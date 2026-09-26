export type PaperId = "dailystar" | "prothomalo";

export const CATEGORIES = [
  "Bangladesh Affairs",
  "International Affairs",
  "Economy",
  "Science & Tech",
  "Environment",
  "Sports",
  "Others",
] as const;
export type Category = (typeof CATEGORIES)[number];

/** One article's real text from the e-paper (not read off the image). */
export interface Story {
  storyId: string;
  headline: string;
  body: string;
  captions: string[];
}

export interface PageImage {
  pageNo: number;
  sequence: number;
  name: string;
  /** The e-paper's page id (used to open that exact page in the app). */
  pageId: string;
  mime: string;
  data: Buffer;
  /** Article text for this page, when the reader provides it. */
  stories?: Story[];
}

export interface DigestItem {
  headline: string;
  bullets: string[];
  keyFacts: string[];
  bcsRelevance: "high" | "medium";
  page: number;
  pageId?: string;
  /** The paper's own headline and opening lines, when the story came from text. */
  sourceHeadline?: string;
  excerpt?: string;
  /** Model that read the page; the app warns when a lighter model read an image. */
  model?: string;
  /** "paper" = AI unavailable; the paper's own headline and text, not summarized. */
  source?: "image" | "text" | "paper";
  /** Index of the story in the page's article list (text mode only). */
  story?: number;
}

export interface DigestSection {
  category: Category;
  items: DigestItem[];
}

export interface Mcq {
  question: string;
  options: string[];
  answer: string;
  model?: string;
  source?: "image" | "text";
}

export interface PageSummary {
  sections: DigestSection[];
  mcqs: Mcq[];
}

/** Login no longer valid: the user must refresh the saved session / credentials. */
export class LoginError extends Error {}
/** The site asked for a CAPTCHA or OTP. We stop instead of trying to get around it. */
export class ChallengeError extends Error {}
/** Today's edition isn't up yet. */
export class NotPublishedError extends Error {}
