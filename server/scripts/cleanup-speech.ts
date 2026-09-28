import "dotenv/config";
import { createClient } from "@supabase/supabase-js";

// Deletes read-aloud audio older than SPEECH_KEEP_DAYS (default 3) from the "speech" bucket,
// so saved voices don't fill the free Storage quota. Usage: npm run cleanup-speech
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set");
const storage = createClient(url, key, { auth: { persistSession: false } }).storage.from("speech");
const cutoff = Date.now() - Number(process.env.SPEECH_KEEP_DAYS || 3) * 86_400_000;

// Files live in one folder per voice: <voice>/<hash>.wav
const { data: folders, error } = await storage.list("", { limit: 1000 });
if (error) throw new Error(`Storage list: ${error.message}`);
let removed = 0;
for (const folder of folders ?? []) {
  if (folder.id) continue;  // a file at the root, not a folder
  for (;;) {
    const { data: files, error } = await storage.list(folder.name, { limit: 1000, sortBy: { column: "created_at", order: "asc" } });
    if (error) throw new Error(`Storage list ${folder.name}: ${error.message}`);
    const old = (files ?? []).filter((f) => f.created_at && Date.parse(f.created_at) < cutoff).map((f) => `${folder.name}/${f.name}`);
    if (!old.length) break;
    const { error: delError } = await storage.remove(old);
    if (delError) throw new Error(`Storage remove: ${delError.message}`);
    removed += old.length;
    if (old.length < (files ?? []).length) break;  // the rest are newer
  }
}
console.log(`Removed ${removed} old read-aloud files.`);
