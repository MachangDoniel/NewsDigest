import type { Browser, BrowserContext, Page } from "playwright";
import { LoginError, NotPublishedError, type PageImage } from "../types.js";
import { assertNoChallenge, dhakaDate, downloadPages, readPageImageTags } from "./common.js";

const LOGIN_URL = "https://profile.thedailystar.net/login?redirect_to=https://epaper.thedailystar.net/Login/LandingPage";
const EPAPER = "https://epaper.thedailystar.net";
// Same reader markup as Prothom Alo (ASP.NET e-paper platform). Fallback: any large page image.
const PAGE_IMG = "img.img_jpg";

async function signIn(context: BrowserContext): Promise<Page> {
  const email = process.env.DAILYSTAR_EMAIL;
  const password = process.env.DAILYSTAR_PASSWORD;
  if (!email || !password) throw new LoginError("DAILYSTAR_EMAIL / DAILYSTAR_PASSWORD are not set");

  const page = await context.newPage();
  await page.goto(LOGIN_URL, { waitUntil: "domcontentloaded" });
  await assertNoChallenge(page);
  await page.fill('input[placeholder="Email"]', email);
  await page.fill('input[type="password"]', password);
  await Promise.all([
    page.waitForURL((u) => !u.hostname.startsWith("profile."), { timeout: 45_000 }).catch(() => undefined),
    page.getByRole("button", { name: /sign in/i }).first().click(),
  ]);
  await assertNoChallenge(page);
  if (new URL(page.url()).hostname.startsWith("profile.")) {
    throw new LoginError("Daily Star login failed. Check DAILYSTAR_EMAIL / DAILYSTAR_PASSWORD");
  }
  return page;
}

export async function captureDailyStar(browser: Browser): Promise<PageImage[]> {
  const context = await browser.newContext({ viewport: { width: 1280, height: 1600 } });
  try {
    const page = await signIn(context);
    const { y, m, d } = dhakaDate();

    // The landing page may show an edition picker; go straight to the reader if it isn't already open.
    if (!(await page.locator(PAGE_IMG).count())) {
      await page.goto(`${EPAPER}/Home/DIndex?eid=1&edate=${d}/${m}/${y}`, { waitUntil: "domcontentloaded" });
    }
    await assertNoChallenge(page);
    await page.waitForSelector(PAGE_IMG, { timeout: 45_000 }).catch(() => {
      throw new Error(`Daily Star reader layout not recognized at ${page.url()}. The selector in dailyStar.ts needs updating.`);
    });

    const tags = await readPageImageTags(page, PAGE_IMG);
    if (!tags.some((t) => t.urls.some((u) => u.includes(`/${y}/${m}/${d}/`)))) {
      throw new NotPublishedError(`Daily Star edition for ${y}-${m}-${d} is not up yet`);
    }
    const { pages } = await downloadPages(context, tags, page.url());
    if (pages.length === 0) throw new LoginError("Daily Star page images could not be downloaded (subscription/login?)");
    return pages;
  } finally {
    await context.close();
  }
}
