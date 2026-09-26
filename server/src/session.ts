import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { PaperId } from "./types.js";

export const SESSIONS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../.sessions");

const ENV_NAME: Record<PaperId, string> = {
  prothomalo: "PROTHOMALO_SESSION",
  dailystar: "DAILYSTAR_SESSION",
};

/**
 * Returns a Playwright storageState object for the paper.
 * Checks the env secret first (base64 JSON, used in GitHub Actions), then the local .sessions/<paper>.json file.
 */
export function loadSession(paper: PaperId): any | undefined {
  const b64 = process.env[ENV_NAME[paper]];
  if (b64) return JSON.parse(Buffer.from(b64, "base64").toString("utf8"));
  const file = path.join(SESSIONS_DIR, `${paper}.json`);
  if (existsSync(file)) return JSON.parse(readFileSync(file, "utf8"));
  return undefined;
}
