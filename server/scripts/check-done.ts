import "dotenv/config";
import { appendFileSync } from "node:fs";
import { parseDay, recentDays } from "../src/papers/common.js";
import { hasDigest } from "../src/supabase.js";
import type { PaperId } from "../src/types.js";

// Tells the hourly workflow whether the last week's digests all exist (or one --date's), so it can
// stop before installing a browser. Usage: npm run check-done -- [--paper dailystar|prothomalo] [--date YYYY-MM-DD]
const i = process.argv.indexOf("--paper");
const only = (i === -1 ? "" : process.argv[i + 1] ?? "") as PaperId | "";
const papers: PaperId[] = only ? [only] : ["dailystar", "prothomalo"];
const j = process.argv.indexOf("--date");
const dates = (j === -1 ? recentDays() : [parseDay(process.argv[j + 1] ?? "")]).map((d) => d.iso);

const done = (await Promise.all(dates.flatMap((d) => papers.map((p) => hasDigest(d, p))))).every(Boolean);
console.log(done ? `All digests for ${dates.join(", ")} exist; nothing to do.` : `Digests still pending among ${dates.join(", ")}.`);
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `done=${done}\n`);
