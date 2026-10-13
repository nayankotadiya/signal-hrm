# Go live for free: Vercel + Render + MongoDB Atlas

This puts Signal HRM on the internet at no cost:

| Part | Where | Free plan limits that matter |
|---|---|---|
| Web app (what people open) | **Vercel** | Hobby plan is for non-commercial personal use. For running a business on it, upgrade to Pro. |
| API (the server) | **Render** | Sleeps after 15 min without visits (step 9 keeps it awake). 512 MB memory. Disk is wiped on restart, so file uploads stay off for now. |
| Redis | **Render Key Value** | In memory only. Fine: it holds rate limits and short-lived data, nothing permanent. |
| Database | **MongoDB Atlas M0** | 512 MB. **No automatic backups on the free cluster** (see "Before real data" below). |

People sign in with **email + password** (no email sending needed). Administrators add people and hand them a one-time temporary password; each person chooses their own at first sign-in.

Allow about an hour. You need a GitHub account, and GitHub Desktop is the easiest way to upload the project.

---

## 0. Check the production build on your PC (5 minutes)

```powershell
cd "C:\Users\NAYAN\Downloads\signal hrm bulletproof brands\apps\web"
flutter --version
flutter build web --release --no-web-resources-cdn --dart-define=APP_ENV=production --dart-define=API_BASE_URL=/api --dart-define=PASSWORD_LOGIN=true
```

It should end with `✓ Built build\web`. Note the Flutter version number (for example `3.41.2`): Vercel will build with the same one.

## 1. Put the project on GitHub (private)

1. Install **GitHub Desktop** and sign in.
2. **File → Add local repository →** choose `C:\Users\NAYAN\Downloads\signal hrm bulletproof brands`. It offers to create a repository: accept.
3. Move `infra\github-ci.yml` to `.github\workflows\ci.yml` (create the folders). This runs the tests on every push.
4. Commit everything ("Initial version"), then **Publish repository**. Keep **Private** ticked.

The `.gitignore` already keeps secrets, build output and `node_modules` out of GitHub.

## 2. Create the database (MongoDB Atlas)

1. Sign up at mongodb.com/atlas → **Create** a cluster → **M0 Free** → region **Mumbai (ap-south-1)** → name it `signal-hrm`.
2. **Database Access → Add user**: username `signalhrm`, click **Autogenerate password**, copy it, role **Read and write to any database**.
3. **Network Access → Add IP address → Allow access from anywhere** (`0.0.0.0/0`). Render's free plan has no fixed IP address, so this is required; the strong password protects the database.
4. **Connect → Drivers** → copy the connection string. Put your password in it:
   `mongodb+srv://signalhrm:YOUR_PASSWORD@signal-hrm.xxxxx.mongodb.net/`

## 3. Start the API on Render

1. Sign up at render.com with your GitHub account.
2. **New → Blueprint** → pick your `signal-hrm` repository. Render reads `render.yaml` and shows **signal-hrm-api** and **signal-hrm-redis**.
3. It asks for three values:
   - `MONGODB_URI`: the connection string from step 2
   - `CORS_ORIGINS` and `PUBLIC_WEB_URL`: type `https://example.com` for now (you change them in step 6)
4. **Apply**. The first build takes 5–10 minutes. When it says **Live**, open
   `https://signal-hrm-api.onrender.com/api/v1/health` (use the address Render shows; it may have extra letters). You should see `"state":"healthy"` or `"degraded"` (storage and email are intentionally off).
5. In **signal-hrm-api → Environment**, copy and keep somewhere safe and offline:
   - `ENCRYPTION_KEY`: encrypted bank and ID details can't be read without it
   - `SETUP_TOKEN`: you need it once in step 7

## 4. Point the web app at your API

Open `apps\web\vercel.json` and replace `REPLACE-WITH-YOUR-RENDER-SERVICE` with your Render address, for example:

```json
"destination": "https://signal-hrm-api.onrender.com/api/:path*"
```

Commit and push in GitHub Desktop.

## 5. Publish the web app on Vercel

1. Sign up at vercel.com with GitHub → **Add New → Project** → import `signal-hrm`.
2. **Root Directory:** `apps/web` (click Edit). **Framework Preset:** Other. Leave build settings as they are (they come from `vercel.json`).
3. **Environment Variables:**
   - `FLUTTER_VERSION` = the version from step 0, e.g. `3.41.2`
   - `PASSWORD_LOGIN` = `true`
4. **Deploy.** The first build downloads Flutter and takes about 5 minutes. You get an address like `https://signal-hrm.vercel.app`.

## 6. Tell the API its web address

Render → **signal-hrm-api → Environment** → set both `CORS_ORIGINS` and `PUBLIC_WEB_URL` to your Vercel address (e.g. `https://signal-hrm.vercel.app`, no slash at the end) → **Save, rebuild and deploy**.

## 7. Create your administrator account

1. Open your Vercel address. The sign-in screen says **"This server isn't set up yet"** → **Set up Signal HRM**.
2. Paste the `SETUP_TOKEN`, enter **Bulletproof Brands**, your name, email and a strong password.
3. Save the 10 recovery codes shown once (copy or download). They're your way back in if you forget the password.
4. Back in Render → Environment → **delete `SETUP_TOKEN`** → save. Setup is now closed for good.

## 8. Add your team

**Admin → Users → Add person.** Because email isn't set up, Signal HRM immediately creates a **temporary password** (shown once). Give it to the person in person or by phone. At first sign-in they must choose their own password; until then nothing else opens.

Lost password later: **Admin → Users → the person → Reset password**.

Then follow the **setup checklist** on your dashboard (departments, work locations with radius, shifts, leave types, holidays).

## 9. Keep the API awake (free)

Render's free plan sleeps after 15 minutes without visits, and waking takes about a minute. A free uptime monitor prevents that and also alerts you if the app goes down:

1. Sign up at uptimerobot.com → **New monitor** → type **HTTP(s)**.
2. URL: `https://YOUR-VERCEL-ADDRESS/api/v1/health/live`, interval **5 minutes**.

One always-on free service uses about 744 of Render's 750 free hours a month, so keep only this one service on the free plan.

---

## Before real data: limits to fix

- **Backups:** the free Atlas cluster has no automatic backups, and Signal HRM's own backups need file storage. Before you rely on it for payroll and attendance, either upgrade Atlas (the Flex tier includes daily snapshots) or move to the Hostinger VPS setup in `docs/DEPLOYMENT.md`.
- **File uploads (documents, selfies, letters):** off, because Render's free disk is wiped on restart. They need Google Drive storage, which requires a Google Workspace shared drive (personal Gmail drives don't work with service accounts), or a VPS with a disk.
- **Email:** add SMTP settings any time (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `MAIL_FROM` in Render). Email sign-in codes, invitations and email notifications then switch on automatically. Brevo and Zoho both have free tiers.
- **Your own domain:** Vercel → Project → Settings → Domains (e.g. `hrm.bulletproofbrands.in`), then update `CORS_ORIGINS` and `PUBLIC_WEB_URL` in Render.

## Updating later

Push to GitHub. Vercel and Render rebuild automatically. Check `/api/v1/health` afterwards.
