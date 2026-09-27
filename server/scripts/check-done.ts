import "dotenv/config";
import { appendFileSync } from "node:fs";
import { dhakaDate } from "../src/papers/common.js";
import { hasDigest } from "../src/supabase.js";
import type { PaperId } from "../src/types.js";

// Tells the hourly workflow whether today's digests already exist, so it can stop
// before installing a browser. Usage: npm run check-done -- [--paper dailystar|prothomalo]
const i = process.argv.indexOf("--paper");
const only = (i === -1 ? "" : process.argv[i + 1] ?? "") as PaperId | "";
const papers: PaperId[] = only ? [only] : ["dailystar", "prothomalo"];
const date = dhakaDate().iso;

const done = (await Promise.all(papers.map((p) => hasDigest(date, p)))).every(Boolean);
console.log(done ? `All digests for ${date} exist; nothing to do.` : `Digests for ${date} still pending.`);
if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `done=${done}\n`);
