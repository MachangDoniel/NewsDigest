import { chromium } from "playwright";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import readline from "node:readline/promises";
import { SESSIONS_DIR } from "../src/session.js";
import type { PaperId } from "../src/types.js";

// Usage: npm run save-session prothomalo
// Opens a real Chrome window. YOU sign in (Google, etc.), then press Enter here.
// Only the site's cookies/localStorage are saved. No password is stored.

const START: Record<PaperId, string> = {
  prothomalo: "https://epaper.prothomalo.com",
  dailystar: "https://epaper.thedailystar.net",
};
const SECRET: Record<PaperId, string> = { prothomalo: "PROTHOMALO_SESSION", dailystar: "DAILYSTAR_SESSION" };

const paper = process.argv[2] as PaperId;
if (!START[paper]) {
  console.error("Usage: npm run save-session <prothomalo|dailystar>");
  process.exit(1);
}

// Installed Chrome (not Playwright's bundled Chromium): Google refuses sign-in from automation builds.
const browser = await chromium.launch({ headless: false, channel: "chrome", ignoreDefaultArgs: ["--enable-automation"] });
const context = await browser.newContext({ viewport: null });
const page = await context.newPage();
await page.goto(START[paper]);

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
await rl.question(`\nSign in to ${paper} in the browser window, open today's e-paper, then press Enter here… `);
rl.close();

mkdirSync(SESSIONS_DIR, { recursive: true });
const file = path.join(SESSIONS_DIR, `${paper}.json`);
writeFileSync(file, JSON.stringify(await context.storageState(), null, 2), { mode: 0o600 });
await browser.close();

console.log(`\nSaved ${file}`);
console.log(`Upload it to GitHub Secrets with:\n\n  base64 -i ${path.relative(process.cwd(), file)} | gh secret set ${SECRET[paper]}\n`);
