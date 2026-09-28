// NewsDigest: AI go-between for the iOS app.
// The app never holds API keys: it sends the page (article text, or an image as fallback)
// here, and this function calls Gemini / Groq with keys stored as Supabase secrets:
//   GEMINI_API_KEYS  (comma-separated)   GROQ_API_KEYS (comma-separated, optional)
// Only signed-in users of this project can call it.
//
// POST { action: "summarize", paper, pageName, pageNo, lang: "en"|"bn", model?, stories?: [{headline, body, captions}], image?: {mime, data} }
//   → { ok: true, sections, mcqs, model, source } | { ok: false, reason: "quota"|"error", message }
// POST { action: "chat", context, messages: [{ role: "user"|"model", text }] }
//   → { ok: true, text, model } | { ok: false, reason, message }
// POST { action: "run_digest", paper?: "dailystar"|"prothomalo" }
//   Starts the "Daily digest" GitHub workflow now instead of waiting for the next hourly run.
//   Needs GH_DISPATCH_TOKEN (fine-grained token, Actions: read and write on the repo) and
//   GH_REPO ("owner/name"); GH_REF defaults to "main".
//   → { ok: true, message } | { ok: false, reason: "error", message }
// POST { action: "speak", text, lang: "bn"|"en", gender?: "female"|"male" }
//   Natural read-aloud voice from Azure Speech. Needs AZURE_SPEECH_KEY and AZURE_SPEECH_REGION
//   (e.g. "southeastasia"); AZURE_VOICE_BN / AZURE_VOICE_EN override the default voices.
//   → { ok: true, audio: base64 mp3, voice } | { ok: false, reason: "quota"|"error", message }
import { createClient } from "npm:@supabase/supabase-js@2";

const CATEGORIES = ["Bangladesh Affairs", "International Affairs", "Economy", "Science & Tech", "Environment", "Sports", "Others"];
const GEMINI_MODELS = ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash-lite"];
const GROQ_TEXT_MODEL = "openai/gpt-oss-120b";

const keys = (name: string) => (Deno.env.get(name) ?? "").split(",").map((k) => k.trim()).filter(Boolean);
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// Keep in sync with server/src/prompt.ts.
function bcsPrompt(paper: string, pageName: string, lang: string): string {
  const langRule =
    lang === "bn"
      ? "Write everything (headlines, bullets, key facts, MCQs) in Bangla (বাংলা). Keep proper names in their usual Bangla spelling."
      : "Write everything in clear, simple English, even when the source is in Bangla.";
  return `You are a study assistant for a candidate preparing for the Bangladesh Civil Service (BCS) exam.
Source: page "${pageName}" of today's ${paper}.

Extract ONLY news that could matter for BCS preliminary/written/viva: Bangladesh affairs (government decisions, laws, constitution, appointments, projects with cost/length/location, policies, statistics), international affairs (treaties, summits, organizations, conflicts, elections, heads of state), economy (budget, GDP, inflation, remittance, reserves, trade), science & tech, environment/climate, notable sports records, rankings/indices, firsts, awards, and deaths of notable people.
Skip ads, gossip, entertainment, and crime without policy significance. Do not invent facts that are not in the source. Copy numbers, dates and names exactly.

Categories: ${CATEGORIES.join(", ")}.
Write up to 3 MCQs with 4 options each. The answer must exactly equal one of the options.
${langRule}

Reply with JSON only, in this shape:
{"sections":[{"category":"...","items":[{"headline":"...","bullets":["..."],"keyFacts":["..."],"bcsRelevance":"high|medium","page":0,"story":0}]}],
 "mcqs":[{"question":"...","options":["a","b","c","d"],"answer":"a"}]}`;
}

/** First ~2 sentences of a story, skipping a short byline line. */
function excerptOf(body: string, max = 320): string {
  const lines = body.split("\n").map((l) => l.trim()).filter(Boolean);
  const text = (lines.length > 1 && lines[0].length < 60 ? lines.slice(1) : lines).join(" ").replace(/\s+/g, " ");
  if (text.length <= max) return text;
  const cut = text.slice(0, max);
  const end = Math.max(cut.lastIndexOf("। "), cut.lastIndexOf(". "), cut.lastIndexOf("? "));
  return (end > max * 0.5 ? cut.slice(0, end + 1) : cut.replace(/\s+\S*$/, "")) + " …";
}

type Part = { text: string } | { inline_data: { mime_type: string; data: string } };

/** Tries each Gemini model and key; returns null when every one is rate-limited or failing. */
async function gemini(parts: Part[], preferred: string | undefined, jsonMode: boolean): Promise<{ text: string; model: string } | null> {
  const models = preferred && preferred !== "auto" ? [preferred, ...GEMINI_MODELS.filter((m) => m !== preferred)] : GEMINI_MODELS;
  const pool = keys("GEMINI_API_KEYS");
  const deadline = Date.now() + 80_000; // stay well inside the app's 100 s wait
  for (const model of models) {
    for (const key of pool) {
      if (Date.now() > deadline) return null;
      const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: "POST",
        signal: AbortSignal.timeout(Math.min(35_000, Math.max(1_000, deadline - Date.now()))),
        headers: { "Content-Type": "application/json", "x-goog-api-key": key },
        body: JSON.stringify({
          contents: [{ role: "user", parts }],
          generationConfig: { temperature: 0.2, ...(jsonMode ? { responseMimeType: "application/json" } : {}) },
        }),
      }).catch(() => null);
      if (!res) continue;
      if (res.ok) {
        const data = await res.json();
        const text = data.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text ?? "").join("") ?? "";
        if (text) return { text, model };
      }
      // 429 (quota) / 5xx (overloaded): try the next key, then the next model.
    }
  }
  return null;
}

/** Groq text model in JSON mode (text sources only; Groq's image model can't read Bangla print). */
async function groqJSON(prompt: string, model: string): Promise<{ text: string; model: string } | null> {
  for (const key of keys("GROQ_API_KEYS")) {
    const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      signal: AbortSignal.timeout(30_000),
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify({
        model,
        temperature: 0.2,
        response_format: { type: "json_object" },
        ...(model.startsWith("openai/") ? { reasoning_effort: "low" } : {}),
        messages: [{ role: "user", content: prompt }],
      }),
    }).catch(() => null);
    if (res?.ok) {
      const data = await res.json();
      const text = data.choices?.[0]?.message?.content ?? "";
      if (text) return { text, model: `groq:${model}` };
    }
  }
  return null;
}

async function groqChat(messages: { role: string; content: string }[]): Promise<{ text: string; model: string } | null> {
  for (const key of keys("GROQ_API_KEYS")) {
    const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      signal: AbortSignal.timeout(30_000),
      body: JSON.stringify({ model: GROQ_TEXT_MODEL, temperature: 0.3, reasoning_effort: "low", messages }),
    }).catch(() => null);
    if (res?.ok) {
      const data = await res.json();
      const text = data.choices?.[0]?.message?.content ?? "";
      if (text) return { text, model: `groq:${GROQ_TEXT_MODEL}` };
    }
  }
  return null;
}

async function summarize(body: any) {
  const stories: { headline: string; body: string; captions?: string[] }[] = body.stories ?? [];
  const prompt = bcsPrompt(body.paper ?? "the newspaper", body.pageName ?? "", body.lang ?? "en");
  let parts: Part[];
  let source: "text" | "image";
  if (stories.length) {
    const list = stories
      .map((s, i) => {
        const text = s.body.length > 3000 ? s.body.slice(0, 3000) + " …" : s.body;
        const caps = s.captions?.length ? `\nPhoto captions: ${s.captions.join(" | ")}` : "";
        return `### Story ${i}\nHeadline: ${s.headline}\n${text}${caps}`;
      })
      .join("\n\n");
    parts = [{ text: `${prompt}\n\nFor each item, set "story" to the number of the story it came from.\n\n${list}` }];
    source = "text";
  } else if (body.image?.data) {
    parts = [{ inline_data: { mime_type: body.image.mime ?? "image/jpeg", data: body.image.data } }, { text: prompt }];
    source = "image";
  } else {
    return json({ ok: false, reason: "error", message: "Nothing to summarize" }, 400);
  }

  // "groq:<model>" picks Groq first (text only); otherwise Gemini first, Groq as the backup for text.
  const chosen = String(body.model ?? "auto");
  const groqModel = chosen.startsWith("groq:") ? chosen.slice(5) : GROQ_TEXT_MODEL;
  const textPrompt = source === "text" ? (parts[0] as { text: string }).text : "";
  let out: { text: string; model: string } | null = null;
  if (chosen.startsWith("groq:") && source === "text") out = await groqJSON(textPrompt, groqModel);
  if (!out) out = await gemini(parts, chosen.startsWith("groq:") ? undefined : chosen, true);
  if (!out && source === "text" && !chosen.startsWith("groq:")) out = await groqJSON(textPrompt, groqModel);
  if (!out) return json({ ok: false, reason: "quota", message: "All AI keys are busy or out of quota right now." });
  try {
    const parsed = JSON.parse(out.text);
    const pageNo = Number(body.pageNo ?? 0);
    const sections = (parsed.sections ?? [])
      .map((sec: any) => ({
        category: CATEGORIES.includes(sec.category) ? sec.category : "Others",
        items: (sec.items ?? []).map((it: any) => {
          const story = Number.isInteger(it.story) ? stories[it.story] : undefined;
          return {
            headline: String(it.headline ?? ""),
            bullets: it.bullets ?? [],
            keyFacts: it.keyFacts ?? [],
            bcsRelevance: it.bcsRelevance === "high" ? "high" : "medium",
            page: pageNo,
            model: out.model,
            source,
            ...(story ? { sourceHeadline: story.headline, excerpt: excerptOf(story.body) } : {}),
          };
        }),
      }))
      .filter((sec: any) => sec.items.length);
    const mcqs = (parsed.mcqs ?? [])
      .filter((q: any) => Array.isArray(q.options) && q.options.includes(q.answer))
      .map((q: any) => ({ question: q.question, options: q.options, answer: q.answer, model: out.model, source }));
    return json({ ok: true, sections, mcqs, model: out.model, source });
  } catch {
    return json({ ok: false, reason: "error", message: "The AI reply couldn't be read." });
  }
}

async function chat(body: any) {
  const context = String(body.context ?? "").slice(0, 12000);
  const history: { role: string; text: string }[] = body.messages ?? [];
  const system = `You help a Bangladesh Civil Service (BCS) exam candidate understand today's news. Be concise and accurate; don't invent facts. Answer in Bangla if the user writes in Bangla or asks for it.\n\nContext from the newspaper page:\n${context}`;
  // Groq first (fast, generous free tier for text), then Gemini.
  const groq = await groqChat([
    { role: "system", content: system },
    ...history.map((m) => ({ role: m.role === "model" ? "assistant" : "user", content: m.text })),
  ]);
  if (groq) return json({ ok: true, ...groq });
  const convo = [system, ...history.map((m) => `${m.role === "model" ? "Assistant" : "User"}: ${m.text}`), "Assistant:"].join("\n\n");
  const g = await gemini([{ text: convo }], undefined, false);
  if (g) return json({ ok: true, ...g });
  return json({ ok: false, reason: "quota", message: "All AI keys are busy or out of quota right now." });
}

async function runDigest(body: any) {
  const token = Deno.env.get("GH_DISPATCH_TOKEN");
  const repo = Deno.env.get("GH_REPO");
  if (!token || !repo) return json({ ok: false, reason: "error", message: "Manual runs aren't set up on the server (GH_DISPATCH_TOKEN / GH_REPO)." });
  const api = `https://api.github.com/repos/${repo}/actions/workflows/daily-digest.yml`;
  const headers = { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" };

  // A run already queued or in progress will pick up whatever isn't done; don't stack another.
  for (const status of ["in_progress", "queued"]) {
    const res = await fetch(`${api}/runs?status=${status}&per_page=1`, { headers }).catch(() => null);
    if (res?.ok && (await res.json()).total_count > 0) {
      return json({ ok: true, message: "A digest run is already going. It usually takes 5–10 minutes." });
    }
  }

  const paper = ["dailystar", "prothomalo"].includes(body.paper) ? body.paper : "";
  const res = await fetch(`${api}/dispatches`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ ref: Deno.env.get("GH_REF") || "main", inputs: { paper, force: false } }),
  }).catch(() => null);
  if (!res?.ok) {
    const detail = res ? `GitHub said ${res.status}` : "couldn't reach GitHub";
    return json({ ok: false, reason: "error", message: `Couldn't start the digest (${detail}).` });
  }
  return json({ ok: true, message: "Digest started. It usually takes 5–10 minutes." });
}

const VOICES: Record<string, Record<string, string>> = {
  bn: { female: "bn-BD-NabanitaNeural", male: "bn-BD-PradeepNeural" },
  en: { female: "en-US-JennyNeural", male: "en-US-GuyNeural" },
};

async function speak(body: any) {
  const key = Deno.env.get("AZURE_SPEECH_KEY");
  const region = Deno.env.get("AZURE_SPEECH_REGION");
  if (!key || !region) return json({ ok: false, reason: "error", message: "The natural voice isn't set up on the server (AZURE_SPEECH_KEY / AZURE_SPEECH_REGION)." });
  const text = String(body.text ?? "").slice(0, 3000);
  if (!text.trim()) return json({ ok: false, reason: "error", message: "Nothing to read" }, 400);
  const lang = body.lang === "bn" ? "bn" : "en";
  const gender = body.gender === "male" ? "male" : "female";
  const voice = Deno.env.get(`AZURE_VOICE_${lang.toUpperCase()}`) || VOICES[lang][gender];
  const escaped = text.replace(/[<>&'"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" })[c]!);
  const ssml = `<speak version="1.0" xml:lang="${voice.slice(0, 5)}"><voice name="${voice}">${escaped}</voice></speak>`;

  const res = await fetch(`https://${region}.tts.speech.microsoft.com/cognitiveservices/v1`, {
    method: "POST",
    signal: AbortSignal.timeout(30_000),
    headers: {
      "Ocp-Apim-Subscription-Key": key,
      "Content-Type": "application/ssml+xml",
      "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
      "User-Agent": "NewsDigest",
    },
    body: ssml,
  }).catch(() => null);
  if (!res?.ok) {
    const quota = res?.status === 429 || res?.status === 403;
    return json({ ok: false, reason: quota ? "quota" : "error", message: quota ? "The natural voice is out of quota for now." : "The natural voice couldn't be reached." });
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return json({ ok: true, audio: btoa(binary), voice });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, reason: "error", message: "POST only" }, 405);

  // Only signed-in users of this project.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return json({ ok: false, reason: "error", message: "Sign in first" }, 401);

  const body = await req.json().catch(() => ({}));
  if (body.action === "chat") return chat(body);
  if (body.action === "run_digest") return runDigest(body);
  if (body.action === "speak") return speak(body);
  return summarize(body);
});
