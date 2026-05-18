# claude-meter worker

A ~80-line Cloudflare Worker that lets the Flutter **web** build reach
Anthropic's API from a browser (it doesn't return CORS headers for arbitrary
origins, so a direct call would be blocked).

- It does NOT store, log, or transform request bodies or tokens.
- It exposes exactly two routes:
  - `GET /usage` → `https://api.anthropic.com/api/oauth/usage`
  - `POST /token` → `https://platform.claude.com/v1/oauth/token`
- The Android build talks to Anthropic directly and ignores this proxy.

## Deploy

```bash
# One-time
npm i -g wrangler
wrangler login   # opens browser, free Cloudflare account, no card

# Deploy
cd worker
wrangler deploy
```

Wrangler prints the URL, e.g. `https://claude-meter.<subdomain>.workers.dev`.
Paste it into `web/proxy_url.js` (next to `index.html`).

## Capacity

- Cloudflare free tier: 100,000 requests/day per account.
- Default polling: 10 min, paused while the tab is in background — typically
  ~30–50 requests/user/day → covers ~2,000–3,000 active users for free.
- If you ever hit the limit, the paid Worker tier is $5/month for 10M
  requests/month (≈35k users at this cadence).

## Privacy

The Worker forwards only:
- `Authorization` header
- `Content-Type` header
- `anthropic-beta` header
- The request body (for `/token`)

No logging is configured. To audit, see `index.js` — it's tiny.
