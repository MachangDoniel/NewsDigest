import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { DigestSection, Mcq, PaperId } from "./types.js";

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
