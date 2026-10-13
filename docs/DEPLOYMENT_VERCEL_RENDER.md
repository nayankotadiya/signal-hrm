# Deploying Signal HRM to Vercel, Render & MongoDB Atlas

This guide walks you through deploying **Signal HRM** into a production serverless/cloud architecture:
- **Frontend:** Flutter Web PWA on **Vercel**
- **Backend:** NestJS API on **Render** (with managed Redis)
- **Database:** **MongoDB Atlas**

---

## 1. MongoDB Atlas Setup

1. **Create Cluster:**
   - Log into [MongoDB Atlas](https://www.mongodb.com/cloud/atlas).
   - Create a free (M0) or dedicated cluster in your preferred region.

2. **Network Access (IP Whitelist):**
   - Go to **Security → Network Access**.
   - Click **Add IP Address** → Choose **Allow Access from Anywhere (`0.0.0.0/0`)** because Render uses dynamic outbound IPs on web services.

3. **Database User:**
   - Go to **Security → Database Access**.
   - Create a user (e.g. `signal_admin`) with **Read and write to any database** privileges.
   - Note the password.

4. **Connection URI:**
   - Go to **Deployments → Database → Connect → Drivers (Node.js)**.
   - Copy your connection string:
     ```
     mongodb+srv://signal_admin:<password>@cluster0.xxxx.mongodb.net/?retryWrites=true&w=majority
     ```

---

## 2. Backend on Render (NestJS + Redis)

You can deploy in **one click** using the included [`render.yaml`](../render.yaml) Blueprint:

1. Push your repository to GitHub.
2. In [Render Dashboard](https://dashboard.render.com):
   - Click **New +** → **Blueprint**.
   - Connect your GitHub repository.
   - Render automatically reads [`render.yaml`](../render.yaml) and creates:
     - `signal-hrm-api` (Web Service)
     - `signal-hrm-redis` (Managed Redis instance)
3. Fill in the prompted environment variables:
   - `MONGODB_URI`: Your MongoDB Atlas connection URI from Step 1.
   - `MONGODB_DB_NAME`: `signal_hrm_prod`
   - `CORS_ORIGINS`: `https://*.vercel.app,https://your-domain.com`
   - `PUBLIC_WEB_URL`: `https://your-app.vercel.app` (or your custom domain)
   - `JWT_SECRET`, `OTP_PEPPER`, `ENCRYPTION_KEY`: Render automatically generates secure values for these.
4. Click **Apply**. Render will install dependencies, build TypeScript, attach Redis, and launch your API.
5. Note your Render service URL (e.g., `https://signal-hrm-api.onrender.com`).

---

## 3. Frontend on Vercel (Flutter Web PWA)

### Option A: Using Vercel GitHub Integration (Automatic)
1. In [Vercel Dashboard](https://vercel.com/new), import your GitHub repository.
2. Vercel will automatically detect [`vercel.json`](../vercel.json) in the project root.
3. In **Environment Variables**, add:
   - `API_BASE_URL`: `https://signal-hrm-api.onrender.com/api`
4. Click **Deploy**. Vercel will clone Flutter stable, compile the web assets, and deploy to your `.vercel.app` domain.

### Option B: Deploy Pre-built Bundle via Vercel CLI (Fastest)
If you already built the release web app locally:
```bash
# 1. Build locally with production API target
cd apps/web
flutter build web --release --no-web-resources-cdn --dart-define=APP_ENV=production --dart-define=API_BASE_URL=https://signal-hrm-api.onrender.com/api

# 2. Deploy directly with Vercel CLI
npx vercel --prod build/web
```

---

## 4. Bootstrap Super Admin on Render

Once your Render API service is running:

1. Open your Render Dashboard → select `signal-hrm-api` service.
2. Click the **Shell** tab on the left sidebar.
3. Run the bootstrap command:
   ```bash
   node dist/scripts/bootstrap-super-admin.js --org "Bulletproof Brands" --name "Nayan Kotadiya" --email "your-email@yourdomain.com"
   ```
4. **Copy the 10 emergency recovery codes** displayed in the console and store them offline.

---

## 5. Google Drive Cloud Storage & File Retention
High-volume assets (facial attendance photos, receipts, employee verification documents, and automated database backup archives) are stored in Google Drive:

1. **Google Cloud Console Setup:**
   - Go to [Google Cloud Console](https://console.cloud.google.com/).
   - Create a project or select an existing one.
   - Enable the **Google Drive API**.
   - Create a **Service Account** under **IAM & Admin → Service Accounts**.
   - Generate and download a **JSON Key** for the service account.
2. **Google Drive Folder:**
   - Create a folder in Google Drive (e.g. `Signal HRM Production`).
   - Share the folder with the Service Account email (give **Editor** permissions).
   - Copy the folder ID from the URL (`https://drive.google.com/drive/folders/<FOLDER_ID>`).
3. **Configure Environment Variables on Render:**
   - `STORAGE_PROVIDER`: `google_drive`
   - `GOOGLE_DRIVE_CREDENTIALS_JSON`: The entire JSON string from the downloaded service account key file.
   - `GOOGLE_DRIVE_ROOT_FOLDER_ID`: Your Google Drive folder ID.
4. **Strict 1 Month 15 Days (45 Days) Facial Data Retention Policy:**
   - By default, all attendance selfie and facial verification photos have an automatic expiration set to **45 days** (1 month and 15 days).
   - An automated nightly cleanup cron job (`purgeExpiredFacialData`) executes at 02:40 UTC:
     - Permanently removes the physical image files from Google Drive.
     - Unlinks evidence IDs from attendance records.
     - Permanently purges the evidence database records.

---

## 6. MongoDB Atlas 90% Storage Alerting
Signal HRM monitors MongoDB database capacity in real time to prevent cluster downtime:
- **Capacity Monitoring:** The API checks database size every 30 minutes and tracks metrics through `/api/v1/system/overview`.
- **Configurable Limit:** Set `MONGODB_STORAGE_LIMIT_MB` (defaults to `512` for MongoDB Atlas M0 Free Tier, or your dedicated cluster quota).
- **Critical Threshold (>= 90%):** When database size reaches or exceeds 90% of capacity:
  - System health marks database as `degraded` with reason `storage_almost_full`.
  - An automated `SecurityAlert` is generated.
  - High-priority alert notifications are immediately dispatched to all **Admins** and **Super Admins**.

---

## 7. Automated Backups to Google Drive
Signal HRM features enterprise automated backups:
- **Automated Scheduling:** Runs nightly (default `30 2 * * *` at 02:30 UTC).
- **Execution:** Generates a compressed, gzipped `mongodump` archive and streams it directly to Google Drive under `system/backups`.
- **Integrity Verification:** Calculates SHA-256 checksums and tests archive readability.
- **Super Admin Management:** Super Admins can list, verify, trigger restore tests, and download backup archives directly via the API (`GET /api/v1/backups/:id/download`).

---

## 8. Verification & Live Access

1. Open your Vercel deployment URL (e.g. `https://your-app.vercel.app`).
2. Enter your email to receive an OTP code (or sign in using recovery code / dev echo if configured).
3. The dashboard setup checklist will guide you through confirming that your MongoDB Atlas database, Redis cache, Google Drive storage, and attendance/work systems are 100% operational.
