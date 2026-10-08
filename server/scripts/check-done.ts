import "dotenv/config";
import { appendFileSync } from "node:fs";
import { dhakaDate, parseDay } from "../src/papers/common.js";
import { hasDigest } from "../src/supabase.js";
import type { PaperId } from "../src/types.js";

// Tells the hourly workflow whether today's digests already exist, so it can stop
// before installing a browser. Usage: npm run check-done -- [--paper dailystar|prothomalo] [--date YYYY-MM-DD]
const i = process.argv.indexOf("--paper");
const only = (i === -1 ? "" : process.argv[i + 1] ?? "") as PaperId | "";
const papers: PaperId[] = only ? [only] : ["dailystar", "prothomalo"];
const j = process.argv.indexOf("--date");
const date = (j === -1 ? dhakaDate() : parseDay(process.argv[j + 1] ?? "")).iso;

const done = (await Promise.all(papers.map((p) => hasDigest(date, p)))).every(Boolean);
console.log(done ? `All digests for ${date} exist; nothing to do.` : `Digests for ${date} still pending.`);
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `done=${done}\n`);
