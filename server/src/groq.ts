import type { PageSummary } from "./types.js";
import { KeyPool } from "./keys.js";

// Only Groq model with image input (preview): https://console.groq.com/docs/vision
const DEFAULT_MODEL = "qwen/qwen3.8-27b";

const JSON_SHAPE = `Reply with JSON only, in exactly this shape:
{"sections":[{"category":"...","items":[{"headline":"...","bullets":["..."],"keyFacts":["..."],"bcsRelevance":"high|medium","page":0}]}],
 "mcqs":[{"question":"...","options":["a","b","c","d"],"answer":"a"}]}`;

const pool = new KeyPool("GROQ_API_KEYS", "GROQ_API_KEY");

export const groqConfigured = () => pool.configured();

export async function summarizePageGroq(image: { mime: string; data: Buffer }, prompt: string): Promise<PageSummary> {
  const model = process.env.GROQ_MODEL || DEFAULT_MODEL;
  const body = {
    model,
    temperature: 0.2,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: `${prompt}\n\n${JSON_SHAPE}` },
          { type: "image_url", image_url: { url: `data:${image.mime};base64,${image.data.toString("base64")}` } },
        ],
      },
    ],
  };

  const res = await pool.fetchWithRotation((key) =>
    fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify(body),
    }),
  );
  if (!res.ok) throw new Error(`Groq ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const json: any = await res.json();
  const text: string = json.choices?.[0]?.message?.content ?? "";
  if (!text) return { sections: [], mcqs: [] };
  const parsed = JSON.parse(text);
  return { sections: parsed.sections ?? [], mcqs: parsed.mcqs ?? [] };
}

function parseGroups(text: string): number[][] | null {
  const parsed = JSON.parse(text);
  return Array.isArray(parsed?.groups) ? parsed.groups.filter(Array.isArray).map((g: unknown[]) => g.map(Number)) : null;
}

/** Text-only duplicate grouping, a job Groq's text models handle well. Returns null if Groq isn't set up. */
export async function groupDuplicatesGroq(prompt: string): Promise<number[][] | null> {
  if (!pool.configured()) return null;
  const res = await pool.fetchWithRotation(
    (key) =>
      fetch("https://api.groq.com/openai/v1/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
        body: JSON.stringify({
          model: process.env.GROQ_TEXT_MODEL || "openai/gpt-oss-120b",
          temperature: 0,
          reasoning_effort: "low",
          response_format: { type: "json_object" },
          messages: [{ role: "user", content: prompt }],
        }),
      }),
    { backoff: false },
  );
  if (!res.ok) throw new Error(`Groq ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const json: any = await res.json();
  return parseGroups(json.choices?.[0]?.message?.content ?? "");
}

export { parseGroups };
