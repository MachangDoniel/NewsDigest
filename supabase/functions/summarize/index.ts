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
// POST { action: "whoami" }
//   → { ok: true, admin }   admin = the signed-in email is in the `admins` table
// POST { action: "admin_overview" }   admins only
//   → { ok: true, runs, workflow, database, storage, usage, users } for the app's Admin screen
// POST { action: "log_web", events: [{ action, ok, status, latencyMs, device, ip, userAgent }] }
//   Visits reported by the NewsDigest-Web server, for the Admin screen. No user sign-in: the
//   request must carry the X-Web-Log-Key header matching the WEB_LOG_KEY secret.
// POST { action: "admin_ping" }   admins only → { ok, pingMs }   one small database query, timed
// POST { action: "admin_reset_usage" }   admins only → { ok }   empties the usage log
// POST { action: "run_digest", paper?: "dailystar"|"prothomalo", date?: "YYYY-MM-DD", force?: boolean }   admins only
//   Starts the "Daily digest" GitHub workflow now instead of waiting for the next hourly run.
//   Needs GH_DISPATCH_TOKEN (fine-grained token, Actions: read and write on the repo) and
//   GH_REPO ("owner/name"); GH_REF defaults to "main".
//   → { ok: true, message } | { ok: false, reason: "error", message }
// POST { action: "speak", text }
//   Gemini read-aloud voice for one section of a story. Each section is made once and saved in
//   the private "speech" Storage bucket; later requests for the same text get the saved copy.
//   Uses only GEMINI_TTS_KEYS (keys from a separate Google project, so reading aloud never uses
//   the summary quota). GEMINI_TTS_VOICE (default "Kore") and GEMINI_TTS_MODEL are optional.
//   → { ok: true, url, cached } (signed URL of a WAV file, valid 1 hour)
//   | { ok: false, reason: "busy", retryAfter, message }  per-minute limit: try again after retryAfter seconds
//   | { ok: false, reason: "quota"|"error", message }       daily limit reached, or another failure
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
  const date = /^\d{4}-\d{2}-\d{2}$/.test(body.date ?? "") ? body.date : "";
  const res = await fetch(`${api}/dispatches`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ ref: Deno.env.get("GH_REF") || "main", inputs: { paper, date, force: body.force === true } }),
  }).catch(() => null);
  if (!res?.ok) {
    const detail = res ? `GitHub said ${res.status}` : "couldn't reach GitHub";
    return json({ ok: false, reason: "error", message: `Couldn't start the digest (${detail}).` });
  }
  return json({ ok: true, message: "Digest started. It usually takes 5–10 minutes." });
}

const TTS_MODELS = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"];

async function speak(body: any) {
  const pool = keys("GEMINI_TTS_KEYS");
  if (!pool.length) return json({ ok: false, reason: "error", message: "The Gemini voice isn't set up on the server (GEMINI_TTS_KEYS)." });
  const text = String(body.text ?? "").trim().slice(0, 1500);
  if (!text) return json({ ok: false, reason: "error", message: "Nothing to read" }, 400);
  const voice = Deno.env.get("GEMINI_TTS_VOICE") || "Kore";
  const preferred = Deno.env.get("GEMINI_TTS_MODEL");
  const models = preferred ? [preferred, ...TTS_MODELS.filter((m) => m !== preferred)] : TTS_MODELS;

  // Saved per voice and text, so any section already made is sent straight back.
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
  const path = `${voice}/${hash}.wav`;
  const storage = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!).storage.from("speech");
  const signed = async () => (await storage.createSignedUrl(path, 3600)).data?.signedUrl;

  const { data: found } = await storage.list(voice, { search: `${hash}.wav`, limit: 1 });
  if (found?.some((f) => f.name === `${hash}.wav`)) {
    const url = await signed();
    if (url) return json({ ok: true, url, cached: true });
  }

  let audio: Uint8Array | null = null;
  // A 429 is either the per-minute limit (busy: fine again shortly) or the daily one (quota).
  let busyFor = 0;
  let daily = false;
  let lastError = "";
  outer: for (const model of models) {
    for (const key of pool) {
      const res = await fetch("https://generativelanguage.googleapis.com/v1beta/interactions", {
        method: "POST",
        signal: AbortSignal.timeout(90_000),
        headers: { "Content-Type": "application/json", "x-goog-api-key": key },
        body: JSON.stringify({
          model,
          input: [{ type: "user_input", content: [{ type: "text", text }] }],
          response_format: { type: "audio", mime_type: "audio/wav", sample_rate: 24000 },
          generation_config: { speech_config: [{ voice }] },
        }),
      }).catch(() => null);
      if (!res) { lastError = "no response"; continue; }
      if (res.status === 429) {
        const detail = await res.text();
        if (/per ?day/i.test(detail)) daily = true;
        else busyFor = Math.max(busyFor, Number(detail.match(/"retryDelay":\s*"(\d+)/)?.[1] ?? 20));
        continue;  // try the next key, then the next model
      }
      if (!res.ok) { lastError = `${model} said ${res.status}`; continue; }
      const data = await res.json();
      const parts = (data.steps ?? []).filter((s: any) => s.type === "model_output").flatMap((s: any) => s.content ?? []);
      const b64 = parts.filter((c: any) => c.type === "audio").at(-1)?.data;
      if (b64) { audio = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)); break outer; }
    }
  }
  if (!audio) {
    if (busyFor) return json({ ok: false, reason: "busy", retryAfter: Math.min(busyFor, 60), message: "The Gemini voice is busy for a moment." });
    if (daily) return json({ ok: false, reason: "quota", message: "The Gemini voice is out of quota for today." });
    return json({ ok: false, reason: "error", message: `The Gemini voice couldn't make this section (${lastError || "no audio"}).` });
  }

  const { error } = await storage.upload(path, audio, { contentType: "audio/wav", upsert: true });
  if (error) return json({ ok: false, reason: "error", message: `Couldn't save the audio: ${error.message}` });
  const url = await signed();
  return url ? json({ ok: true, url, cached: false }) : json({ ok: false, reason: "error", message: "Couldn't share the saved audio." });
}

const service = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function isAdmin(email?: string): Promise<boolean> {
  if (!email) return false;
  // Emails in `admins` are stored in lower case.
  const { data } = await service().from("admins").select("email").eq("email", email.toLowerCase()).limit(1);
  return (data?.length ?? 0) > 0;
}

/** Date (YYYY-MM-DD) in Dhaka, `daysAgo` days back. */
const dhakaDay = (daysAgo = 0, from = Date.now()) => new Date(from + 6 * 3_600_000 - daysAgo * 86_400_000).toISOString().slice(0, 10);

/** Everything the app's Admin screen shows, in one call. */
async function adminOverview() {
  const db = service();
  const since = dhakaDay(9);
  const weekAgo = new Date(Date.now() - 7 * 86_400_000).toISOString();
  await db.from("usage_events").delete().lt("at", new Date(Date.now() - 30 * 86_400_000).toISOString());

  const started = Date.now();
  const now = new Date();
  const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
  const [count, oldest, built, statuses, events, users, admins, stats, month] = await Promise.all([
    db.from("digests").select("id", { count: "exact", head: true }),
    db.from("digests").select("date").order("date").limit(1),
    db.from("digests").select("date,paper,page_count,created_at").gte("date", since),
    db.from("run_status").select("date,paper,state,message,updated_at").gte("date", since),
    db.from("usage_events").select("at,email,action,ok,latency_ms,device,ip,user_agent,status").gte("at", weekAgo).order("at", { ascending: false }).limit(5000),
    db.auth.admin.listUsers(),
    db.from("admins").select("email"),
    db.rpc("admin_db_stats"),
    // Requests from the app this calendar month; each one is one Edge Function call.
    db.from("usage_events").select("id", { count: "exact", head: true }).gte("at", monthStart).not("email", "in", "(server,web)"),
  ]);
  const pingMs = Date.now() - started;
  const failed = [count, oldest, built, statuses, events, admins].find((r) => r.error)?.error;

  // One row per paper per day for the last 10 days, newest first.
  const runs = [];
  for (let i = 0; i < 10; i++) {
    const date = dhakaDay(i);
    for (const paper of ["dailystar", "prothomalo"]) {
      const digest = built.data?.find((d) => d.date === date && d.paper === paper);
      const status = statuses.data?.find((s) => s.date === date && s.paper === paper);
      runs.push({
        date,
        paper,
        state: digest ? "ok" : status?.state ?? "missing",
        message: digest ? null : status?.message ?? null,
        pages: digest?.page_count ?? null,
        at: digest?.created_at ?? status?.updated_at ?? null,
      });
    }
  }

  // "server" rows are pages the hourly digest summarized; everything else came from the app.
  const today = dhakaDay();
  const rows = events.data ?? [];
  const todayRows = rows.filter((e) => dhakaDay(0, Date.parse(e.at)) === today);
  const tally = (list: typeof rows) => {
    const out: Record<string, number> = {};
    for (const e of list) out[e.action] = (out[e.action] ?? 0) + 1;
    return out;
  };
  const thisHour = Math.floor(Date.now() / 3_600_000);
  const hourly = Array.from({ length: 24 }, (_, i) => {
    const hour = thisHour - 23 + i;
    const inHour = rows.filter((e) => Math.floor(Date.parse(e.at) / 3_600_000) === hour);
    const server = inHour.filter((e) => e.email === "server").length;
    const web = inHour.filter((e) => e.email === "web").length;
    return { at: new Date(hour * 3_600_000).toISOString(), app: inHour.length - server - web, server, web };
  });
  const daily = Array.from({ length: 7 }, (_, i) => {
    const date = dhakaDay(6 - i);
    const inDay = rows.filter((e) => dhakaDay(0, Date.parse(e.at)) === date);
    const server = inDay.filter((e) => e.email === "server").length;
    const web = inDay.filter((e) => e.email === "web").length;
    return { date, app: inDay.length - server - web, server, web, failed: inDay.filter((e) => !e.ok).length };
  });
  const timedToday = todayRows.filter((e) => e.email !== "server" && e.latency_ms != null);
  const perUser = new Map<string, { email: string; count: number; last: string; device: string | null; ip: string | null; userAgent: string | null }>();
  const perAction = new Map<string, { action: string; count: number; failed: number; totalMs: number; timed: number }>();
  for (const e of rows) {
    const email = e.email ?? "unknown";
    // Website visitors have no account, so they are told apart by address.
    const who = email === "web" ? `web ${e.ip ?? ""}` : email;
    // Rows are newest first, so the first one seen for a user is their latest.
    const u = perUser.get(who) ?? { email, count: 0, last: e.at, device: e.device, ip: e.ip, userAgent: e.user_agent };
    u.count++;
    perUser.set(who, u);
    const a = perAction.get(e.action) ?? { action: e.action, count: 0, failed: 0, totalMs: 0, timed: 0 };
    a.count++;
    if (!e.ok) a.failed++;
    if (e.latency_ms != null) { a.totalMs += e.latency_ms; a.timed++; }
    perAction.set(e.action, a);
  }
  const adminEmails = new Set((admins.data ?? []).map((a) => a.email.toLowerCase()));
  const size = stats.data ?? {};

  return json({
    ok: true,
    runs,
    workflow: await recentWorkflowRuns(),
    database: {
      ok: !failed,
      message: failed?.message ?? null,
      pingMs,
      digests: count.count ?? 0,
      firstDate: oldest.data?.[0]?.date ?? null,
      latestDate: built.data?.map((d) => d.date).sort().at(-1) ?? null,
    },
    // Limits are Supabase's free plan: 500 MB database, 1 GB file storage.
    storage: {
      dbBytes: size.dbBytes ?? null,
      dbLimitBytes: 500 * 1024 * 1024,
      audioBytes: size.audioBytes ?? null,
      audioLimitBytes: 1024 * 1024 * 1024,
      audioFiles: size.audioFiles ?? null,
      statusRows: size.runStatus ?? null,
      usageRows: size.usageEvents ?? null,
    },
    usage: {
      today: tally(todayRows),
      week: tally(rows),
      failedToday: todayRows.filter((e) => !e.ok).length,
      failedWeek: rows.filter((e) => !e.ok).length,
      // Supabase's free plan allows 500,000 Edge Function calls a month. Admin-screen calls aren't logged, so this runs slightly low.
      monthCalls: month.count ?? 0,
      monthLimit: 500_000,
      avgMsToday: timedToday.length ? Math.round(timedToday.reduce((a, e) => a + e.latency_ms, 0) / timedToday.length) : null,
      daily,
      usersToday: new Set(todayRows.filter((e) => e.email !== "server").map((e) => (e.email === "web" ? `web ${e.ip ?? ""}` : e.email))).size,
      hourly,
      byUser: [...perUser.values()].sort((a, b) => b.count - a.count),
      byAction: [...perAction.values()]
        .map((a) => ({ action: a.action, count: a.count, failed: a.failed, avgMs: a.timed ? Math.round(a.totalMs / a.timed) : null }))
        .sort((a, b) => b.count - a.count),
      recent: rows.slice(0, 100).map((e) => ({ at: e.at, email: e.email, action: e.action, ok: e.ok, latencyMs: e.latency_ms, device: e.device, ip: e.ip, status: e.status })),
    },
    users: (users.data?.users ?? []).map((u) => ({
      email: u.email ?? "",
      lastSignIn: u.last_sign_in_at ?? null,
      admin: adminEmails.has((u.email ?? "").toLowerCase()),
    })),
  });
}

async function adminPing() {
  const started = Date.now();
  const { error } = await service().from("digests").select("id").limit(1);
  return json({ ok: !error, pingMs: Date.now() - started, message: error?.message ?? null });
}

async function adminResetUsage() {
  const { error } = await service().from("usage_events").delete().gte("id", 0);
  return json({ ok: !error, message: error?.message ?? null });
}

/** The last few "Daily digest" runs on GitHub; empty when the GitHub token isn't set. */
async function recentWorkflowRuns() {
  const token = Deno.env.get("GH_DISPATCH_TOKEN");
  const repo = Deno.env.get("GH_REPO");
  if (!token || !repo) return [];
  const res = await fetch(`https://api.github.com/repos/${repo}/actions/workflows/daily-digest.yml/runs?per_page=8`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" },
  }).catch(() => null);
  if (!res?.ok) return [];
  return ((await res.json()).workflow_runs ?? []).map((r: any) => ({
    id: r.id,
    at: r.created_at,
    event: r.event,
    // "success" | "failure" | "cancelled" once finished; otherwise "queued" | "in_progress".
    result: r.conclusion ?? r.status,
  }));
}

/** Visits reported by the NewsDigest-Web server (see its src/services/visitLog.ts). */
async function logWeb(req: Request, body: any) {
  const key = Deno.env.get("WEB_LOG_KEY");
  if (!key || req.headers.get("X-Web-Log-Key") !== key) return json({ ok: false, reason: "error", message: "Not allowed" }, 403);
  const text = (v: unknown, max: number) => (typeof v === "string" && v ? v.slice(0, max) : null);
  const rows = (Array.isArray(body.events) ? body.events : []).slice(0, 100).map((e: any) => ({
    email: "web",
    action: text(e.action, 80) ?? "unknown",
    ok: e.ok !== false,
    status: Number.isInteger(e.status) ? e.status : null,
    latency_ms: Number.isFinite(e.latencyMs) ? Math.round(e.latencyMs) : null,
    device: text(e.device, 40),
    ip: text(e.ip, 45),
    user_agent: text(e.userAgent, 200),
    ...(typeof e.at === "string" && !Number.isNaN(Date.parse(e.at)) ? { at: new Date(Date.parse(e.at)).toISOString() } : {}),
  }));
  if (!rows.length) return json({ ok: true, saved: 0 });
  // A flood of visits must not fill the database: keep at most 1,000 web rows an hour and 7 days of them.
  const db = service();
  await db.from("usage_events").delete().eq("email", "web").lt("at", new Date(Date.now() - 7 * 86_400_000).toISOString());
  const { count } = await db.from("usage_events").select("id", { count: "exact", head: true })
    .eq("email", "web").gte("at", new Date(Date.now() - 3_600_000).toISOString());
  const room = Math.max(0, 1000 - (count ?? 0));
  if (!room) return json({ ok: true, saved: 0, message: "Hourly limit reached" });
  const { error } = await db.from("usage_events").insert(rows.slice(0, room));
  return json({ ok: !error, saved: error ? 0 : Math.min(rows.length, room), message: error?.message ?? null });
}

/** One account may make 40 AI requests (summarize, ask, read aloud) a minute, so a runaway client can't drain the keys. */
async function overAILimit(email?: string): Promise<boolean> {
  if (!email) return false;
  const { count } = await service().from("usage_events").select("id", { count: "exact", head: true })
    .eq("email", email).in("action", ["summarize", "chat", "speak"]).gte("at", new Date(Date.now() - 60_000).toISOString());
  return (count ?? 0) >= 40;
}

const ADMIN_ACTIONS: Record<string, (body: any) => Promise<Response>> = {
  run_digest: runDigest,
  admin_overview: adminOverview,
  admin_ping: adminPing,
  admin_reset_usage: adminResetUsage,
};
const ACTIONS = ["summarize", "chat", "speak", "whoami", ...Object.keys(ADMIN_ACTIONS)];

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, reason: "error", message: "POST only" }, 405);
  const started = Date.now();
  const body = await req.json().catch(() => ({}));
  // The website's server reports visits with its own key instead of a user sign-in.
  if (body.action === "log_web") return logWeb(req, body);

  // Only signed-in users of this project.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return json({ ok: false, reason: "error", message: "Sign in first" }, 401);
  const email = data.user.email;

  const action = ACTIONS.includes(body.action) ? body.action : "summarize";

  let res: Response;
  if (action === "whoami") res = json({ ok: true, admin: await isAdmin(email) });
  else if (action in ADMIN_ACTIONS) {
    if (!(await isAdmin(email))) res = json({ ok: false, reason: "error", message: "Only an admin can do this." }, 403);
    else res = await ADMIN_ACTIONS[action](body);
  } else if (await overAILimit(email)) {
    res = json({ ok: false, reason: "busy", retryAfter: 30, message: "Too many AI requests in a minute. Try again shortly." });
  } else if (action === "chat") res = await chat(body);
  else if (action === "speak") res = await speak(body);
  else res = await summarize(body);

  // For the Admin usage screen. Looking at that screen isn't itself counted.
  if (!action.startsWith("admin_")) {
    const ok = (await res.clone().json().catch(() => ({}))).ok === true;
    // The app says what it runs on (iPhone / iPad / Simulator); see DigestStore.invokeFunction.
    const device = (req.headers.get("X-Device") ?? "").replace(/[^\w .-]/g, "").slice(0, 40) || null;
    const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim().slice(0, 45) || null;
    const user_agent = (req.headers.get("user-agent") ?? "").slice(0, 200) || null;
    await service().from("usage_events")
      .insert({ email, action, ok, latency_ms: Date.now() - started, device, ip, user_agent, status: res.status })
      .then(() => undefined, () => undefined);
  }
  return res;
});
