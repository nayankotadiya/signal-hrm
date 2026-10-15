const http = require('http');
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { OAuth2Client } = require('google-auth-library');
const { drive } = require('@googleapis/drive');

const envPath = path.resolve(__dirname, '../.env');
const envContent = fs.existsSync(envPath) ? fs.readFileSync(envPath, 'utf8') : '';
const env = {};
for (const line of envContent.split('\n')) {
  const match = line.match(/^\s*([\w.-]+)\s*=\s*(.*)?\s*$/);
  if (match) {
    const key = match[1];
    let val = match[2] || '';
    if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
    env[key] = val.trim();
  }
}

const clientId = env.GOOGLE_DRIVE_CLIENT_ID || env.GOOGLE_CLIENT_IDS?.split(',')[0]?.trim();
const clientSecret = env.GOOGLE_DRIVE_CLIENT_SECRET || env.GOOGLE_CLIENT_SECRET?.trim();
const targetFolderId = env.GOOGLE_DRIVE_ROOT_FOLDER_ID || '1Ate4kVQ5pi3j4y5RyagdD6cHoH4bF4cC';

if (!clientId || !clientSecret) {
  console.error('ERROR: GOOGLE_CLIENT_IDS and GOOGLE_CLIENT_SECRET must be set in apps/api/.env');
  process.exit(1);
}

const PORT = 8912;
const REDIRECT_URI = `http://localhost:${PORT}/callback`;

const oauth2Client = new OAuth2Client(clientId, clientSecret, REDIRECT_URI);

const authUrl = oauth2Client.generateAuthUrl({
  access_type: 'offline',
  prompt: 'consent',
  scope: [
    'https://www.googleapis.com/auth/drive',
    'https://www.googleapis.com/auth/drive.file',
  ],
});

console.log('\n================================================================');
console.log('       SIGNAL HRM - GOOGLE DRIVE (15GB FREE) SETUP');
console.log('================================================================');
console.log('\nTarget Folder: ' + targetFolderId);
console.log('\n1. Open this URL in your browser to authorize your personal Google Drive:');
console.log('\n' + authUrl + '\n');
console.log('2. After approving, your browser will redirect to localhost:' + PORT);
console.log('   (If the redirect fails or you are on a remote server, paste the code or full redirect URL below:)\n');

let handled = false;

async function handleTokens(code) {
  if (handled) return;
  handled = true;
  console.log('Exchanging OAuth code for tokens...');
  const { tokens } = await oauth2Client.getToken(code);
  const refreshToken = tokens.refresh_token;

  if (!refreshToken) {
    console.warn('\n⚠️ No refresh_token returned. Try revoking app permissions in Google Account Security and running again with prompt=consent.');
    process.exit(1);
  }

  console.log('\n✅ SUCCESS! Google Drive Refresh Token obtained:');
  console.log(refreshToken);

  // Append or update in .env
  let updatedEnv = fs.existsSync(envPath) ? fs.readFileSync(envPath, 'utf8') : '';
  if (updatedEnv.includes('GOOGLE_DRIVE_REFRESH_TOKEN=')) {
    updatedEnv = updatedEnv.replace(/GOOGLE_DRIVE_REFRESH_TOKEN=.*(\r?\n|$)/, `GOOGLE_DRIVE_REFRESH_TOKEN=${refreshToken}\n`);
  } else {
    updatedEnv += `\nGOOGLE_DRIVE_REFRESH_TOKEN=${refreshToken}\n`;
  }
  fs.writeFileSync(envPath, updatedEnv, 'utf8');
  console.log('Saved GOOGLE_DRIVE_REFRESH_TOKEN into apps/api/.env!');

  // Test Drive API upload to target folder
  oauth2Client.setCredentials(tokens);
  const d = drive({ version: 'v3', auth: oauth2Client });
  const { Readable } = require('stream');

  console.log(`\nTesting upload directly to target folder: ${targetFolderId}...`);
  const testFile = await d.files.create({
    requestBody: { name: 'signal_hrm_connection_test.txt', parents: [targetFolderId] },
    media: { mimeType: 'text/plain', body: Readable.from(Buffer.from('Signal HRM Personal Drive Connected Successfully!')) },
    fields: 'id, name, parents',
    supportsAllDrives: true,
  });
  console.log('✅ Uploaded test file to Google Drive folder! File ID:', testFile.data.id);
  console.log('   Check your folder: https://drive.google.com/drive/u/0/folders/' + targetFolderId);

  await d.files.delete({ fileId: testFile.data.id, supportsAllDrives: true });
  console.log('✅ Verified & cleaned up test file. Personal Google Drive is 100% READY!\n');
}

const server = http.createServer(async (req, res) => {
  try {
    const u = new URL(req.url, `http://localhost:${PORT}`);
    if (u.pathname === '/callback') {
      const code = u.searchParams.get('code');
      if (!code) {
        res.writeHead(400, { 'Content-Type': 'text/plain' });
        res.end('Missing code parameter.');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<h1>Google Drive Connected Successfully!</h1><p>You can close this tab and return to the terminal.</p>');
      await handleTokens(code);
      setTimeout(() => process.exit(0), 1000);
    }
  } catch (err) {
    console.error('Error in callback:', err);
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end('Error: ' + err.message);
  }
});

server.listen(PORT, () => {
  // Readline fallback for pasting code manually
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  rl.question('Paste code or redirect URL here (optional): ', async (answer) => {
    rl.close();
    if (!answer || handled) return;
    let code = answer.trim();
    if (code.includes('code=')) {
      try {
        const u = new URL(code.startsWith('http') ? code : `http://localhost?${code}`);
        code = u.searchParams.get('code') || code;
      } catch {}
    }
    await handleTokens(code);
    setTimeout(() => process.exit(0), 1000);
  });
});
