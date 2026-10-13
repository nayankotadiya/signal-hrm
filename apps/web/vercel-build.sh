#!/usr/bin/env bash
# Builds the Signal HRM web app on Vercel (Vercel has no Flutter preinstalled).
#   install: downloads the Flutter SDK (cached between builds) and fetches packages
#   build:   compiles the release web app into build/web
# Settings come from Vercel → Project → Settings → Environment Variables:
#   FLUTTER_VERSION   Flutter release to build with (default: stable). Pin it to the version you test with,
#                     e.g. 3.41.2 — run `flutter --version` on your PC.
#   PASSWORD_LOGIN    true to show password sign-in (default true)
#   GOOGLE_CLIENT_ID, APPLE_CLIENT_ID, APPLE_REDIRECT_URI   optional sign-in buttons
set -euo pipefail
cd "$(dirname "$0")"
FLUTTER_VERSION="${FLUTTER_VERSION:-stable}"
FLUTTER="$PWD/.flutter-sdk/bin/flutter"

case "${1:-}" in
  install)
    if [ ! -x "$FLUTTER" ]; then
      echo "Downloading Flutter ($FLUTTER_VERSION)…"
      git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git .flutter-sdk
    fi
    "$FLUTTER" config --no-analytics >/dev/null
    "$FLUTTER" --version
    "$FLUTTER" pub get
    ;;
  build)
    "$FLUTTER" build web --release --no-web-resources-cdn \
      --dart-define=APP_ENV=production \
      --dart-define=API_BASE_URL=/api \
      --dart-define=PASSWORD_LOGIN="${PASSWORD_LOGIN:-true}" \
      --dart-define=GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" \
      --dart-define=APPLE_CLIENT_ID="${APPLE_CLIENT_ID:-}" \
      --dart-define=APPLE_REDIRECT_URI="${APPLE_REDIRECT_URI:-}"
    ;;
  *)
    echo "usage: vercel-build.sh install|build" >&2
    exit 2
    ;;
esac
