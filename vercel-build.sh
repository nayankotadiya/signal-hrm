#!/usr/bin/env bash
# Signal HRM Vercel Build Script for Flutter Web PWA
set -euo pipefail

echo "=================================================="
echo "🚀 Building Signal HRM Web for Vercel"
echo "=================================================="

# 1. Download Flutter SDK if not cached
if [ ! -d "flutter" ]; then
  echo "==> Cloning Flutter stable SDK..."
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git flutter
fi

export PATH="$PWD/flutter/bin:$PATH"
echo "==> Flutter SDK version:"
flutter --version

# 2. Get dependencies for shared UI package
echo "==> Resolving dependencies for packages/n_ui..."
(cd packages/n_ui && flutter pub get)

# 3. Resolve dependencies and build release for apps/web
echo "==> Building apps/web release..."
cd apps/web
flutter pub get

# Default API URL fallback if not set in Vercel environment variables
API_URL="${API_BASE_URL:-https://signal-hrm-api.onrender.com/api}"
GOOGLE_ID="${GOOGLE_CLIENT_ID:-496408398091-dtkgg1289q8uv2dqupahuiooc3c52ui2.apps.googleusercontent.com}"
echo "==> Target API URL: $API_URL"

flutter build web --release --no-web-resources-cdn \
  --dart-define=APP_ENV=production \
  --dart-define=API_BASE_URL="$API_URL" \
  --dart-define=GOOGLE_CLIENT_ID="$GOOGLE_ID" \
  --dart-define=PASSWORD_LOGIN=true

echo "=================================================="
echo "✅ Build complete! Assets in apps/web/build/web"
echo "=================================================="
