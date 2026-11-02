import type { BrowserContext, Page } from "playwright";
import { ChallengeError, LoginError, SignInUnavailableError, type PageImage } from "../types.js";

/** Today's date in Dhaka as { y, m, d } strings, zero-padded. */
export function dhakaDate(date = new Date()) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Dhaka",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const get = (t: string) => parts.find((p) => p.type === t)!.value;
  return { y: get("year"), m: get("month"), d: get("day"), iso: `${get("year")}-${get("month")}-${get("day")}` };
}

export type Day = ReturnType<typeof dhakaDate>;

/** Today and the 7 days before it, newest first. Scheduled runs fill in whatever is missing from these. */
export function recentDays(count = 8): Day[] {
  return Array.from({ length: count }, (_, i) => dhakaDate(new Date(Date.now() - i * 24 * 60 * 60 * 1000)));
}

/** A given YYYY-MM-DD edition date, in the same shape as dhakaDate(). */
export function parseDay(iso: string): Day {
  const match = iso.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) throw new Error(`--date must look like 2026-10-07, got "${iso}"`);
  const [, y, m, d] = match;
  return { y, m, d, iso };
}

let personWatching = false;
/** The browser window is visible and someone is at the Mac to answer a check themselves. */
export function setPersonWatching(on: boolean) {
  personWatching = on;
}

/** Throws if the page is showing a CAPTCHA / bot check. We never try to solve these. */
export async function assertNoChallenge(page: Page) {
  // Cloudflare's "Just a moment..." page. Its check sits in a closed shadow root, so the selector
  // below can't see it. It sometimes clears by itself; give it a moment before giving up.
  const interstitial = async () => /^just a moment/i.test(await page.title().catch(() => ""));
  const shown = async () =>
    (await interstitial()) ||
    (await page
      .locator('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="challenges.cloudflare"], #cf-challenge-running')
      .count()
      .catch(() => 0)) > 0;
  for (let i = 0; i < 10 && (await interstitial()); i++) await page.waitForTimeout(2000);
  if (personWatching && (await shown())) {
    console.log("  → A check is showing in the browser window. Answer it there; waiting up to 5 minutes…");
    for (let i = 0; i < 150 && (await shown()); i++) await page.waitForTimeout(2000);
    await page.waitForLoadState("domcontentloaded").catch(() => undefined);
  }
  if (await shown()) {
    const { origin, pathname } = new URL(page.url());
    throw new ChallengeError(`CAPTCHA / bot check shown at ${origin}${pathname}`);
  }
}

const SIGN_IN_TRIES = 3;
const SIGN_IN_RETRY_MS = Number(process.env.SIGN_IN_RETRY_SECONDS || 15) * 1000;
const SIGN_IN_TIMEOUT_MS = Number(process.env.SIGN_IN_TIMEOUT_SECONDS || 45) * 1000;

/**
 * Opens the sign-in page, fills it in and submits, and returns the signed-in page.
 * LoginError means the site turned the credentials down. A slow or failing site is retried, then
 * thrown as SignInUnavailableError, so a bad night on their side doesn't read as an expired login.
 */
export async function signInWithRetry(
  context: BrowserContext,
  opts: { paper: string; url: string; signedIn: (u: URL) => boolean; submit: (page: Page) => Promise<void> },
): Promise<Page> {
  let last = "";
  for (let attempt = 1; attempt <= SIGN_IN_TRIES; attempt++) {
    const page = await context.newPage();
    try {
      await page.goto(opts.url, { waitUntil: "domcontentloaded" });
      await assertNoChallenge(page);
      const formHost = new URL(page.url()).hostname;
      // The site answered the form with "no". 408 and 429 are it being busy, not a verdict on the login.
      let rejected: number | undefined;
      page.on("response", (res) => {
        const status = res.status();
        if (res.request().method() === "POST" && new URL(res.url()).hostname === formHost && status >= 400 && status < 500 && status !== 408 && status !== 429) {
          rejected = status;
        }
      });
      await Promise.all([page.waitForURL(opts.signedIn, { timeout: SIGN_IN_TIMEOUT_MS }).catch(() => undefined), opts.submit(page)]);
      await assertNoChallenge(page);
      if (opts.signedIn(new URL(page.url()))) return page;
      if (rejected) throw new LoginError(`${opts.paper} rejected the login (HTTP ${rejected})`);
      last = `still on ${formHost} after ${SIGN_IN_TIMEOUT_MS / 1000}s`;
    } catch (e) {
      if (e instanceof LoginError || e instanceof ChallengeError) throw e;
      last = (e as Error).message.split("\n")[0];
    }
    await page.close();
    console.warn(`  sign-in try ${attempt}/${SIGN_IN_TRIES} failed: ${last}`);
    if (attempt < SIGN_IN_TRIES) await new Promise((r) => setTimeout(r, SIGN_IN_RETRY_MS));
  }
  throw new SignInUnavailableError(`${opts.paper} sign-in didn't finish after ${SIGN_IN_TRIES} tries; the site may be slow or down (${last})`);
}

/**
 * Reads the page-image <img> tags the e-paper reader puts in the DOM.
 * Prefers the highest-resolution URL the site exposes in its attributes.
 */
export async function readPageImageTags(page: Page, selector: string) {
  return page.$$eval(selector, (imgs) =>
    imgs.map((img, i) => ({
      urls: [img.getAttribute("xhighres"), img.getAttribute("highres"), img.getAttribute("data-src"), img.getAttribute("src")]
        .filter((u): u is string => !!u && /^https?:/.test(u)),
      pageNo: Number(img.getAttribute("pageno") ?? i + 1),
      sequence: Number(img.getAttribute("sequence") ?? i + 1),
      name: img.getAttribute("pgname") ?? img.getAttribute("alt") ?? `Page ${i + 1}`,
      id: img.getAttribute("page_id") ?? img.id ?? String(i),
    })),
  );
}

/** Downloads the first URL that returns a real image, using the context's login cookies. */
export async function downloadFirst(context: BrowserContext, urls: string[], referer: string) {
  for (const url of urls) {
    const res = await context.request.get(url, { headers: { Referer: referer }, failOnStatusCode: false });
    const type = res.headers()["content-type"] ?? "";
    if (res.ok() && type.startsWith("image/")) {
      const data = await res.body();
      if (data.length > 20_000) return { data, mime: type.split(";")[0], url };
    }
  }
  return null;
}

export type TagList = Awaited<ReturnType<typeof readPageImageTags>>;

export async function downloadPages(context: BrowserContext, tags: TagList, referer: string): Promise<{ pages: PageImage[]; failed: TagList }> {
  const seen = new Set<string>();
  const pages: PageImage[] = [];
  const failed: TagList = [];
  for (const tag of tags) {
    if (seen.has(tag.id)) continue;
    seen.add(tag.id);
    const img = await downloadFirst(context, tag.urls, referer);
    if (!img) {
      failed.push(tag);
      continue;
    }
    pages.push({ pageNo: tag.pageNo, sequence: tag.sequence, name: tag.name, pageId: tag.id, mime: img.mime, data: img.data });
  }
  pages.sort((a, b) => a.sequence - b.sequence);
  return { pages, failed };
}
