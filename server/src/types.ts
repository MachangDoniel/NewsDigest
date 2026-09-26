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

export interface PageImage {
  pageNo: number;
  sequence: number;
  name: string;
  mime: string;
  data: Buffer;
}

export interface DigestItem {
  headline: string;
  bullets: string[];
  keyFacts: string[];
  bcsRelevance: "high" | "medium";
  page: number;
  /** Model that read the page; the app warns when it was a lighter fallback model. */
  model?: string;
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
