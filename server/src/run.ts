import "dotenv/config";
import { writeFileSync, mkdirSync } from "node:fs";
import { chromium, type Browser } from "playwright";
import { captureDailyStar } from "./papers/dailyStar.js";
import { captureProthomAlo } from "./papers/prothomAlo.js";
import { dhakaDate } from "./papers/common.js";
import { summarizePage } from "./gemini.js";
import { merge } from "./merge.js";
import { pagePrompt, type DigestLang } from "./prompt.js";
import { hasDigest, saveDigest, saveStatus, type RunState } from "./supabase.js";
import {
  CATEGORIES,
  ChallengeError,
  LoginError,
  NotPublishedError,
  type DigestSection,
  type Mcq,
  type PageImage,
  type PageSummary,
  type PaperId,
} from "./types.js";

// Usage: npm run digest -- [--paper dailystar|prothomalo] [--dry] [--force] [--max-pages N]
const args = process.argv.slice(2);
const flag = (name: string) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? undefined : args[i + 1] ?? "";
};
const DRY = args.includes("--dry");
const FORCE = args.includes("--force");
const MAX_PAGES = Number(flag("max-pages") ?? Infinity);
const ONLY = flag("paper") as PaperId | undefined;

const PAPERS: { id: PaperId; name: string; capture: (b: Browser) => Promise<PageImage[]> }[] = [
  { id: "dailystar", name: "The Daily Star", capture: captureDailyStar },
  { id: "prothomalo", name: "Prothom Alo", capture: captureProthomAlo },
];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
function stateFor(err: unknown): RunState {
  if (err instanceof LoginError) return "login_expired";
  if (err instanceof ChallengeError) return "challenge";
  if (err instanceof NotPublishedError) return "not_published";
  return "error";
}

async function runPaper(browser: Browser, paper: (typeof PAPERS)[number], date: string, lang: DigestLang) {
  console.log(`\n== ${paper.name} (${date})`);
  // The workflow runs a few times each morning; later runs only retry papers that aren't done.
  if (!DRY && !FORCE && (await hasDigest(date, paper.id))) {
    console.log("  already done, skipping");
    return;
  }
  const pages = (await paper.capture(browser)).slice(0, MAX_PAGES);
  console.log(`  captured ${pages.length} pages`);

  const delay = Number(process.env.GEMINI_DELAY_SECONDS || 7) * 1000;
  const summaries: PageSummary[] = [];
  for (const [i, p] of pages.entries()) {
    if (i > 0) await sleep(delay);
    try {
      const s = await summarizePage(p, pagePrompt({ paper: paper.name, pageName: p.name, pageNo: p.pageNo, lang }));
      const n = s.sections.reduce((a, x) => a + x.items.length, 0);
      console.log(`  page ${p.pageNo} ${p.name}: ${n} items`);
      summaries.push(s);
    } catch (e) {
      // One bad page shouldn't sink the whole digest.
      console.warn(`  page ${p.pageNo} failed: ${(e as Error).message}`);
    }
  }
  if (summaries.length === 0) throw new Error("Gemini failed on every page");

  const digest = await merge(summaries);
  if (DRY) {
    mkdirSync("out", { recursive: true });
    writeFileSync(`out/${date}-${paper.id}.json`, JSON.stringify(digest, null, 2));
    console.log(`  dry run → out/${date}-${paper.id}.json`);
    return;
  }
  await saveDigest({ date, paper: paper.id, ...digest, page_count: pages.length });
  await saveStatus({ date, paper: paper.id, state: "ok" });
  console.log(`  saved ${digest.sections.length} sections, ${digest.mcqs.length} MCQs`);
}

async function main() {
  const date = dhakaDate().iso;
  const lang = (process.env.DIGEST_LANG as DigestLang) || "en";
  const browser = await chromium.launch();
  let failures = 0;
  try {
    for (const paper of PAPERS.filter((p) => !ONLY || p.id === ONLY)) {
      try {
        await runPaper(browser, paper, date, lang);
      } catch (e) {
        const state = stateFor(e);
        const message = (e as Error).message;
        console.error(`  ✗ ${state}: ${message}`);
        // Not published yet isn't a failure; a later scheduled run picks it up.
        if (state !== "not_published") failures++;
        if (!DRY) await saveStatus({ date, paper: paper.id, state, message }).catch((err) => console.error(err));
      }
    }
  } finally {
    await browser.close();
  }
  process.exitCode = failures ? 1 : 0;
}

main();
