import type { BrowserContext, Page } from "playwright";
import { ChallengeError, type PageImage } from "../types.js";

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

/** Throws if the page is showing a CAPTCHA / bot check. We never try to solve these. */
export async function assertNoChallenge(page: Page) {
  const challenge = await page
    .locator('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="challenges.cloudflare"], #cf-challenge-running')
    .count();
  if (challenge > 0) throw new ChallengeError(`CAPTCHA / bot check shown at ${page.url()}`);
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
    pages.push({ pageNo: tag.pageNo, sequence: tag.sequence, name: tag.name, mime: img.mime, data: img.data });
  }
  pages.sort((a, b) => a.sequence - b.sequence);
  return { pages, failed };
}
