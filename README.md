# Signal HRM

**People • Work • Time • Operations**: a secure HRMS with persistent data, role-based access, audit trails and the **N UI** design system (*N UI — Defined & Developed by Nayan*).

Stack: Flutter Web (PWA) · NestJS · MongoDB Atlas · Redis · Google Drive through a backend storage abstraction.

- Architecture, environments, conflicts and assumptions: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- What each phase delivered, and what was verified: [`docs/PHASE_REPORTS.md`](docs/PHASE_REPORTS.md)
- **Go live for free (Vercel + Render + MongoDB Atlas, password sign-in):** [`docs/GO_LIVE.md`](docs/GO_LIVE.md)
- Deployment (Hostinger VPS, MongoDB Atlas, Caddy): [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)

## Run it locally (Windows, macOS or Linux)

Prerequisites: Node.js 20.12+, Flutter 3.27+ with Chrome, and optionally Docker Desktop for local MongoDB and Redis.

### 1. Data stores (optional in development)

```bash
docker compose -f infra/docker-compose.dev.yml up -d
```

Without them the API still starts; health reports the database and Redis as **unknown** (never green).

### 2. API

```bash
cd apps/api
npm install
copy .env.example .env        # macOS/Linux: cp .env.example .env
# with Docker running, set in .env:
#   MONGODB_URI=mongodb://localhost:27017
#   REDIS_URL=redis://localhost:6379
npm run start:dev
```

- Health: http://localhost:3000/api/v1/health
- API docs (Swagger): http://localhost:3000/api/docs
- Tests: `npm run test:all` (typecheck, unit, e2e)

### 3. Web app

```bash
cd packages/n_ui
flutter pub get
flutter test                  # N UI unit and widget tests

cd ../../apps/web
flutter pub get               # also generates localizations into lib/l10n/gen
flutter test
flutter run -d chrome --web-port 8080 --dart-define=API_BASE_URL=http://localhost:3000/api
```

Port 8080 matches `CORS_ORIGINS` in `.env.example`. If Flutter reports missing project files, run `flutter create . --platforms web --project-name signal_hrm_web` inside `apps/web` once; it only adds files that don't exist. In the app:

Sign in with the Super Admin you bootstrap (below). With `OTP_DEV_ECHO=true` in development, the sign-in code and invitation links are printed in the API console instead of being emailed.

### 4. First Super Admin and demo data

```bash
cd apps/api
npm run build
npm run bootstrap -- --org "Bulletproof Brands" --name "Nayan Kotadiya" --email you@example.com
npm run seed:demo -- --admin-email demo@example.com    # optional, development/staging only
```

### 5. Tests

```bash
cd apps/api
npm run test:all                       # typecheck, unit, e2e
# end-to-end smoke test against a running API and database (see the file header):
API=http://localhost:3000/api API_LOG=./api.log npm run test:smoke
```

Deployment to the VPS: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

Golden baselines for N UI are recorded on your machine the first time:

```bash
cd packages/n_ui
flutter test test_goldens --update-goldens
```

### Production web build

```bash
cd apps/web
flutter build web --release --no-web-resources-cdn --dart-define=APP_ENV=production
```

In production the app calls `/api` on its own origin (Caddy proxies it; see `infra/Caddyfile`). `APP_ENV=production` hides the gallery and motion lab. The Docker setup in `infra/` does all of this for you.
