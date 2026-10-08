import "dotenv/config";
import { writeFileSync, mkdirSync } from "node:fs";
import { chromium, type Browser } from "playwright";
import { captureDailyStar } from "./papers/dailyStar.js";
import { captureProthomAlo } from "./papers/prothomAlo.js";
import { dhakaDate, parseDay, setPersonWatching, type Day } from "./papers/common.js";
import { summarizePage, summarizeStories } from "./gemini.js";
import { merge } from "./merge.js";
import { pagePrompt, storiesPrompt, type DigestLang } from "./prompt.js";
import { hasDigest, saveDigest, saveStatus, type RunState } from "./supabase.js";
import {
  CATEGORIES,
  ChallengeError,
  LoginError,
  NotPublishedError,
  type Category,
  type DigestItem,
  type DigestSection,
  type Mcq,
  type PageImage,
  type PageSummary,
  type PaperId,
} from "./types.js";

// Usage: npm run digest -- [--paper dailystar|prothomalo] [--date YYYY-MM-DD] [--dry] [--force] [--max-pages N]
const args = process.argv.slice(2);
const flag = (name: string) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? undefined : args[i + 1] ?? "";
};
const DRY = args.includes("--dry");
const FORCE = args.includes("--force");
const MAX_PAGES = Number(flag("max-pages") ?? Infinity);
const ONLY = flag("paper") as PaperId | undefined;
// A past edition to fill in; default is today in Dhaka.
const DATE = flag("date");

// lang: each paper is summarized in its own language unless DIGEST_LANG overrides it.
const PAPERS: { id: PaperId; name: string; lang: DigestLang; capture: (b: Browser, day: Day) => Promise<PageImage[]> }[] = [
  { id: "dailystar", name: "The Daily Star", lang: "en", capture: captureDailyStar },
  { id: "prothomalo", name: "Prothom Alo", lang: "bn", capture: captureProthomAlo },
];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/** First ~2 sentences of the paper's own text, as a short excerpt. */
function excerptOf(body: string, max = 320): string {
  const text = body.replace(/\s+/g, " ").trim();
  if (text.length <= max) return text;
  const cut = text.slice(0, max);
  const end = Math.max(cut.lastIndexOf("। "), cut.lastIndexOf(". "), cut.lastIndexOf("? "));
  return (end > max * 0.5 ? cut.slice(0, end + 1) : cut.replace(/\s+\S*$/, "")) + " …";
}

/** Links each item to its page and, in text mode, to the paper's own headline and opening lines. */
function attachSource(summary: PageSummary, page: PageImage) {
  for (const section of summary.sections) {
    for (const item of section.items) {
      item.page = page.pageNo;
      item.pageId = page.pageId;
      const story = item.story !== undefined ? page.stories?.[item.story] : undefined;
      if (story) {
        item.sourceHeadline = story.headline;
        // Skip a leading byline line like "বিশেষ প্রতিনিধি, ঢাকা" / "Staff Correspondent".
        const lines = story.body.split("\n").map((l) => l.trim()).filter(Boolean);
        const bodyStart = lines.length > 1 && lines[0].length < 60 ? lines.slice(1) : lines;
        item.excerpt = excerptOf(bodyStart.join(" "));
      }
      delete item.story;
    }
  }
}

/** Rough category from the page's name, for stories kept without AI. */
function categoryForPage(name: string): Category {
  const n = name.toLowerCase();
  if (/international|world|আন্তর্জাতিক|বিশ্ব/.test(n)) return "International Affairs";
  if (/business|economy|অর্থ|বাণিজ্য/.test(n)) return "Economy";
  if (/sport|খেলা/.test(n)) return "Sports";
  if (/tech|science|বিজ্ঞান|প্রযুক্তি/.test(n)) return "Science & Tech";
  if (/showbiz|entertainment|literature|weekend|বিনোদন|ছুটির|গোল্লাছুট|অভিমত|মতামত|opinion|editorial/.test(n)) return "Others";
  return "Bangladesh Affairs";
}

/** The paper's own stories for a page, used when no AI model is available. Not summarized. */
function paperFallback(page: PageImage): PageSummary {
  const items: DigestItem[] = (page.stories ?? [])
    .filter((s) => s.headline && s.body.length > 120)
    .map((s) => {
      const lines = s.body.split("\n").map((l) => l.trim()).filter(Boolean);
      const bodyStart = lines.length > 1 && lines[0].length < 60 ? lines.slice(1) : lines;
      return {
        headline: s.headline,
        bullets: [],
        keyFacts: [],
        bcsRelevance: "medium",
        page: page.pageNo,
        pageId: page.pageId,
        sourceHeadline: s.headline,
        excerpt: excerptOf(bodyStart.join(" "), 600),
        source: "paper",
      };
    });
  return { sections: items.length ? [{ category: categoryForPage(page.name), items }] : [], mcqs: [] };
}

function stateFor(err: unknown): RunState {
  if (err instanceof LoginError) return "login_expired";
  if (err instanceof ChallengeError) return "challenge";
  if (err instanceof NotPublishedError) return "not_published";
  return "error";
}

async function runPaper(browser: Browser, paper: (typeof PAPERS)[number], day: Day, lang: DigestLang) {
  const date = day.iso;
  console.log(`\n== ${paper.name} (${date})`);
  // The workflow runs a few times each morning; later runs only retry papers that aren't done.
  if (!DRY && !FORCE && (await hasDigest(date, paper.id))) {
    console.log("  already done, skipping");
    return;
  }
  const pages = (await paper.capture(browser, day)).slice(0, MAX_PAGES);
  console.log(`  captured ${pages.length} pages`);

  const delay = Number(process.env.GEMINI_DELAY_SECONDS || 7) * 1000;
  const summaries: PageSummary[] = [];
  for (const [i, p] of pages.entries()) {
    if (i > 0) await sleep(delay);
    try {
      const opts = { paper: paper.name, pageName: p.name, pageNo: p.pageNo, lang };
      const stories = p.stories ?? [];
      const s = stories.length
        ? await summarizeStories(storiesPrompt({ ...opts, stories }))
        : await summarizePage(p, pagePrompt(opts));
      attachSource(s, p);
      const n = s.sections.reduce((a, x) => a + x.items.length, 0);
      console.log(`  page ${p.pageNo} ${p.name}: ${n} items (from ${stories.length ? `text, ${stories.length} stories` : "image"})`);
      summaries.push(s);
    } catch (e) {
      // One bad page shouldn't sink the whole digest. If every AI key is out of quota,
      // keep the paper's own headlines and opening lines instead of dropping the page.
      const fallback = paperFallback(p);
      const n = fallback.sections.reduce((a, x) => a + x.items.length, 0);
      console.warn(`  page ${p.pageNo} failed (${(e as Error).message.split("\n")[0].slice(0, 80)}); ${n ? `kept ${n} stories from the paper` : "no text to keep"}`);
      if (n) summaries.push(fallback);
    }
  }
  if (summaries.length === 0) throw new Error("Gemini failed on every page");

  const digest = await merge(summaries);
  if (DRY) {
    mkdirSync("out", { recursive: true });
    writeFileSync(`out/${date}-${paper.id}.json`, JSON.stringify(digest, null, 2));
    console.log(`  dry run → out/${date}-${paper.id}.json`);
    return;
  }
  await saveDigest({ date, paper: paper.id, ...digest, page_count: pages.length });
  await saveStatus({ date, paper: paper.id, state: "ok" });
  console.log(`  saved ${digest.sections.length} sections, ${digest.mcqs.length} MCQs`);
}

async function main() {
  const day = DATE ? parseDay(DATE) : dhakaDate();
  const date = day.iso;
  const override = process.env.DIGEST_LANG as DigestLang | "auto" | undefined;
  let browser = await chromium.launch();
  let failures = 0;
  try {
    for (const paper of PAPERS.filter((p) => !ONLY || p.id === ONLY)) {
      const lang = override && override !== "auto" ? override : paper.lang;
      try {
        try {
          await runPaper(browser, paper, day, lang);
        } catch (e) {
          // On your own Mac, show the browser so you can answer the check yourself. Never on GitHub.
          if (!(e instanceof ChallengeError) || process.env.CI) throw e;
          console.log("  bot check shown; opening a browser window so you can answer it");
          await browser.close();
          browser = await chromium.launch({ headless: false });
          setPersonWatching(true);
          await runPaper(browser, paper, day, lang);
        }
      } catch (e) {
        const state = stateFor(e);
        const message = (e as Error).message;
        console.error(`  ✗ ${state}: ${message}`);
        // Not published yet isn't a failure; a later scheduled run picks it up.
        if (state !== "not_published") failures++;
        if (!DRY) await saveStatus({ date, paper: paper.id, state, message }).catch((err) => console.error(err));
      }
    }
  } finally {
    await browser.close();
  }
  process.exitCode = failures ? 1 : 0;
}

main();
