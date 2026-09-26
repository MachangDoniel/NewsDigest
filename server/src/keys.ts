const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Comma-separated API keys from env (e.g. GEMINI_API_KEYS="k1,k2"), used round-robin.
 * On 429/5xx the next key is tried; once every key has failed, back off and retry a few times.
 */
export class KeyPool {
  private next = 0;
  constructor(private listVar: string, private singleVar?: string) {}

  keys(): string[] {
    const raw = process.env[this.listVar] || (this.singleVar ? process.env[this.singleVar] : "") || "";
    return raw.split(",").map((k) => k.trim()).filter(Boolean);
  }

  configured() {
    return this.keys().length > 0;
  }

  async fetchWithRotation(send: (key: string) => Promise<Response>, opts: { backoff?: boolean } = {}): Promise<Response> {
    const backoff = opts.backoff ?? true;
    const keys = this.keys();
    if (keys.length === 0) throw new Error(`${this.listVar} is not set`);
    for (let attempt = 1; ; attempt++) {
      const res = await send(keys[this.next++ % keys.length]);
      const retryable = res.status === 429 || res.status >= 500;
      if (res.ok || !retryable || attempt >= keys.length + (backoff ? 2 : 0)) return res;
      if (attempt >= keys.length) await sleep(15_000 * (attempt - keys.length + 1));
    }
  }
}
