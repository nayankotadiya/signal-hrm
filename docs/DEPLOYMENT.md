# Deploying Signal HRM (Hostinger VPS + MongoDB Atlas)

One origin serves both the PWA and the API (Caddy proxies `/api` and `/ws`), so the refresh cookie stays first-party and CORS is not needed in production.

## 1. Prepare

1. **MongoDB Atlas:** one cluster, separate databases per environment (`signal_hrm_staging`, `signal_hrm_prod`). Create a database user limited to that database; allow the VPS IP in Network Access.
2. **VPS (Ubuntu 22.04+):** install Docker Engine and the compose plugin; open ports 80 and 443; point the DNS `A` record (e.g. `hrm.yourdomain.com`) at the VPS.
3. **Google Drive storage (optional):** a service account with a shared drive folder; put the JSON key on the server (never in the repo).
4. **SMTP:** any provider (Zoho, SES, Brevo…). Without SMTP nobody can receive sign-in codes in production.

## 2. Configure

```bash
git clone <your repo> signal-hrm && cd signal-hrm
cp apps/api/.env.example apps/api/.env.production
```

Edit `apps/api/.env.production` at least:

```
APP_ENV=production
PORT=3000
MONGODB_URI=mongodb+srv://USER:PASS@cluster.xxxx.mongodb.net/
MONGODB_DB_NAME=signal_hrm_prod
CORS_ORIGINS=https://hrm.yourdomain.com
PUBLIC_WEB_URL=https://hrm.yourdomain.com
COOKIE_SECURE=true
TRUST_PROXY=1
JWT_SECRET=<openssl rand -base64 48>
OTP_PEPPER=<openssl rand -base64 48>
ENCRYPTION_KEY=<openssl rand -base64 48>   # keep a copy offline: encrypted bank/PAN data needs it
OTP_DEV_ECHO=false
SMTP_HOST=... SMTP_PORT=587 SMTP_USER=... SMTP_PASS=... MAIL_FROM="Signal HRM <hr@yourdomain.com>"
STORAGE_PROVIDER=google_drive   # or local (stored in the api-data volume)
BACKUP_ENABLED=true
```

Create `infra/prod.env` with `SITE_ADDRESS=hrm.yourdomain.com`. Google / Apple sign-in client ids are build arguments of the web image (`GOOGLE_CLIENT_ID`, `APPLE_CLIENT_ID`, `APPLE_REDIRECT_URI` in `infra/docker-compose.prod.yml`).

## 3. Start

```bash
docker compose -f infra/docker-compose.prod.yml --env-file infra/prod.env up -d --build
docker compose -f infra/docker-compose.prod.yml exec api \
  node dist/scripts/bootstrap-super-admin.js --org "Bulletproof Brands" --name "Nayan Kotadiya" --email you@yourdomain.com
```

The bootstrap prints 10 recovery codes once. Store them offline. Then open `https://hrm.yourdomain.com`, sign in with an email code and follow the setup checklist on the home screen.

## 4. After every upgrade

```bash
git pull
docker compose -f infra/docker-compose.prod.yml --env-file infra/prod.env up -d --build
docker compose -f infra/docker-compose.prod.yml exec api node dist/scripts/provision.js
```

Take a manual backup first from **System → Backups → Back up now** (or it is taken nightly when `BACKUP_ENABLED=true`).

## 5. Checks

- `https://hrm.yourdomain.com/api/v1/health` — every critical component healthy.
- **System → Health** in the app — no failing jobs; **System → Backups** — a verified backup within 36 hours and a passed restore test.
- Security headers: the Caddyfile sets HSTS, CSP (self-hosted CanvasKit, Google/Apple sign-in hosts only), `nosniff`, frame denial and a permissions policy allowing geolocation and camera only for this site.

## Staging

Same steps with `APP_ENV=staging`, `MONGODB_DB_NAME=signal_hrm_staging` and its own domain. `npm run seed:demo` (or `node dist/scripts/seed-demo.js --admin-email you@...`) adds a separate "Signal HRM Demo" organization; it refuses to run in production.
