# Signal HRM: phase reports

## Phase 1: architecture, configuration and N UI foundation (12 Oct 2026)

### Done and verified

**API (`apps/api`)**: compiled and tested in the build environment.

- Typecheck clean (`tsc --noEmit`), production build clean.
- 26 unit tests pass: config validation (dev defaults; staging and production refuse to start without MongoDB, Redis and CORS; production refuses a dev database name), structured error filter (business codes, field details, no leaking of internal error text), health aggregation rules, timed checks (healthy / degraded / timeout / failure), database check never green without a real ping, storage and unimplemented components report unknown.
- 5 end-to-end tests pass against the real HTTP stack: health lists all seven components; with no data stores the overall state is **unknown** (not healthy); correlation IDs are reused when well-formed and replaced when not; unknown routes return the structured error shape; Swagger is served outside production.
- Manual run against a **real Redis**: Redis reported healthy after a real ping (1 ms). Against an **unreachable MongoDB**: database reported unavailable and `/health/ready` returned 503.
- `.env` loading, Swagger at `/api/docs`, and CORS preflight allowing `x-correlation-id` and `idempotency-key` all checked on the running server.

**Flutter (`packages/n_ui`, `apps/web`)**: written, syntax-checked, **not compiled here**.

- Every Dart file (45 files) parses with zero syntax errors using a Dart grammar (checker confirmed to catch errors on a deliberately broken file).
- The Flutter SDK and pub.dev are blocked by this build environment's network policy, so `flutter analyze`, `flutter test` and a browser run have **not** happened yet. Run the commands in the README; type errors, if any, will show there.
- Token contrast values were computed independently (WCAG formula) and are asserted again in `test/tokens_test.dart`.

### Built

- Architecture note with repo layout, environments, contracts, eight document conflicts and assumptions (`docs/ARCHITECTURE.md`).
- **N UI tokens:** `NTokens` theme extension resolved live from `NPreferences` (appearance, theme style, accent incl. contrast-clamped custom, text scales, density, radius, shadow, blur, transparency, reduced motion, reduced transparency, high contrast, larger text). iOS-inspired and Classic styles, light and dark. Outfit 300 to 700 bundled with its OFL licence; tabular figures for numbers.
- **Layout:** `NBreakpoint` (mobile, tablet, laptop, desktop) via `NBreakpointBuilder` / `NBreakpointScope`; `NBentoGrid` (1fr 1fr 1fr 1.12fr, 2, 1 columns).
- **Signature components:** `NSlidingPills` (one travelling indicator, spring position 550 ms, width over 82%, labels 350 ms, first layout without animation, re-measure on resize, text scale and font load, hidden-safe, overflow scroll with active label centered, PageView swipe tracking, roving focus with arrow / Home / End / Enter / Space, focus ring, "Label, tab n of m" semantics, RTL, reduced motion), `NViewSwitcher` (exit 220 ms then enter 520 ms in the direction of travel, RTL-aware, `.indexed` keeps branch state), `NDarkActionCard` (check mode; approve mode with held commit, Undo toast, idempotency keys, flush on screen exit and app hide, server rejection returns the row with the reason, confirmation hook for decisions that need a comment), `NHeroRow` with `NGreeting`, `NMeterRow`, count-up `NKpi`, plus `NGlassCard`, `NPanel`, `NPageBackground`, `NToast`, `NStatusChip` (four health states + business tones), `NButton`, `NIconButton`, `NSwitch`, `NSkeleton`, `NEntrance` (page-load stagger, never replayed on tab switch), `NLiveDot`.
- **App shell:** one shell from a permission-filtered destination registry; top pill nav on tablet and wider, floating blurred bottom pill nav on mobile with a More sheet past five items; theme toggle, settings, search, notifications and account in the top bar; Ctrl/Cmd+K hook; go_router with clean URLs, deep links and a not-found page; direction-aware switching between sibling destinations.
- **Pages:** Home (live API health: meters, KPIs, component list, a read-only setup checklist in the dark card that ticks only when real checks pass; skeleton, error with retry and correlation reference), Component gallery (every component, plus mobile 390 / tablet 820 / desktop 1280 frames in light, dark or both), Motion lab (the Phase 1 demonstration: resize, overflow, swipe, direction-aware stepper, reduced motion, RTL, text scale), Appearance (live personalization with preview), Not found.
- **PWA basics:** manifest, generated icons (regular and maskable), lightweight gradient splash removed on Flutter's first frame, light/dark theme-color.
- **Localization:** all shell, home and appearance copy in ARB files; English complete, Hindi and Gujarati for the shell (fall back to English elsewhere).
- **Tests written (Flutter):** tokens and contrast, preferences parsing, breakpoints, held commit (window, Undo, rejection, flush, dispose, re-hold, key format), sliding pills (first layout, travel, single indicator, reduced motion, resize, text scale, overflow centering, semantics, keyboard, RTL, swipe tracking), view switcher (exit-then-enter, direction both ways, reduced motion, state preservation), dark action card (held approve, Undo, rejection, confirmation path, check progress), app (real health numbers, failure state, desktop and mobile navigation, theme toggle, no overflow at ten widths and at 200% text). Golden tests for 2 styles x 2 themes x 2 widths in `test_goldens/` (baselines recorded on first run).

### Mocked or placeholder (clearly labelled in the UI)

- No sign-in yet, so the permission set is empty and only foundation pages appear.
- Search, notifications and account buttons show a toast naming the phase that delivers them.
- N UI preferences last for the session only (persisted to `user_preferences` in Phase 2).
- Backups, background jobs and notifications report **unknown / not implemented** in health; storage reports **unknown / not configured**.
- Gallery and Appearance preview use labelled sample content for design review. They are hidden in production builds (gallery) or clearly titled "Live preview" (appearance). The Home page shows only real API data.

### Not yet done in Phase 1 scope

- Flutter compile, analyzer, test and browser verification (blocked here; run locally).
- Golden baselines (need a first local run with `--update-goldens`).
- Offline shell service worker (planned with the offline attendance queue in Phase 4).

### Next: Phase 2 (authentication, organization setup and authorization)

1. One-time Super Admin bootstrap command (Nayan Kotadiya), hashed recovery codes, reauthentication for sensitive changes.
2. Email OTP (hashed, rate-limited, single use), Google and Apple sign-in, invitation acceptance; no account from a valid OTP alone; suspended / inactive / pending screens.
3. Sessions (rotation, revoke, device list) and `GET /v1/me` with permissions (action + scope).
4. Roles and permissions engine with backend guard on every route, grant-authority checks, audit log service and idempotency-key store in Redis.
5. Organization profile and settings, initial departments (Content, Meta, Shopify), `user_preferences` sync, demo seed for dev and staging only.
6. Shell built from real permissions; Access denied, Account suspended and Account pending activation screens.

---

## Phases 2–13: full application, then testing (12 Oct 2026)

Built in one continuous pass as requested ("first build full app, all phases, then testing"). The backend was then exercised end to end against a real database over HTTP.

### How it was verified

**API: compiled, unit-tested, and run end to end.**

- `tsc --noEmit` clean; production build clean.
- **54 unit tests pass** (9 suites): the Phase 1 suites plus Haversine and geofence verdicts (accuracy limit checked before distance, radius boundary, impossible-travel speed), payroll arithmetic (percent-of chains, cycle detection, wage ceilings, caps, slabs, loss-of-pay proration, adjustments, reimbursements outside gross, paise rounding), AES-GCM encryption and tamper detection, password hashing, the permission model and grant authority, audit key sanitising, Meta lead mapping and `X-Hub-Signature-256` verification.
- **5 HTTP e2e tests pass** (Phase 1 health stack).
- **86/86 end-to-end smoke steps pass** (`apps/api/test/smoke/smoke.mjs`): the real API process over HTTP against a MongoDB-compatible database (FerretDB 1.24 on SQLite, because MongoDB downloads are blocked in this build environment). FerretDB 1.x lacks some aggregation operators and `findAndModify` projections, so a **test-only** preload (`test/smoke/ferret-shim.cjs`, never loaded in production) evaluates those pipelines with mingo; the application code is unchanged. CI runs the same smoke test against **real MongoDB 7** (`.github/workflows/ci.yml`).
- What the smoke run proves, among others: Super Admin bootstrap; OTP sign-in with generic answers for unknown emails; invitation acceptance (link + emailed code); refresh-token rotation and **reuse detection** (session revoked, security alert raised); logout revocation; scope isolation (employee cannot read a manager's record, salary, payroll, system, other people's payslips, exports or selfies); masked sensitive fields; **all Phase 4 attendance rules** (Idempotency-Key required, accuracy worse than the limit refused with retries left, Haversine distance with the configured radius, exception flow after retries or denied permission creating a correction for approval, server time stored while the device time is ignored, distance/accuracy/verification on the record, an exact retry replaying the same record with no duplicate, shared-device / impossible-travel / mock-location / outside-geofence **flags without punishment**, restricted selfie evidence); leave apply → manager approval → single ledger deduction, rejection releasing pending days, idempotent apply; self-approval blocked; expense with magic-byte-checked receipt (renamed executable refused), approval separate from payment; tasks with flow rules; CRM duplicate detection by normalised phone; documents with acknowledgement; generated employment letter PDF; salary proposal → compensation approver; payroll prepared by one person, approved by others, finalized with re-authentication, payslip PDFs visible only to the employee, finalized run locked; all 55 reports run; global search respects scope; notifications; audit log; security overview; Meta webhook signature rejection; personal data export without secrets and readable only by its owner; needs-attention snooze (critical items refused); role-specific dashboards.
- Demo seed (`npm run seed:demo`) and `npm run provision` were run against the same database; the demo refuses to run in production.

**Bugs the testing found and fixed:** model providers touched the database before it initialised (API would not start); idempotency results were stored after the response, so an immediate retry got "in progress" instead of a replay; audit entries with dotted field names were rejected by the database; letter generation returned a file the UI never downloaded; task-status names in dashboards and the demo seed did not match the schema; duplicate index and route-wildcard warnings; CORS did not allow the `x-device-id` header the web app sends; no proxy trust for client IPs behind Caddy.

**Flutter (n_ui + web): written, syntax-checked and API-checked, NOT compiled here.**

- The Flutter SDK cannot be downloaded in this environment (Google storage and pub.dev are blocked), so `flutter analyze`, `flutter test` and a browser run have not happened.
- All 82 Dart files parse with zero syntax errors. A second checker built for this project indexes the real source of Flutter (stable), go_router, http, package:web, intl and N UI, and checks every constructor and function call in the app for unknown named arguments, missing required arguments, unknown named constructors and non-existent `Icons.*`: **0 problems** (it was confirmed to catch deliberate mistakes). Type errors and logic errors can still exist; run `flutter analyze` and `flutter test` first (README).
- Widget tests were rewritten for the signed-in app (fake API through the real client, session and router): signed-out shows sign-in and calls nothing private; employee dashboard shows real numbers; navigation follows permissions; no overflow at ten widths and at 200% text. New N UI tests cover the data table (desktop vs mobile cards), empty and error states, confirm-with-reason, chart semantics, select, calendar and the Kanban keyboard menu.

### What was built

**API (NestJS, MongoDB):** sessions and sign-in (email OTP, Google, Apple, optional password, invitations, recovery codes, re-authentication for sensitive actions); organization settings per section; feature switches; roles and per-user grants with grant authority; users; employees with encrypted sensitive fields, history and on/offboarding checklists; departments, teams; locations; shifts, assignments, change/swap requests with rule checks; attendance (Phase 4 rules, live board, calendar, corrections, flags, evidence, nightly close of day); leave types, policies, accrual, carry-forward, ledger, calendar; holidays, events, announcements, kudos; expenses, categories and limits, reimbursements; salary structures with approval, statutory rules (inactive until validated), payroll runs (calculate, anomalies, approval chain, finalize, payments, bank file, adjustments), payslip PDFs; tasks; CRM leads, activities, follow-ups, sources; meetings; travel; documents with versions, access scopes, acknowledgements, access log, generated letters; approval engine (rules, stages, parallel modes, delegation, escalation, self-approval guard); notifications (in-app, email worker, preferences, templates, delivery log); 55 reports with CSV export; global search; files through a storage abstraction (local disk, Google Drive) with magic-byte checks; backups (mongodump, verification, retention, restore tests, protected restore); moderation; append-only audit log; security center; system health, metrics, error log; Meta lead ads integration (webhook, retries, de-duplication); dashboards per permission set; needs-attention engine with audited snooze; setup checklist; personal data export; bootstrap, provision and demo seed scripts.

**Web (Flutter PWA on N UI):** sign-in (email code, Google/Apple when configured, recovery code), invitation acceptance, re-authentication dialog, session restore and refresh; permission-built navigation; command palette (Ctrl/Cmd+K) with live search; notification center with unread badge; offline banner; dashboard (needs attention with snooze, setup checklist, personal, team, organization and control-center sections from live data); Time (check-in/out flow with location, optional selfie, accuracy and geofence feedback, retry and exception request, offline punch queue; month calendar; corrections; attendance register; leave balances, apply with live preview, requests, team calendar; live team board; flag review with evidence; shift schedule, requests and setup; holidays and events); Work (Kanban and list, task detail with checklist, comments and activity; leads pipeline, list and detail; meetings; travel); People (directory, employee profile with sensitive section, checklists, history, leave balances and adjustments, invitations, offboarding; departments and teams; announcements and kudos); Money (expenses with receipts and charts, reimbursements, payslips, payroll runs and lines, statutory rules, salary versions); Approvals (held-commit approve/decline, detail with history, delegation); Documents (upload, policies, acknowledgements, versions, access log, letters); Reports (catalog, saved views, run with charts and CSV export); Admin (company, modules, attendance rules, locations, leave setup, users, roles editor, approval rules, expense policy, notification templates and deliveries, integrations); System (health, latency, database, jobs, errors, backups and restore, security, audit, moderation); Account (profile, appearance synced to the account, notification choices, devices, recovery codes, data export, sign out). New N UI components: inputs, select, date field, search, filter chips, sheet/drawer, confirm dialog, empty/error states, banner, data table, list row, avatar, progress bar, timeline, bars, donut, sparkline, ring, Kanban, month calendar.

**Deployment:** API Dockerfile (with mongodump/mongorestore), web Dockerfile (Flutter build served by Caddy), Caddyfile (single origin, TLS, strict CSP with self-hosted CanvasKit, HSTS, caching rules), production compose for the Hostinger VPS (API, web, Redis; MongoDB Atlas), CI workflow, deployment runbook (`docs/DEPLOYMENT.md`).

### Not done, partial, or not verified

- **Flutter not compiled or run** (see above).
- **Not exercised here:** SMTP delivery, Google Drive storage, mongodump backups/restores, Google and Apple sign-in, live Meta lead delivery, Redis (the API runs without it in development), payroll bank-file download through re-authentication, PDF layout review.
- **In-app video/audio calls:** rooms and the signaling gateway exist on the server, but the web client has no calling screen yet; meetings use external links.
- **Realtime in the web app:** the unread badge polls every minute; the socket.io client is not wired yet.
- **Localization:** navigation and shell strings are in English, Hindi and Gujarati; most feature screens are English only so far.
- **Offline:** only attendance punches queue offline; other actions need a connection (the app says so).
- Payroll statutory rules ship empty on purpose (no rates are hard-coded); they must be configured and validated.

## Production readiness and free hosting (2026-10-13)

**Built**
- Password sign-in that works with no email server: first-admin setup screen guarded by a one-time `SETUP_TOKEN` (closes itself once a Super Admin exists); administrators issue one-time temporary passwords (shown once, activates invited accounts, signs the person out everywhere); the server blocks every route except the account basics until the person chooses their own password; confirm-it's-you for sensitive actions with the password; change/set password from Account. Password rules: 10+ characters, letters plus numbers or symbols, no common words, no name or email. Lockout after repeated failures reuses the existing sign-in lockout.
- Without SMTP: email-code requests and invitations answer with a clear `EMAIL_NOT_CONFIGURED` (409), adding a person skips the invitation and offers a temporary password, email notifications are skipped instead of retried.
- Hosting: `render.yaml` (API on Docker + Key Value, generated secrets), `apps/web/vercel.json` + `vercel-build.sh` (Flutter build on Vercel, `/api` proxied to Render so the refresh cookie stays first-party, security headers), `docs/GO_LIVE.md` step-by-step guide.
- Animated splash (HTML before Flutter loads, and the in-app splash): rippling signal mark, live waveform, rising wordmark, loading shimmer; respects reduced motion. Fixed the dark-mode splash text that was nearly invisible. Sign-in screen brand and card animate in.

**Verified here**
- API: typecheck clean; 56 unit tests, 5 e2e, 86/86 smoke (development mode); 21/21 production-mode flow (APP_ENV=production, Redis, no SMTP, PASSWORD_LOGIN) covering setup, wrong key, weak passwords, cookie flags (HttpOnly, Secure, SameSite=Strict), refresh, add person without email, temporary password, forced password change, reauth with password, recovery codes. Zero errors or warnings in the server log.
- Web: syntax and API-shape checks clean. Not compiled here (no Flutter SDK): run `flutter analyze` and `flutter test` before deploying.

**Not verified / limits**
- Vercel and Render builds themselves (run on their servers). Free-plan limits: Render sleeps without traffic, no file uploads (ephemeral disk), Atlas M0 has no automatic backups, Vercel Hobby is for non-commercial use.
