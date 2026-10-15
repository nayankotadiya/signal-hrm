#!/usr/bin/env bash
# Signal HRM Web build script for Vercel
set -euo pipefail
cd "$(dirname "$0")"

FLUTTER_VERSION="${FLUTTER_VERSION:-stable}"
FLUTTER="$PWD/.flutter-sdk/bin/flutter"

install_flutter() {
  if [ ! -x "$FLUTTER" ]; then
    echo "Downloading Flutter ($FLUTTER_VERSION)…"
    git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git .flutter-sdk
  fi
  "$FLUTTER" config --no-analytics >/dev/null
  "$FLUTTER" --version
  if [ -d "../../packages/n_ui" ]; then
    echo "Fetching packages/n_ui dependencies…"
    (cd ../../packages/n_ui && "$FLUTTER" pub get)
  fi
  "$FLUTTER" pub get
}

build_web() {
  API_URL="${API_BASE_URL:-https://signal-hrm-api.onrender.com/api}"
  echo "Building Flutter Web release for API: $API_URL"
  "$FLUTTER" build web --release --no-web-resources-cdn \
    --dart-define=APP_ENV=production \
    --dart-define=API_BASE_URL="$API_URL" \
    --dart-define=PASSWORD_LOGIN="${PASSWORD_LOGIN:-true}" \
    --dart-define=APPLE_CLIENT_ID="${APPLE_CLIENT_ID:-}" \
    --dart-define=APPLE_REDIRECT_URI="${APPLE_REDIRECT_URI:-}"
}

case "${1:-all}" in
  install)
    install_flutter
    ;;
  build)
    build_web
    ;;
  all|"")
    install_flutter
    build_web
    ;;
  *)
    echo "usage: vercel-build.sh [install|build|all]" >&2
    exit 2
    ;;
esac
