import { CATEGORIES, type Category, type DigestItem, type DigestSection, type Mcq, type PageSummary } from "./types.js";
import { groupDuplicatesGroq } from "./groq.js";
import { groupDuplicatesGemini } from "./gemini.js";

type Flat = DigestItem & { category: Category };

const norm = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();

const STOP = new Set(
  "a an the of in on at to for and or with by from as is are was were be been its it this that into over after amid about new says said".split(" "),
);

function tokens(s: string): Set<string> {
  return new Set(
    norm(s)
      .split(" ")
      .filter((t) => t.length > 2 && !STOP.has(t))
      .map((t) => (t.length > 4 && t.endsWith("s") ? t.slice(0, -1) : t)),
  );
}

/** Conservative fallback when no LLM is available: near-identical headlines only. */
function groupLexically(items: Flat[]): number[][] {
  const toks = items.map((i) => tokens(i.headline));
  const parent = items.map((_, i) => i);
  const find = (i: number): number => (parent[i] === i ? i : (parent[i] = find(parent[i])));
  for (let i = 0; i < items.length; i++) {
    for (let j = i + 1; j < items.length; j++) {
      const shared = [...toks[i]].filter((t) => toks[j].has(t)).length;
      const overlap = shared / Math.max(1, Math.min(toks[i].size, toks[j].size));
      if (shared >= 3 && overlap >= 0.75) parent[find(j)] = find(i);
    }
  }
  const groups = new Map<number, number[]>();
  items.forEach((_, i) => groups.set(find(i), [...(groups.get(find(i)) ?? []), i]));
  return [...groups.values()].filter((g) => g.length > 1);
}

/** Asks an LLM which headlines are the same story; the LLM only returns indices, never facts. */
async function groupDuplicates(items: Flat[]): Promise<number[][]> {
  if (items.length < 2) return [];
  const list = items.map((it, i) => `${i}. ${it.headline} | ${it.keyFacts.slice(0, 4).join("; ")}`).join("\n");
  const prompt = `Below are news items extracted from different pages of ONE newspaper issue.
Group items that report the SAME news story (same event), even if worded differently or split across pages.
Do NOT group items that merely involve the same person, place or topic but are different events
(e.g. "PM addresses UN General Assembly" and "PM meets UN Secretary-General" are DIFFERENT stories).

${list}

Reply with JSON only: {"groups": [[index, index, ...], ...]} listing only groups with 2 or more items. Use {"groups": []} if there are none.`;

  for (const [name, fn] of [
    ["Groq", groupDuplicatesGroq],
    ["Gemini", groupDuplicatesGemini],
  ] as const) {
    try {
      const groups = await fn(prompt);
      if (groups) {
        // Keep only valid, non-overlapping groups.
        const used = new Set<number>();
        return groups
          .map((g) => [...new Set(g)].filter((i) => Number.isInteger(i) && i >= 0 && i < items.length && !used.has(i)))
          .filter((g) => g.length > 1)
          .map((g) => (g.forEach((i) => used.add(i)), g));
      }
    } catch (e) {
      console.warn(`  duplicate check via ${name} failed: ${(e as Error).message.slice(0, 120)}`);
    }
  }
  return groupLexically(items);
}

function uniqueBy(values: string[], limit: number): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const v of values) {
    const k = norm(v);
    if (!k || seen.has(k)) continue;
    seen.add(k);
    out.push(v);
    if (out.length >= limit) break;
  }
  return out;
}

/** Combines duplicate items: best item leads, bullets and key facts are unioned. */
function combine(group: Flat[]): Flat {
  const ranked = [...group].sort(
    (a, b) =>
      (a.bcsRelevance === "high" ? 0 : 1) - (b.bcsRelevance === "high" ? 0 : 1) ||
      b.keyFacts.length + b.bullets.length - (a.keyFacts.length + a.bullets.length),
  );
  const lead = ranked[0];
  return {
    ...lead,
    bullets: uniqueBy(ranked.flatMap((i) => i.bullets), 4),
    keyFacts: uniqueBy(ranked.flatMap((i) => i.keyFacts), 8),
    bcsRelevance: ranked.some((i) => i.bcsRelevance === "high") ? "high" : "medium",
    page: Math.min(...group.map((i) => i.page)),
  };
}

export async function merge(summaries: PageSummary[]): Promise<{ sections: DigestSection[]; mcqs: Mcq[] }> {
  // Flatten and drop exact repeats first.
  const seen = new Set<string>();
  const flat: Flat[] = [];
  for (const s of summaries) {
    for (const section of s.sections) {
      const category = CATEGORIES.includes(section.category) ? section.category : "Others";
      for (const item of section.items) {
        const key = norm(item.headline);
        if (!key || seen.has(key)) continue;
        seen.add(key);
        flat.push({ ...item, category });
      }
    }
  }

  const groups = await groupDuplicates(flat);
  const inGroup = new Set(groups.flat());
  const merged = [...flat.filter((_, i) => !inGroup.has(i)), ...groups.map((g) => combine(g.map((i) => flat[i])))];
  if (groups.length) console.log(`  merged ${groups.flat().length} duplicate items into ${groups.length}`);

  const sections = CATEGORIES.map((category) => ({
    category,
    items: merged
      .filter((i) => i.category === category)
      .map(({ category: _, ...item }) => item)
      // High-relevance first, then page order.
      .sort((a, b) => (a.bcsRelevance === b.bcsRelevance ? a.page - b.page : a.bcsRelevance === "high" ? -1 : 1)),
  })).filter((s) => s.items.length > 0);

  const seenQ = new Set<string>();
  const mcqs = summaries
    .flatMap((s) => s.mcqs)
    .filter((q) => q.options.length === 4 && q.options.includes(q.answer))
    .filter((q) => {
      const k = norm(q.answer) + "|" + [...tokens(q.question)].sort().join(" ");
      return seenQ.has(k) ? false : (seenQ.add(k), true);
    })
    .slice(0, 20);

  return { sections, mcqs };
}
