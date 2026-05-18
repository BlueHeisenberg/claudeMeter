#!/usr/bin/env bash
# Local-use only: Anthropic's API does not set CORS headers for arbitrary
# origins, so the web build needs Chrome started with web security disabled.
# Use a throwaway profile so you don't expose your real Chrome session.
set -euo pipefail
PROFILE_DIR="${TMPDIR:-/tmp}/claude-meter-chrome"
mkdir -p "$PROFILE_DIR"
exec flutter run -d chrome \
  --web-browser-flag "--disable-web-security" \
  --web-browser-flag "--user-data-dir=$PROFILE_DIR"
