import { CATEGORIES, type PageSummary } from "./types.js";
import { KeyPool } from "./keys.js";
import { splitHalves } from "./image.js";
import { groqConfigured, parseGroups, summarizePageGroq } from "./groq.js";

const RESPONSE_SCHEMA = {
  type: "OBJECT",
  properties: {
    sections: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          category: { type: "STRING", enum: [...CATEGORIES] },
          items: {
            type: "ARRAY",
            items: {
              type: "OBJECT",
              properties: {
                headline: { type: "STRING" },
                bullets: { type: "ARRAY", items: { type: "STRING" } },
                keyFacts: { type: "ARRAY", items: { type: "STRING" } },
                bcsRelevance: { type: "STRING", enum: ["high", "medium"] },
                page: { type: "INTEGER" },
                story: { type: "INTEGER" },
              },
              required: ["headline", "bullets", "keyFacts", "bcsRelevance", "page"],
            },
          },
        },
        required: ["category", "items"],
      },
    },
    mcqs: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          question: { type: "STRING" },
          options: { type: "ARRAY", items: { type: "STRING" } },
          answer: { type: "STRING" },
        },
        required: ["question", "options", "answer"],
      },
    },
  },
  required: ["sections", "mcqs"],
};

const pool = new KeyPool("GEMINI_API_KEYS", "GEMINI_API_KEY");

type Part = { text: string } | { inline_data: { mime_type: string; data: string } };

async function imageParts(image: { mime: string; data: Buffer }, prompt: string): Promise<Part[]> {
  const halves = await splitHalves(image.data);
  const note =
    halves.length > 1
      ? "\n\nThe page is given as two images: the TOP half, then the BOTTOM half, overlapping slightly. Treat them as one page and don't repeat a story that appears in the overlap. Read numbers and dates carefully, including Bangla digits (০-৯)."
      : "";
  return [...halves.map((h) => ({ inline_data: { mime_type: h.mime, data: h.data.toString("base64") } })), { text: prompt + note }];
}

async function generateSummary(parts: Part[], model: string, backoff: boolean): Promise<PageSummary> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
  const body = {
    contents: [{ role: "user", parts }],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: RESPONSE_SCHEMA,
      temperature: 0.2,
    },
  };

  const res = await pool.fetchWithRotation(
    (key) =>
      fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": key },
        body: JSON.stringify(body),
      }),
    { backoff },
  );
  if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const json: any = await res.json();
  const text = json.candidates?.[0]?.content?.parts?.map((p: any) => p.text ?? "").join("") ?? "";
  if (!text) return { sections: [], mcqs: [] };
  return JSON.parse(text) as PageSummary;
}

function tagModel(summary: PageSummary, model: string, source: "image" | "text" = "image"): PageSummary {
  for (const section of summary.sections)
    for (const item of section.items) {
      item.model = model;
      item.source = source;
    }
  for (const q of summary.mcqs) {
    q.model = model;
    q.source = source;
  }
  return summary;
}

/** GEMINI_MODEL first, then GEMINI_FALLBACK_MODELS (comma-separated) when a model is overloaded. */
function geminiModels(): string[] {
  const primary = process.env.GEMINI_MODEL || "gemini-3.8-flash";
  // `||` not `??`: GitHub passes unset repository variables as "".
  const fallbacks = (process.env.GEMINI_FALLBACK_MODELS || "gemini-3.7-flash,gemini-3.5-flash-lite")
    .split(",")
    .map((m) => m.trim())
    .filter((m) => m && m !== primary);
  return [primary, ...fallbacks];
}

/** Tries each Gemini model in turn; the last one waits and retries on rate limits. */
async function withModelChain(parts: Part[], source: "image" | "text", allowFinalBackoff: boolean): Promise<PageSummary> {
  if (!pool.configured()) throw new Error("GEMINI_API_KEYS is not set");
  let lastError: unknown;
  const models = geminiModels();
  for (const [i, model] of models.entries()) {
    try {
      return tagModel(await generateSummary(parts, model, allowFinalBackoff && i === models.length - 1), model, source);
    } catch (e) {
      lastError = e;
      console.warn(`    ${model} failed: ${(e as Error).message.split("\n")[0].slice(0, 100)}`);
    }
  }
  throw lastError;
}

/** Summarizes a page from its article TEXT. Numbers come straight from the text, so nothing is misread. */
export async function summarizeStories(prompt: string): Promise<PageSummary> {
  return withModelChain([{ text: prompt }], "text", true);
}

/**
 * Summarizes a page from its IMAGE (fallback when a page has no article text).
 * Groq is used only when GROQ_FALLBACK=true: its image model can't read small Bangla print
 * and was seen inventing headlines, which is worse than no digest for exam prep.
 */
export async function summarizePage(image: { mime: string; data: Buffer }, prompt: string): Promise<PageSummary> {
  const useGroq = process.env.GROQ_FALLBACK === "true" && groqConfigured();
  try {
    return await withModelChain(await imageParts(image, prompt), "image", !useGroq);
  } catch (e) {
    if (!useGroq) throw e;
  }
  return tagModel(await summarizePageGroq(image, prompt), `groq:${process.env.GROQ_MODEL || "qwen/qwen3.8-27b"}`);
}

/** Text-only duplicate grouping; used when Groq isn't available. Returns null if Gemini isn't set up. */
export async function groupDuplicatesGemini(prompt: string): Promise<number[][] | null> {
  if (!pool.configured()) return null;
  let lastError: unknown;
  for (const model of geminiModels().reverse()) {
    // Cheapest model first: this is an easy task and saves the main model's quota for page reading.
    const res = await pool.fetchWithRotation(
      (key) =>
        fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-goog-api-key": key },
          body: JSON.stringify({
            contents: [{ role: "user", parts: [{ text: prompt }] }],
            generationConfig: { responseMimeType: "application/json", temperature: 0 },
          }),
        }),
      { backoff: false },
    );
    if (res.ok) {
      const json: any = await res.json();
      return parseGroups(json.candidates?.[0]?.content?.parts?.map((p: any) => p.text ?? "").join("") ?? "");
    }
    lastError = new Error(`Gemini ${model} ${res.status}`);
  }
  throw lastError;
}
