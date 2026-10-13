# Signal HRM web (Flutter PWA) served by Caddy, which also proxies the API on the same origin.
#   docker build -f apps/web/Dockerfile -t signal-hrm-web .
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /src
COPY packages/n_ui ./packages/n_ui
COPY apps/web ./apps/web
WORKDIR /src/apps/web
ARG APP_ENV=production
ARG PASSWORD_LOGIN=false
ARG GOOGLE_CLIENT_ID=
ARG APPLE_CLIENT_ID=
ARG APPLE_REDIRECT_URI=
# --no-web-resources-cdn: CanvasKit is served from our own origin (strict CSP, no third-party CDN).
RUN flutter pub get && flutter build web --release --no-web-resources-cdn \
      --dart-define=APP_ENV=$APP_ENV --dart-define=API_BASE_URL=/api --dart-define=PASSWORD_LOGIN=$PASSWORD_LOGIN \
      --dart-define=GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID --dart-define=APPLE_CLIENT_ID=$APPLE_CLIENT_ID --dart-define=APPLE_REDIRECT_URI=$APPLE_REDIRECT_URI

FROM caddy:2.8-alpine
COPY --from=build /src/apps/web/build/web /srv/www
COPY infra/Caddyfile /etc/caddy/Caddyfile
