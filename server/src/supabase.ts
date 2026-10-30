import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { DigestSection, Mcq, PageSummary, PaperId } from "./types.js";

let client: SupabaseClient | undefined;

function db(): SupabaseClient {
  if (client) return client;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set");
  client = createClient(url, key, { auth: { persistSession: false } });
  return client;
}

export async function saveDigest(row: {
  date: string;
  paper: PaperId;
  sections: DigestSection[];
  mcqs: Mcq[];
  page_count: number;
}) {
  const { error } = await db().from("digests").upsert(row, { onConflict: "date,paper" });
  if (error) throw new Error(`Supabase digests upsert: ${error.message}`);
}

export type RunState = "ok" | "login_expired" | "challenge" | "not_published" | "error";

export async function saveStatus(row: { date: string; paper: PaperId; state: RunState; message?: string }) {
  const { error } = await db()
    .from("run_status")
    .upsert({ ...row, message: row.message ?? null, updated_at: new Date().toISOString() }, { onConflict: "date,paper" });
  if (error) throw new Error(`Supabase run_status upsert: ${error.message}`);
}

export async function hasDigest(date: string, paper: PaperId): Promise<boolean> {
  const { count, error } = await db()
    .from("digests")
    .select("id", { count: "exact", head: true })
    .eq("date", date)
    .eq("paper", paper);
  if (error) throw new Error(`Supabase digests lookup: ${error.message}`);
  return (count ?? 0) > 0;
}

// Pages finished so far, by page id, so a run cut off by the time limit is continued by the next one.
// Kept in Storage because it's a temporary file, gone once the digest is saved. Never fails a run.
const PROGRESS_BUCKET = "digest-progress";
export type Progress = Record<string, PageSummary>;

export async function loadProgress(date: string, paper: PaperId): Promise<Progress> {
  const { data, error } = await db().storage.from(PROGRESS_BUCKET).download(`${date}/${paper}.json`);
  if (error || !data) return {};
  return (JSON.parse(await data.text()) as Progress) ?? {};
}

let bucketReady = false;

export async function saveProgress(date: string, paper: PaperId, progress: Progress) {
  try {
    if (!bucketReady) {
      // Errors if it already exists, which is fine.
      await db().storage.createBucket(PROGRESS_BUCKET, { public: false });
      bucketReady = true;
    }
    const { error } = await db()
      .storage.from(PROGRESS_BUCKET)
      .upload(`${date}/${paper}.json`, JSON.stringify(progress), { upsert: true, contentType: "application/json" });
    if (error) throw error;
  } catch (e) {
    console.warn(`  couldn't save progress: ${(e as Error).message}`);
  }
}

export async function clearProgress(date: string, paper: PaperId) {
  await db().storage.from(PROGRESS_BUCKET).remove([`${date}/${paper}.json`]).then(() => undefined, () => undefined);
}

/** Counts one page the digest summarized, for the app's Admin usage screen. Never fails a run. */
export async function logUsage(ok: boolean, latencyMs: number) {
  await db()
    .from("usage_events")
    .insert({ email: "server", action: "digest", ok, latency_ms: latencyMs, device: process.env.CI ? "GitHub" : "Mac" })
    .then(() => undefined, () => undefined);
}
