# Signal HRM: architecture note (Phase 1)

People • Work • Time • Operations. Design system: **N UI — Defined & Developed by Nayan**.

## 1. Repository layout

```
signal-hrm/
├─ apps/
│  ├─ api/                 NestJS REST API (versioned /api/v1, WebSocket gateway added when a module needs it)
│  │  ├─ src/config/       env schema (zod), fails fast with one readable list of problems
│  │  ├─ src/common/       correlation IDs, structured errors (later: auth guard, audit, idempotency)
│  │  ├─ src/database/     single MongoDB connection (Mongoose), background connect, honest health
│  │  ├─ src/redis/        shared Redis client (cache, rate limits, idempotency keys, queues)
│  │  ├─ src/storage/      IStorageProvider + provider factory (Google Drive arrives in Phase 9)
│  │  ├─ src/health/       tri-state health checks: api, database, redis, storage, backups, jobs, notifications
│  │  └─ src/modules/      feature modules, one folder per structure module (from Phase 2)
│  └─ web/                 Flutter Web PWA
│     ├─ lib/app/          config, permissions model, preferences scope, services, destinations, router
│     ├─ lib/shell/        the one shell (top pill nav, floating mobile nav, More sheet, PageFrame)
│     ├─ lib/features/     one folder per module (home, gallery, motion lab, appearance, ...)
│     ├─ lib/data/         API clients (health in Phase 1)
│     ├─ lib/l10n/         ARB files: English (complete), Hindi and Gujarati (shell)
│     └─ web/              index.html with lightweight splash, manifest, icons
├─ packages/
│  └─ n_ui/                N UI Flutter package: tokens, themes, layout, motion, components, tests
├─ infra/                  docker-compose for local MongoDB and Redis
└─ docs/                   this note and the phase reports
```

Rules that keep it from sprawling:

- Business modules depend on interfaces (`IStorageProvider`, later the approval engine, audit and notification services), never on vendors.
- Every module uses the shared authorization, audit and approval services. No module gets its own copy.
- Every screen is built from `n_ui` components. Nothing else may hand-roll a tab control (`NSlidingPills` only).

## 2. Environments and configuration

| | development | staging | production |
|---|---|---|---|
| API config | `apps/api/.env` (copied from `.env.example`) | server env vars | server env vars |
| MongoDB | optional (local Docker); health shows "unknown" without it | Atlas, `signal_hrm_staging` | Atlas, `signal_hrm` |
| Redis | optional (local Docker) | required | required |
| CORS | any origin if unset | required list | required list |
| Swagger `/api/docs` | on | on | off |
| Web build flags | `APP_ENV=development` | `APP_ENV=staging` | `APP_ENV=production` (hides gallery and motion lab) |
| Demo seed | allowed (Phase 2+) | allowed, resettable | never |

The API refuses to start in staging or production without MongoDB, Redis and CORS origins, and refuses a production database name ending in `_dev` or `_staging`. Secrets live only on the server; the web build receives only `APP_ENV` and `API_BASE_URL` through `--dart-define`.

## 3. Cross-cutting contracts already in place

- **Errors:** every endpoint returns `{ "error": { status, code, message, details?: [{field, message, code}], correlationId } }`. Internal errors never leak driver messages, hosts or connection strings.
- **Correlation IDs:** `x-correlation-id` on every response. A well-formed incoming ID from the PWA is reused, so the error sheet can show the same reference the server logged.
- **Health:** `GET /api/v1/health` (always 200, read `state`), `/health/live`, `/health/ready` (503 when a critical component is unavailable). States: healthy, degraded, unavailable, unknown. "Healthy" only after a real check (database and Redis are pinged; the API measures event-loop lag). Components without a real check yet report `unknown / not_implemented`.
- **Rate limiting:** global throttler (in-memory in Phase 1; moves to Redis storage in Phase 2 so limits hold across instances).
- **CORS:** allows `idempotency-key` and `x-correlation-id` request headers and exposes `x-correlation-id`.
- **Idempotency keys:** the client generates a UUID v4 per user decision (`newIdempotencyKey()` in `n_ui`). Server-side enforcement (Redis-backed key store) lands with the first mutation in Phase 2.

## 4. N UI foundation

- `NTokens` (a `ThemeExtension`) is resolved at runtime from `NPreferences` by `NTokens.resolve(prefs, brightness)`: colors, gradients, radii, spacing (density), shadows, blur, durations, curves and type helpers. Widgets read `NTokens.of(context)` and never hardcode a color, radius or duration.
- Theme styles: **iOS-inspired** (glass, blur, big radii) and **Classic** (same layout, flatter surfaces, no blur, radii x0.6, visible borders). Light, dark, system.
- Outfit (300 to 700) is bundled in `packages/n_ui/assets/fonts` (SIL OFL, licence included) so the PWA renders offline. Numbers use tabular figures (`tnum`; Outfit ships it).
- `NBreakpoint` (mobile up to 759, tablet 760 to 999, laptop 1000 to 1439, desktop 1440 and up) is published by `NBreakpointBuilder` / `NBreakpointScope`; widgets never read raw screen width.
- Signature components: `NSlidingPills`, `NViewSwitcher` (+ `.indexed` for shell branches), `NDarkActionCard` (check and approve with held commit), `NHeroRow` (`NGreeting`, `NMeterRow`, `NKpi`), `NGlassCard`, `NPanel`, `NPageBackground`, `NToast`, `NStatusChip`, `NButton`, `NIconButton`, `NSwitch`, `NSkeleton`, `NBentoGrid`, `NEntrance`, `NLiveDot`.

### Contrast decisions

| Token | Spec value | Measured | Used | Result |
|---|---|---|---|---|
| Light muted text | `#6E7480` | 3.95:1 on panel `#D3F1F4` (fails AA) | `#5F6570` | 4.93:1 or better on every panel and card stop |
| Accent presets | not specified | | Blue `#2F6FED`, Purple `#6C5CE7`, Green `#2A7F51`, Orange `#BF5414`, Pink `#C2357A`, Teal `#0B7C72` | 4.5:1 or better with white text, 3:1 or better against light and dark cards |
| Custom accent | user input | | clamped by `NContrast.clampAccent` (lightness steps, hue kept) | always 4.5:1 or better with its text color |

## 5. Conflicts found between Part A (UI) and Part B (structure)

Business logic follows Part B; visuals and motion follow Part A.

1. **Muted text color** (Part A §2) fails AA as specified. Part A itself says to darken it; done (`#5F6570`).
2. **Font family setting** (Part B §28 "Font family where supported") vs **Outfit only** (Part A §2). Visual rule wins: the setting will offer only Outfit (default) and the system font as an accessibility fallback, added with the Typography page in Phase 12. Size scales (overall, heading, body, caption, button) already work.
3. **Navigation style** (Part B §28: sidebar, rail, bottom) vs fixed layouts per device (Part A §4). Part A's layouts are the defaults; sidebar and rail are stored in `NPreferences.navStyle` and rendered as alternatives in Phase 12.
4. **Held commit** (Part A §3.3) vs **"No silent approval" / idempotent processing** (Part B §19). Compatible with one safeguard: if a tab closes inside the 5 s window, the decision might not be sent. Held decisions are flushed when the screen is left and when the app is hidden (implemented), the server stays the source of truth, and an unsent decision simply reappears as pending. Decisions whose policy requires a comment (for example a rejection with a mandatory reason) use a dialog, not held commit (`needsConfirmation` hook, implemented).
5. **Leave "request clarification"** (Part B §11 step 6) is a third decision that Part A's Approve / Decline rows don't show. It goes in the request's detail drawer (Phase 4); the dark card keeps two buttons.
6. **Meetings** appear in CRM (§16) and in Calls and meetings (§21). One `meetings` collection and module; CRM links to it through the related lead reference (Part B §1 forbids duplicate implementations).
7. **Payroll collection** (§30 lists one `payroll` collection holding run and per-employee fields) vs "do not embed unlimited histories". Phase 5 uses `payroll_runs` (header, period, status, approvals) plus `payroll` (one line per employee per run). Same business rules.
8. **Optional password login** (Part B §3) isn't in Part A's auth blueprint. It becomes an organization security setting, off by default.

## 6. Assumptions

- One organization at launch, but every organization-owned document carries `organizationId` and every request validates membership on the backend (multi-organization ready).
- Organization defaults for a new install: time zone Asia/Kolkata, currency INR, week starts Monday. All are editable in Organization settings (Phase 2).
- Stack versions: Node 20.12+, NestJS 11, Mongoose 8, TypeScript 5.8; Flutter 3.27+ (uses `Color.withValues`), go_router 14 to 17, `http` 1.x.
- Client state uses plain Flutter (`InheritedNotifier`, `ValueNotifier`) to keep dependencies small.
- Phase 1 has no sign-in, so the permission set is empty and only foundation pages show. From Phase 2 the shell, routes and widgets are built from `GET /v1/me` permissions (action plus scope); hiding is never security.
- N UI preferences live in memory in Phase 1 and persist to `user_preferences` with organization defaults from Phase 2.
- Flutter's generated service worker is deprecated, so the offline shell and the offline attendance queue get a purpose-built service worker in Phase 4.
- Deployment target (Phase 13): Hostinger VPS running the API and Redis with Docker Compose, MongoDB Atlas, and Caddy or Nginx serving the Flutter build with HTTPS, SPA fallback to `index.html` (needed for clean URLs), and security headers including a strict Content-Security-Policy. The web build should use `--no-web-resources-cdn` so the CSP needs no third-party script origins.

---

## 7. Phases 2–13 additions

- **Modules** (`apps/api/src/modules`): auth, users, roles, organization, people, time (attendance, shifts, leave, holidays), finance (expenses, payroll), work (tasks, CRM, travel, meetings), documents, approvals, notifications, reports, search, files, backups, security (moderation, audit, security center), integrations (Meta lead ads), dashboard (dashboards, needs-attention, setup checklist, personal data export), system, setup (provisioning).
- **Every request** runs through: correlation id → auth guard (JWT access token, user and organization status, feature switch, `@Can` permission, `@RequireReauth`) → idempotency interceptor (all mutations; `@Idempotent` makes the key mandatory; responses replayed for 24 h) → handler → structured error filter.
- **Authorization** is enforced in services with `PermissionsService.require` and `ScopeService` filters (own < records < team < department < organization). The web app only reads the permission set to decide what to show.
- **Approvals** go through one engine (rules or default chains, stages, parallel modes, delegation, escalation cron, self-approval guard). Payroll and salary stages never fall back to a different approver: with nobody eligible the request is refused (`NO_APPROVER`).
- **Attendance (Phase 4 rules):** server-side Haversine against the employee's assigned location and radius; configurable maximum GPS accuracy (refuse, ask to retry, then offer the exception flow); location and selfie required separately for check-in and check-out; server time only (device time kept for diagnostics); suspicious patterns flagged for review only; Idempotency-Key required on every punch; distance, accuracy and verification stored on the punch; selfies are restricted evidence with retention.
- **Web app:** `ApiClient` (access token in memory, httpOnly refresh cookie, single-flight refresh, re-authentication prompt, Idempotency-Key on every mutation with one same-key retry on network failure), `SessionController`, router rebuilt from permissions and modules, `PlatformBridge` (browser geolocation, file picker with camera capture, downloads, Google/Apple scripts) with a VM stub for tests.
- **Deployment:** single origin behind Caddy (TLS, CSP, HSTS); API container includes MongoDB database tools for backups; MongoDB Atlas per environment; Redis on the VPS. See `docs/DEPLOYMENT.md`.
