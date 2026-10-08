import type { Browser, BrowserContext } from "playwright";
import { LoginError, NotPublishedError, type PageImage } from "../types.js";
import { attachStories } from "./stories.js";
import { assertNoChallenge, dhakaDate, downloadPages, readPageImageTags, type Day } from "./common.js";
import { loadSession } from "../session.js";

const BASE = "https://epaper.prothomalo.com";
// Redirects to auth.prothomalo.com's sign-in page, then back to the reader after login.
const LOGIN_URL = `${BASE}/Login/LandingPage`;

/**
 * Signs in with PROTHOMALO_EMAIL / PROTHOMALO_PASSWORD (the site's own email + password form).
 * Falls back to a saved browser session (`npm run save-session prothomalo`) if no credentials are set.
 */
async function openContext(browser: Browser): Promise<BrowserContext> {
  const email = process.env.PROTHOMALO_EMAIL;
  const password = process.env.PROTHOMALO_PASSWORD;
  const viewport = { width: 1280, height: 1600 };

  if (!email || !password) {
    const storageState = loadSession("prothomalo");
    if (!storageState) throw new LoginError("Set PROTHOMALO_EMAIL / PROTHOMALO_PASSWORD (or save a session)");
    return browser.newContext({ storageState, viewport });
  }

  const context = await browser.newContext({ viewport });
  const page = await context.newPage();
  await page.goto(LOGIN_URL, { waitUntil: "domcontentloaded" });
  await assertNoChallenge(page);
  await page.fill('input[name="email"]', email);
  await page.fill('input[name="password"]', password);
  await Promise.all([
    page.waitForURL((u) => u.hostname === "epaper.prothomalo.com", { timeout: 45_000 }).catch(() => undefined),
    page.getByRole("button", { name: /^login$/i }).click(),
  ]);
  await assertNoChallenge(page);
  if (new URL(page.url()).hostname !== "epaper.prothomalo.com") {
    throw new LoginError("Prothom Alo login failed. Check PROTHOMALO_EMAIL / PROTHOMALO_PASSWORD");
  }
  await page.close();
  return context;
}

/**
 * The reader puts every page in the DOM as <img class="img_jpg"> with attributes:
 *   pageno, pgname, sequence, page_id, highres, xhighres, paywallpage
 */
export async function captureProthomAlo(browser: Browser, day: Day = dhakaDate()): Promise<PageImage[]> {
  const context = await openContext(browser);
  try {
    const { y, m, d } = day;
    const page = await context.newPage();
    await page.goto(`${BASE}/Home/DIndex?eid=1&edate=${d}/${m}/${y}`, { waitUntil: "domcontentloaded" });
    await assertNoChallenge(page);
    await page.waitForSelector("img.img_jpg", { timeout: 45_000 });

    const tags = await readPageImageTags(page, "img.img_jpg");
    if (!tags.some((t) => t.urls.some((u) => u.includes(`/${y}/${m}/${d}/`)))) {
      throw new NotPublishedError(`Prothom Alo edition for ${y}-${m}-${d} is not up yet`);
    }

    const { pages, failed } = await downloadPages(context, tags, page.url());
    // Pages behind the paywall only download with a valid subscriber login.
    if (pages.length === 0 || failed.length > tags.length / 2) {
      throw new LoginError("Prothom Alo page images could not be downloaded (login/subscription?)");
    }
    // Real article text; image reading stays as the fallback for pages without it.
    await attachStories(context, BASE, pages, page.url()).catch((e) => console.warn(`  article text unavailable: ${(e as Error).message}`));
    return pages;
  } finally {
    await context.close();
  }
}
