# Claude Meter

A tiny Flutter app that shows your Claude Code subscription usage at a
glance — the same numbers Claude Code's `/usage` command reports (5-hour
session bucket and weekly bucket, with reset timers), styled like a small
ambient status device.

Designed to sit fullscreen-landscape on a phone propped on your desk. Works
as:
- a **native Android app** (APK), or
- a **PWA** installed from a web URL (GitHub Pages).

## How it works

The app authenticates with your real Claude account via OAuth (PKCE, no
hardcoded tokens). On sign-in it polls Anthropic's `/api/oauth/usage`
endpoint — the same one the official Claude Code CLI calls for `/usage` —
and renders the response.

The web build can't reach `api.anthropic.com` directly (no CORS), so it
goes through a small Cloudflare Worker that just relays the call and adds
CORS headers. The Worker doesn't store or log tokens; it forwards the
`Authorization` header to Anthropic and returns the response verbatim.

**Heads-up:** `/api/oauth/usage` is undocumented; discovered by inspecting
the Claude Code CLI binary. It could change or break without notice. Fan
project, not affiliated with Anthropic.

## Features

- OAuth sign-in via system browser (Google, email, or any provider
  Claude.ai supports — its standard login page)
- Refresh tokens persisted locally; auto access-token refresh on 401
- Live 5-hour and weekly usage bars with reset timers
- Exponential backoff (30m → 60m → 120m) on rate limits, persisted across
  restarts
- 10-min poll cadence, paused while the app is in background
- On Android: landscape lock, immersive-mode fullscreen, screen wakelock,
  real device battery indicator with charging bolt
- On web: PWA install for fullscreen + landscape, falls back to
  Fullscreen-API-on-first-tap in regular browsers

## Run locally

```bash
flutter pub get

# Android device or emulator
flutter run -d <device-id>

# Release APK
flutter build apk --release
```

Web locally needs `--disable-web-security` because Anthropic doesn't return
CORS headers (the Worker handles this when deployed):

```bash
./run-web.sh
```

## Deploy

A single GitHub Actions workflow ([`deploy.yml`](.github/workflows/deploy.yml))
does everything on every push to `main`: deploys the Cloudflare Worker,
reads back its URL via the CF API, builds the Flutter web app with that
URL baked in, and publishes to GitHub Pages.

### One-time setup

1. **Sign up for Cloudflare** (free, email-only, no card).
2. **Create an API token**: *Profile → API Tokens → Create Token → "Edit
   Cloudflare Workers" template → Continue → Create Token*. Copy the token.
3. **Copy your Account ID**: visible on any Workers dashboard page in the
   right sidebar.
4. **Push the repo to GitHub.** In *Settings → Pages*, set **Source** to
   *GitHub Actions*.
5. **Add two repo secrets** under *Settings → Secrets and variables →
   Actions → Secrets*:

   | Secret name              | Value                       |
   | ------------------------ | --------------------------- |
   | `CLOUDFLARE_API_TOKEN`   | token from step 2           |
   | `CLOUDFLARE_ACCOUNT_ID`  | account ID from step 3      |

6. **Push (or run *Actions → Deploy → Run workflow*).** The workflow
   deploys the Worker, builds the web app, deploys to Pages. The Pages URL
   appears in the workflow summary when it's done.

After this, every push to `main` redeploys both halves automatically. No
URLs or variables to maintain by hand.

### Install on your phone

Open the GitHub Pages URL in mobile Chrome / Safari and use **Add to Home
Screen**. The PWA installs as a fullscreen, landscape-locked app — looks
and behaves like a native one.

## Capacity

| Setup                       | Free? | Capacity                |
| --------------------------- | ----- | ----------------------- |
| GitHub Pages                | yes   | 100 GB bandwidth/month  |
| Cloudflare Workers free     | yes   | 100 000 requests/day    |
| 10-min poll, background-paused | — | ≈30–50 req/user/day → ≈2 000–3 000 users |
| Cloudflare Workers paid     | $5/mo | 10 M requests/month     |

## Permissions / dependencies

- Android: `INTERNET` only.
- Flutter packages: `http`, `shared_preferences`, `battery_plus`,
  `wakelock_plus`, `url_launcher`, `crypto`. No analytics, no telemetry,
  no third-party services beyond Anthropic and your own Cloudflare Worker.

## Endpoints

| Purpose          | URL                                                 |
| ---------------- | --------------------------------------------------- |
| OAuth authorize  | `https://claude.ai/oauth/authorize`                 |
| OAuth token      | `https://platform.claude.com/v1/oauth/token`        |
| OAuth redirect   | `https://platform.claude.com/oauth/code/callback`   |
| Usage            | `https://api.anthropic.com/api/oauth/usage`         |

OAuth client ID `9d1c250a-…` is the public Claude Code CLI client. Scopes
match the CLI exactly: `user:file_upload user:inference user:mcp_servers
user:profile user:sessions:claude_code`.

## License

MIT — see [`LICENSE`](LICENSE).
