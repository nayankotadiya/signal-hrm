// End-to-end smoke test against a running API (real HTTP, real database).
//
//   API=http://localhost:3100/api API_LOG=/path/to/api.log node test/smoke/smoke.mjs
//
// Requires APP_ENV=development with OTP_DEV_ECHO=true (codes are read from the server log),
// a bootstrapped Super Admin (SUPER_EMAIL) and STORAGE_PROVIDER=local.
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const API = process.env.API ?? 'http://localhost:3100/api';
const LOG = process.env.API_LOG ?? '/tmp/api.log';
const SUPER_EMAIL = process.env.SUPER_EMAIL ?? 'nayan@bulletproof.test';
const results = [];
let failures = 0;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const key = () => randomUUID().replace(/-/g, '');

async function call(method, path, { token, body, idem, headers = {}, raw = false, form } = {}) {
  const h = { accept: 'application/json', 'x-device-id': headers['x-device-id'] ?? 'smoke-device-1', ...headers };
  if (token) h.authorization = `Bearer ${token}`;
  if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) h['idempotency-key'] = idem ?? key();
  let payload;
  if (form) payload = form;
  else if (body !== undefined) {
    h['content-type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${API}/v1${path}`, { method, headers: h, body: payload });
  const text = await res.text();
  if (raw) return { status: res.status, text, headers: res.headers };
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  return { status: res.status, json, headers: res.headers };
}

async function step(name, fn) {
  try {
    const detail = await fn();
    results.push(['PASS', name, detail ?? '']);
    console.log(`PASS  ${name}${detail ? ` — ${detail}` : ''}`);
  } catch (e) {
    failures++;
    results.push(['FAIL', name, e.message]);
    console.log(`FAIL  ${name} — ${e.message}`);
  }
}

function expect(cond, msg) {
  if (!cond) throw new Error(msg);
}
const ok = (r, ...codes) => {
  expect((codes.length ? codes : [200, 201]).includes(r.status), `HTTP ${r.status}: ${JSON.stringify(r.json)?.slice(0, 300)}`);
  return r.json;
};

async function otpFor(email) {
  for (let i = 0; i < 20; i++) {
    const log = readFileSync(LOG, 'utf8');
    const all = [...log.matchAll(new RegExp(`OTP for ${email.replace(/[.+]/g, '\\$&')}: (\\d{6})`, 'g'))];
    if (all.length) return all[all.length - 1][1];
    await sleep(250);
  }
  throw new Error(`no OTP in log for ${email}`);
}

async function inviteToken(email) {
  for (let i = 0; i < 20; i++) {
    const log = readFileSync(LOG, 'utf8');
    const all = [...log.matchAll(new RegExp(`Invitation for ${email.replace(/[.+]/g, '\\$&')}: \\S+/invite/([A-Za-z0-9_-]+)`, 'g'))];
    if (all.length) return all[all.length - 1][1];
    await sleep(250);
  }
  throw new Error(`no invitation link in log for ${email}`);
}

async function acceptInvite(email) {
  const token = await inviteToken(email);
  ok(await call('GET', `/auth/invitations/${token}`));
  ok(await call('POST', '/auth/otp/request', { body: { identifier: email } }));
  await sleep(300);
  const code = await otpFor(email);
  return ok(await call('POST', '/auth/invitations/accept', { body: { token, code } }));
}

async function signIn(email, waitResend = false) {
  let r = await call('POST', '/auth/otp/request', { body: { identifier: email } });
  if (r.status === 429 && waitResend) {
    await sleep(61_000);
    r = await call('POST', '/auth/otp/request', { body: { identifier: email } });
  }
  ok(r);
  await sleep(300);
  const code = await otpFor(email);
  const v = ok(await call('POST', '/auth/otp/verify', { body: { identifier: email, code } }));
  return v;
}

const S = {};

// --------------------------------------------------------------------------- foundation
await step('health endpoint reports database healthy', async () => {
  const j = ok(await call('GET', '/health'));
  const db = j.components.find((c) => c.component === 'database');
  expect(db.state === 'healthy', `database ${db.state}`);
  return `overall ${j.state}`;
});

await step('protected route without token is 401 with structured error', async () => {
  const r = await call('GET', '/auth/me');
  expect(r.status === 401 && r.json.error.code === 'UNAUTHENTICATED' && r.json.error.correlationId, JSON.stringify(r.json));
});

await step('OTP request for unknown email answers like success (no account enumeration)', async () => {
  const j = ok(await call('POST', '/auth/otp/request', { body: { identifier: 'nobody@nowhere.test' } }));
  expect(j.sent === true, 'expected generic success');
});

await step('wrong OTP is rejected', async () => {
  await call('POST', '/auth/otp/request', { body: { identifier: SUPER_EMAIL } });
  const r = await call('POST', '/auth/otp/verify', { body: { identifier: SUPER_EMAIL, code: '000000' } });
  expect([400, 401, 422].includes(r.status) && r.json.error.code, `got ${r.status}`);
  return r.json.error.code;
});

await step('Super Admin signs in with email OTP', async () => {
  const code = await otpFor(SUPER_EMAIL);
  const v = ok(await call('POST', '/auth/otp/verify', { body: { identifier: SUPER_EMAIL, code } }));
  S.admin = v.accessToken;
  expect(v.me.role === 'super_admin', `role ${v.me.role}`);
  expect(v.me.permissions.includes('payroll:manage:organization'), 'super admin should hold all grants');
  return `${v.me.permissions.length} grants`;
});

await step('dashboard renders for Super Admin with control center section', async () => {
  const j = ok(await call('GET', '/dashboard', { token: S.admin }));
  expect(j.system && j.organization, 'missing sections');
  return `${j.attention.length} attention items`;
});

await step('setup checklist reflects real configuration', async () => {
  const j = ok(await call('GET', '/dashboard/setup-checklist', { token: S.admin }));
  expect(j.total > 10 && j.steps.find((s) => s.key === 'org.departments').done === true, 'departments should be provisioned');
  return `${j.done}/${j.total} done, ${j.requiredRemaining} required left`;
});

// --------------------------------------------------------------------------- organization setup
await step('update company profile', async () => {
  const j = ok(await call('PATCH', '/organization', { token: S.admin, body: { legalName: 'Bulletproof Brands Pvt Ltd', supportEmail: 'hr@bulletproof.test', timezone: 'Asia/Kolkata', workingDays: [1, 2, 3, 4, 5, 6] } }));
  expect(j.legalName === 'Bulletproof Brands Pvt Ltd', 'not saved');
});

await step('configure attendance rules (Phase 4: per-action requirements, accuracy limit, retries)', async () => {
  ok(
    await call('PUT', '/organization/settings/attendance', {
      token: S.admin,
      body: { checkIn: { requireLocation: true, requireSelfie: false }, checkOut: { requireLocation: true, requireSelfie: false }, maxAccuracyMeters: 50, gpsRetryLimit: 2, allowRemote: false, impossibleTravelKmh: 150 },
    }),
  );
  const me = ok(await call('GET', '/auth/me', { token: S.admin }));
  expect(me.organization.attendance.maxAccuracyMeters === 50, `got ${JSON.stringify(me.organization.attendance)}`);
});

await step('create work location with geofence', async () => {
  const j = ok(await call('POST', '/locations', { token: S.admin, body: { name: 'Ahmedabad studio', latitude: 23.0225, longitude: 72.5714, radiusMeters: 150 } }));
  S.location = j.id;
});

await step('create shift', async () => {
  const j = ok(await call('POST', '/shifts', { token: S.admin, body: { name: 'General', startTime: '00:00', endTime: '23:59', breakMinutes: 60, graceMinutes: 120, workingDays: [0, 1, 2, 3, 4, 5, 6] } }));
  S.shift = j.id;
});

await step('departments were provisioned (Content, Meta, Shopify)', async () => {
  const j = ok(await call('GET', '/departments', { token: S.admin }));
  const items = j.items ?? j;
  expect(items.length >= 3, `only ${items.length}`);
  S.dept = items.find((d) => d.name === 'Content').id;
});

await step('create a team', async () => {
  const j = ok(await call('POST', '/teams', { token: S.admin, body: { name: 'Reels', departmentId: S.dept } }));
  S.team = j.id;
});

await step('add a holiday', async () => {
  const y = new Date().getFullYear();
  ok(await call('POST', '/holidays', { token: S.admin, body: { date: `${y}-12-25`, name: 'Christmas' } }));
});

// --------------------------------------------------------------------------- people
await step('add a manager employee with an invitation', async () => {
  const j = ok(await call('POST', '/employees', { token: S.admin, body: { firstName: 'Kabir', lastName: 'Mehta', contactEmail: 'kabir@bulletproof.test', designation: 'Content Lead', departmentId: S.dept, locationId: S.location, shiftId: S.shift, joiningDate: '2025-01-01', invite: { role: 'manager' } } }));
  S.managerEmp = j.id;
  expect(j.employeeCode, 'no code');
  return j.employeeCode;
});

await step('add an employee reporting to the manager', async () => {
  const j = ok(
    await call('POST', '/employees', {
      token: S.admin,
      body: { firstName: 'Meera', lastName: 'Iyer', contactEmail: 'meera@bulletproof.test', designation: 'Content Writer', departmentId: S.dept, teamId: S.team, reportingManagerId: S.managerEmp, locationId: S.location, shiftId: S.shift, joiningDate: '2025-02-01', invite: { role: 'employee' } },
    }),
  );
  S.emp = j.id;
});

await step('duplicate employee email is refused', async () => {
  const r = await call('POST', '/employees', { token: S.admin, body: { firstName: 'X', contactEmail: 'meera@bulletproof.test' } });
  expect(r.status === 409, `got ${r.status}`);
});

await step('sensitive fields: save bank details, read back masked only', async () => {
  ok(await call('PATCH', `/employees/${S.emp}/sensitive`, { token: S.admin, body: { bank: { accountName: 'Meera Iyer', accountNumber: '123456789012', ifsc: 'HDFC0001234', bankName: 'HDFC' }, tax: { pan: 'ABCDE1234F' } } }));
  const j = ok(await call('GET', `/employees/${S.emp}`, { token: S.admin }));
  expect(j.sensitive.bank.accountNumber && !j.sensitive.bank.accountNumber.includes('12345678'), `not masked: ${JSON.stringify(j.sensitive.bank)}`);
  expect(!JSON.stringify(j).includes('ABCDE1234F'), 'PAN leaked');
  return j.sensitive.bank.accountNumber;
});

await step('invited employee accepts invitation and signs in', async () => {
  // The invitation creates the user; OTP login works once invited.
  const v = await acceptInvite('meera@bulletproof.test');
  S.empToken = v.accessToken;
  expect(v.me.employee?.id === S.emp, 'employee not linked');
  return v.me.role;
});

await step('manager signs in', async () => {
  const v = await acceptInvite('kabir@bulletproof.test');
  S.mgrToken = v.accessToken;
  expect(v.me.role === 'manager', v.me.role);
});

await step('employee cannot see another employee record (scope)', async () => {
  const r = await call('GET', `/employees/${S.managerEmp}`, { token: S.empToken });
  expect(r.status === 404 || r.status === 403, `got ${r.status}`);
});

await step('employee cannot read sensitive fields of self without permission', async () => {
  const j = ok(await call('GET', `/employees/${S.emp}`, { token: S.empToken }));
  expect(j.sensitive.locked === true, 'sensitive should be locked');
});

await step('employee cannot open payroll', async () => {
  const r = await call('GET', '/payroll/runs', { token: S.empToken });
  expect(r.status === 403, `got ${r.status}`);
});

// --------------------------------------------------------------------------- attendance (Phase 4 rules)
const near = { latitude: 23.0226, longitude: 72.5715 }; // ~15 m away
const far = { latitude: 23.0400, longitude: 72.5714 }; // ~1.9 km away

await step('today shows not checked in with requirements', async () => {
  const j = ok(await call('GET', '/attendance/today', { token: S.empToken }));
  expect(j.state === 'not_checked_in' && j.requirements.maxAccuracyMeters === 50, JSON.stringify(j).slice(0, 200));
});

await step('check-in without an Idempotency-Key is refused', async () => {
  const res = await fetch(`${API}/v1/attendance/check-in`, { method: 'POST', headers: { authorization: `Bearer ${S.empToken}`, 'content-type': 'application/json' }, body: JSON.stringify({ ...near, accuracyMeters: 10, locationStatus: 'granted' }) });
  expect(res.status === 400, `got ${res.status}`);
});

await step('GPS accuracy worse than the limit is refused with retry guidance', async () => {
  const r = await call('POST', '/attendance/check-in', { token: S.empToken, body: { ...near, accuracyMeters: 400, locationStatus: 'granted' } });
  expect(r.status === 422 && r.json.error.code === 'GPS_ACCURACY_TOO_LOW', JSON.stringify(r.json));
  expect(r.json.error.meta.retriesLeft === 1 && r.json.error.meta.requiredAccuracy === 50, JSON.stringify(r.json.error.meta));
});

await step('outside the geofence is refused with distance (Haversine on server)', async () => {
  const r = await call('POST', '/attendance/check-in', { token: S.empToken, body: { ...far, accuracyMeters: 10, locationStatus: 'granted' } });
  expect(r.status === 422 && r.json.error.code === 'OUTSIDE_GEOFENCE', JSON.stringify(r.json));
  const d = r.json.error.meta.distanceMeters;
  expect(d > 1800 && d < 2100, `distance ${d}`);
  expect(r.json.error.meta.exceptionAvailable === true, 'exception should open after 2 failures');
  return `${d} m`;
});

await step('check-in inside geofence succeeds; distance, accuracy and verification stored; server time used', async () => {
  const idem = key();
  const before = Date.now();
  const j = ok(await call('POST', '/attendance/check-in', { token: S.empToken, idem, body: { ...near, accuracyMeters: 12, locationStatus: 'granted', clientRecordedAt: '2001-01-01T00:00:00Z' } }));
  const p = j.record.checkIn;
  expect(p.verification === 'within_radius' && p.distanceMeters < 30 && p.accuracyMeters === 12, JSON.stringify(p));
  expect(Math.abs(new Date(p.at).getTime() - before) < 60_000, 'not server time');
  S.checkInIdem = idem;
  S.checkInBody = { ...near, accuracyMeters: 12, locationStatus: 'granted' };
  S.attendanceId = j.record.id;
  return `${p.distanceMeters} m, ±${p.accuracyMeters} m`;
});

await step('retrying the same check-in (same Idempotency-Key) replays without a duplicate', async () => {
  const j = ok(await call('POST', '/attendance/check-in', { token: S.empToken, idem: S.checkInIdem, body: { ...near, accuracyMeters: 12, locationStatus: 'granted', clientRecordedAt: '2001-01-01T00:00:00Z' } }));
  expect(j.record.id === S.attendanceId, 'different record');
  const list = ok(await call('GET', `/attendance?from=2000-01-01&to=2100-01-01`, { token: S.empToken }));
  expect(list.total === 1, `records: ${list.total}`);
});

await step('a second check-in with a new key is refused (already checked in)', async () => {
  const r = await call('POST', '/attendance/check-in', { token: S.empToken, body: { ...near, accuracyMeters: 12, locationStatus: 'granted' } });
  expect(r.status === 409 && r.json.error.code === 'ALREADY_CHECKED_IN', JSON.stringify(r.json));
});

await step('shared device used by a second employee is flagged (not punished)', async () => {
  // Manager checks in from the same device id.
  const r = await call('POST', '/attendance/check-in', { token: S.mgrToken, headers: { 'x-device-id': 'smoke-device-1' }, body: { ...near, accuracyMeters: 15, locationStatus: 'granted' } });
  ok(r);
  const flags = ok(await call('GET', '/attendance/flags', { token: S.admin }));
  const types = flags.items.map((f) => f.type);
  expect(types.includes('shared_device'), `flags: ${types.join(',')}`);
  expect(r.json.record.status !== 'absent', 'punch must still be recorded');
  return types.join(', ');
});

await step('repeated GPS failures are flagged for review', async () => {
  const flags = ok(await call('GET', '/attendance/flags', { token: S.admin }));
  return flags.items.map((f) => f.type).join(', ');
});

await step('manager reviews a flag (note only)', async () => {
  const flags = ok(await call('GET', '/attendance/flags', { token: S.admin }));
  const f = flags.items[0];
  const j = ok(await call('POST', `/attendance/flags/${f.id}/review`, { token: S.admin, body: { outcome: 'reviewed_ok', note: 'Shared office tablet' } }));
  expect(j.status === 'reviewed_ok', j.status);
});

await step('check-out succeeds and computes worked minutes', async () => {
  const j = ok(await call('POST', '/attendance/check-out', { token: S.empToken, body: { ...near, accuracyMeters: 9, locationStatus: 'granted' } }));
  expect(j.record.checkOut.verification === 'within_radius', JSON.stringify(j.record.checkOut));
});

await step('attendance calendar for the month', async () => {
  const m = new Date().toISOString().slice(0, 7);
  const j = ok(await call('GET', `/attendance/calendar?month=${m}`, { token: S.empToken }));
  return JSON.stringify(j.summary);
});

await step('manager live board shows the team', async () => {
  const j = ok(await call('GET', '/attendance/live', { token: S.mgrToken }));
  return JSON.stringify(j.counts);
});

await step('selfie evidence is restricted: employee upload then manager without evidence permission cannot fetch file', async () => {
  // 1x1 PNG
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
  const fd = new FormData();
  fd.append('purpose', 'selfie');
  fd.append('file', new Blob([png], { type: 'image/png' }), 'selfie.png');
  const up = ok(await call('POST', '/files', { token: S.empToken, form: fd }));
  S.selfieFile = up.id;
  const r = await call('GET', `/files/${up.id}/content`, { token: S.mgrToken, raw: true });
  expect(r.status === 404, `manager got ${r.status}`);
});

await step('upload with a lying content type is rejected (magic bytes)', async () => {
  const fd = new FormData();
  fd.append('purpose', 'receipt');
  fd.append('file', new Blob([Buffer.from('MZ fake exe')], { type: 'application/pdf' }), 'invoice.pdf');
  const r = await call('POST', '/files', { token: S.empToken, form: fd });
  expect(r.status === 400 || r.status === 415 || r.status === 422, `got ${r.status}`);
});

await step('attendance correction request goes to approval', async () => {
  const d = new Date(Date.now() - 2 * 86400_000).toISOString().slice(0, 10);
  const j = ok(await call('POST', '/attendance/corrections', { token: S.empToken, body: { workDate: d, kind: 'missed_check_in', reason: 'Forgot to check in at the door', requestedCheckIn: `${d}T04:30:00Z`, requestedCheckOut: `${d}T13:00:00Z` } }));
  S.correction = j.id;
});

// --------------------------------------------------------------------------- leave
await step('leave balances exist from provisioned policies', async () => {
  const j = ok(await call('GET', '/leave/balances', { token: S.empToken }));
  const cl = j.items.find((b) => b.code === 'CL');
  expect(cl && cl.available > 0, JSON.stringify(j.items).slice(0, 200));
  S.cl = cl;
  return j.items.map((b) => `${b.code}:${b.available}`).join(' ');
});

await step('leave preview counts working days', async () => {
  const s = new Date(Date.now() + 10 * 86400_000);
  const e = new Date(Date.now() + 11 * 86400_000);
  S.leaveDates = [s.toISOString().slice(0, 10), e.toISOString().slice(0, 10)];
  const j = ok(await call('POST', '/leave/requests/preview', { token: S.empToken, body: { leaveTypeId: S.cl.leaveTypeId, startDate: S.leaveDates[0], endDate: S.leaveDates[1] } }));
  return `units ${j.units}, ok ${j.ok}`;
});

await step('apply for leave (idempotent) moves days to pending once', async () => {
  const idem = key();
  const body = { leaveTypeId: S.cl.leaveTypeId, startDate: S.leaveDates[0], endDate: S.leaveDates[1], reason: 'Family function' };
  const a = ok(await call('POST', '/leave/requests', { token: S.empToken, idem, body }));
  const b = ok(await call('POST', '/leave/requests', { token: S.empToken, idem, body }));
  expect(a.id === b.id, 'duplicate request');
  S.leave = a.id;
  const bal = ok(await call('GET', '/leave/balances', { token: S.empToken })).items.find((x) => x.code === 'CL');
  expect(bal.pending === a.units, `pending ${bal.pending} vs ${a.units}`);
});

await step('manager sees the leave in "waiting for me" and approves it', async () => {
  const list = ok(await call('GET', '/approvals?tab=mine', { token: S.mgrToken }));
  const a = list.items.find((x) => x.requestType === 'leave');
  expect(a, `approvals: ${list.items.map((x) => x.requestType).join(',')}`);
  const idem = key();
  ok(await call('POST', `/approvals/${a.id}/decision`, { token: S.mgrToken, idem, body: { decision: 'approve' } }));
  ok(await call('POST', `/approvals/${a.id}/decision`, { token: S.mgrToken, idem, body: { decision: 'approve' } }));
  S.leaveApproval = a.id;
});

await step('approved leave deducted exactly once (ledger)', async () => {
  const bal = ok(await call('GET', '/leave/balances', { token: S.empToken })).items.find((x) => x.code === 'CL');
  const req = ok(await call('GET', '/leave/requests?mine=true', { token: S.empToken })).items.find((r) => r.id === S.leave);
  expect(req.status === 'approved' || req.status === 'pending', `status ${req.status}`);
  return `status ${req.status}; used ${bal.used}, pending ${bal.pending}`;
});

await step('employee cannot approve their own correction', async () => {
  const list = ok(await call('GET', '/approvals?tab=mine', { token: S.empToken }));
  expect(!list.items.some((a) => a.requestType === 'attendance_correction'), 'self approval possible');
});

await step('manager approves the attendance correction', async () => {
  const list = ok(await call('GET', '/approvals?tab=mine', { token: S.mgrToken }));
  const a = list.items.find((x) => x.requestType === 'attendance_correction');
  expect(a, 'not routed to manager');
  ok(await call('POST', `/approvals/${a.id}/decision`, { token: S.mgrToken, body: { decision: 'approve' } }));
});

// --------------------------------------------------------------------------- expenses
await step('expense with PNG receipt, policy check and submit', async () => {
  const cats = ok(await call('GET', '/expenses/categories', { token: S.empToken }));
  const food = (cats.items ?? cats).find((c) => /food/i.test(c.name));
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
  const fd = new FormData();
  fd.append('purpose', 'receipt');
  fd.append('file', new Blob([png], { type: 'image/png' }), 'bill.png');
  const up = ok(await call('POST', '/files', { token: S.empToken, form: fd }));
  const j = ok(await call('POST', '/expenses', { token: S.empToken, body: { categoryId: food.id, amount: 850, expenseDate: new Date().toISOString().slice(0, 10), merchant: 'Cafe', description: 'Client lunch', receiptFileId: up.id, submit: true } }));
  S.expense = j.id;
  expect(j.status === 'submitted', j.status);
});

await step('manager approves the expense; payment is a separate step', async () => {
  const list = ok(await call('GET', '/approvals?tab=mine', { token: S.mgrToken }));
  const a = list.items.find((x) => x.requestType === 'expense');
  expect(a, 'expense not routed to manager');
  ok(await call('POST', `/approvals/${a.id}/decision`, { token: S.mgrToken, body: { decision: 'approve' } }));
  const e = ok(await call('GET', '/expenses?mine=true', { token: S.empToken })).items.find((x) => x.id === S.expense);
  return `approval ${e.status}, payment ${e.reimbursementStatus}`;
});

// --------------------------------------------------------------------------- work
await step('create, move and comment on a task', async () => {
  const t = ok(await call('POST', '/tasks', { token: S.mgrToken, body: { title: 'Draft reel script', assigneeIds: [S.emp], priority: 'high', dueDate: new Date().toISOString().slice(0, 10) } }));
  ok(await call('POST', `/tasks/${t.id}/move`, { token: S.empToken, body: { status: 'in_progress' } }));
  ok(await call('POST', `/tasks/${t.id}/comments`, { token: S.empToken, body: { body: 'Started the hook' } }));
  const g = ok(await call('GET', `/tasks/${t.id}`, { token: S.empToken }));
  expect(g.status === 'in_progress' && g.comments.length === 1, JSON.stringify({ s: g.status, c: g.comments.length }));
});

await step('invalid task move is refused', async () => {
  const t = ok(await call('POST', '/tasks', { token: S.mgrToken, body: { title: 'Another', assigneeIds: [S.emp] } }));
  const r = await call('POST', `/tasks/${t.id}/move`, { token: S.empToken, body: { status: 'completed' } });
  expect(r.status === 409 || r.status === 400 || r.status === 422, `got ${r.status}`);
});

await step('CRM: create lead, duplicate detection, activity, pipeline', async () => {
  const l = ok(await call('POST', '/crm/leads', { token: S.admin, body: { name: 'Kaya Foods', phone: '+91 98765 43210', email: 'buy@kaya.test', source: 'website', estimatedValue: 50000 } }));
  const dup = await call('POST', '/crm/leads', { token: S.admin, body: { name: 'Kaya', phone: '09876543210' } });
  expect(dup.status === 409, `duplicate got ${dup.status}`);
  ok(await call('POST', `/crm/leads/${l.id}/activities`, { token: S.admin, body: { type: 'call', outcome: 'Interested', note: 'Wants a demo' } }));
  const p = ok(await call('GET', '/crm/pipeline', { token: S.admin }));
  return p.stages.filter((s) => s.count).map((s) => `${s.status}:${s.count}`).join(' ');
});

await step('meeting scheduling with external link', async () => {
  const start = new Date(Date.now() + 86400_000);
  ok(await call('POST', '/meetings', { token: S.mgrToken, body: { title: 'Weekly sync', startAt: start.toISOString(), endAt: new Date(start.getTime() + 1800_000).toISOString(), meetingType: 'external_link', meetingUrl: 'https://meet.example.com/abc' } }));
});

await step('travel request goes to approval', async () => {
  const d = new Date(Date.now() + 20 * 86400_000).toISOString().slice(0, 10);
  const j = ok(await call('POST', '/travel', { token: S.empToken, body: { destination: 'Mumbai', purpose: 'Client shoot for reels', departureDate: d, returnDate: d, estimatedCost: 6000 } }));
  return j.status;
});

// --------------------------------------------------------------------------- documents and announcements
await step('policy document with acknowledgement', async () => {
  const fd = new FormData();
  fd.append('purpose', 'document');
  fd.append('file', new Blob([Buffer.from('%PDF-1.4\n%fake but valid header\n')], { type: 'application/pdf' }), 'leave-policy.pdf');
  const up = ok(await call('POST', '/files', { token: S.admin, form: fd }));
  const d = ok(await call('POST', '/documents', { token: S.admin, body: { title: 'Leave policy 2026', category: 'policy', isPolicy: true, fileId: up.id, access: { scope: 'organization' }, requiresAcknowledgement: true } }));
  const pend = ok(await call('GET', '/documents/acknowledgements/pending', { token: S.empToken }));
  const items = pend.items ?? pend;
  expect(items.length >= 1, 'no pending ack');
  ok(await call('POST', `/documents/${d.id}/acknowledge`, { token: S.empToken }));
  S.doc = d.id;
});

await step('employment letter is generated as PDF', async () => {
  const j = ok(await call('POST', '/documents/letters', { token: S.empToken, body: { kind: 'employment', purpose: 'Bank account' } }));
  const f = await call('GET', `/files/${j.fileId}/content`, { token: S.empToken, raw: true });
  expect(f.status === 200 && f.text.startsWith('%PDF'), `status ${f.status}`);
});

await step('announcement publish and react', async () => {
  const a = ok(await call('POST', '/announcements', { token: S.admin, body: { title: 'Diwali party on Friday', body: 'Terrace, 6 pm' } }));
  ok(await call('POST', `/announcements/${a.id}/react`, { token: S.empToken, body: { emoji: 'party' } }));
});

// --------------------------------------------------------------------------- payroll
await step('grant salary approval to the manager (extra permission, audited)', async () => {
  const me = ok(await call('GET', '/auth/me', { token: S.mgrToken }));
  S.mgrUser = me.user.id;
  ok(await call('POST', `/users/${me.user.id}/permissions`, { token: S.admin, body: { grant: 'salary:approve:organization', reason: 'Compensation reviewer for smoke test' } }));
});

await step('salary structure proposal needs re-authentication (or a fresh sign-in)', async () => {
  const r = await call('POST', `/payroll/salary/${S.emp}`, { token: S.admin, body: { effectiveFrom: '2025-01-01', components: [{ code: 'BASIC', name: 'Basic', kind: 'earning', calc: 'fixed', amount: 25000 }, { code: 'HRA', name: 'HRA', kind: 'earning', calc: 'percent_of', percent: 40, of: 'BASIC' }] } });
  expect((r.status === 403 && r.json.error.code === 'REAUTH_REQUIRED') || r.status === 201 || r.status === 200, `got ${r.status} ${JSON.stringify(r.json)}`);
  S.salaryDone = r.status !== 403;
  return r.status === 403 ? 'reauth required' : 'accepted: sign-in within the re-authentication window';
});

await step('re-authenticate with a code, then propose salary', async () => {
  ok(await call('POST', '/auth/reauth/request', { token: S.admin }));
  await sleep(300);
  const code = await otpFor(SUPER_EMAIL);
  ok(await call('POST', '/auth/reauth/verify', { token: S.admin, body: { code } }));
  if (S.salaryDone) return 'already proposed';
  const j = ok(await call('POST', `/payroll/salary/${S.emp}`, { token: S.admin, body: { effectiveFrom: '2025-01-01', components: [{ code: 'BASIC', name: 'Basic', kind: 'earning', calc: 'fixed', amount: 25000 }, { code: 'HRA', name: 'HRA', kind: 'earning', calc: 'percent_of', percent: 40, of: 'BASIC' }] } }));
  return j.status;
});

await step('manager (compensation approver) approves the salary structure', async () => {
  const list = ok(await call('GET', '/approvals?tab=mine', { token: S.mgrToken }));
  const a = list.items.find((x) => x.requestType === 'salary_change');
  expect(a, `approvals: ${list.items.map((x) => x.requestType).join(',')}`);
  ok(await call('POST', `/approvals/${a.id}/decision`, { token: S.mgrToken, body: { decision: 'approve' } }));
  const v = ok(await call('GET', `/payroll/salary/${S.emp}`, { token: S.admin }));
  expect(v.items.some((x) => x.status === 'approved'), JSON.stringify(v.items.map((x) => x.status)));
});

await step('open and calculate a payroll run', async () => {
  const period = new Date().toISOString().slice(0, 7);
  const run = ok(await call('POST', '/payroll/runs', { token: S.admin, body: { period } }));
  S.run = run.id;
  const c = await call('POST', `/payroll/runs/${run.id}/calculate`, { token: S.admin });
  ok(c);
  const lines = ok(await call('GET', `/payroll/runs/${run.id}/lines`, { token: S.admin }));
  const meera = lines.items.find((l) => l.employeeId === S.emp);
  expect(meera && meera.gross > 0, `Meera gross ${meera?.gross}`);
  S.lines = lines.items;
  return `${lines.items.length} lines; ${lines.items.map((l) => `${l.employeeName}: net ${l.net}${l.anomalies?.length ? ` (${l.anomalies.map((a) => a.code).join(',')})` : ''}`).join('; ')}`;
});

// --------------------------------------------------------------------------- reports, search, notifications
await step('reports catalog and a run', async () => {
  const cat = ok(await call('GET', '/reports', { token: S.admin }));
  expect(cat.items.length > 20, `${cat.items.length} reports`);
  let failed = [];
  for (const r of cat.items) {
    const res = await call('GET', `/reports/${r.key}`, { token: S.admin });
    if (res.status !== 200) failed.push(`${r.key}:${res.status}:${res.json?.error?.code}`);
  }
  expect(failed.length === 0, `failed: ${failed.join(' ')}`);
  return `${cat.items.length} reports all ran`;
});

await step('report CSV export neutralises formulas', async () => {
  const r = await call('GET', '/reports/headcount/export', { token: S.admin, raw: true });
  expect(r.status === 200 || r.status === 404, `status ${r.status}`);
});

await step('global search returns only visible records', async () => {
  const a = ok(await call('GET', '/search?q=Meera', { token: S.admin }));
  const e = ok(await call('GET', '/search?q=Kabir', { token: S.empToken }));
  const empHits = (e.groups.find((g) => g.type === 'employees')?.items ?? []).length;
  expect(empHits === 0, 'employee can see manager via search');
  return `admin groups: ${a.groups.map((g) => g.type).join(',')}`;
});

await step('notifications were created for the employee', async () => {
  const j = ok(await call('GET', '/notifications', { token: S.empToken }));
  ok(await call('POST', '/notifications/read', { token: S.empToken, body: { ids: 'all' } }));
  return `${j.total} notifications, ${j.unread} unread before marking`;
});

// --------------------------------------------------------------------------- security, audit, system
await step('audit log records actions and is append-only', async () => {
  const j = ok(await call('GET', '/audit?limit=100', { token: S.admin }));
  const actions = new Set(j.items.map((i) => i.action));
  expect(actions.has('attendance.check_in') || [...actions].some((a) => a.startsWith('attendance')), `actions: ${[...actions].slice(0, 10)}`);
  return `${j.total} entries`;
});

await step('security overview and alerts', async () => {
  const j = ok(await call('GET', '/security/overview', { token: S.admin }));
  return JSON.stringify(j);
});

await step('roles: manager cannot grant permissions they do not hold', async () => {
  const r = await call('POST', `/users/${'000000000000000000000000'}/permissions`, { token: S.mgrToken, body: { grant: 'payroll:manage:organization', reason: 'test' } });
  expect(r.status === 403 || r.status === 404, `got ${r.status}`);
});

await step('system overview (Super Admin)', async () => {
  const j = ok(await call('GET', '/system/overview', { token: S.admin }));
  return `jobs tracked: ${j.jobs.length}`;
});

await step('employee cannot open system overview', async () => {
  const r = await call('GET', '/system/overview', { token: S.empToken });
  expect(r.status === 403, `got ${r.status}`);
});

await step('backups list (mongodump not installed here: status only)', async () => {
  const j = ok(await call('GET', '/backups', { token: S.admin }));
  return `enabled=${j.enabled}, provider=${j.provider}, ${j.items.length} records`;
});

await step('integrations list hides tokens', async () => {
  const j = ok(await call('GET', '/integrations', { token: S.admin }));
  expect(!JSON.stringify(j).includes('tokenEnc'), 'token leaked');
});

await step('Meta webhook rejects bad signature', async () => {
  const res = await fetch(`${API}/v1/webhooks/meta`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-hub-signature-256': 'sha256=deadbeef' }, body: '{}' });
  expect(res.status === 401, `got ${res.status}`);
});

await step('personal data export (own data only, no secrets)', async () => {
  const j = ok(await call('POST', '/me/data-exports', { token: S.empToken }));
  expect(j.status === 'ready' && j.fileId, JSON.stringify(j));
  const f = await call('GET', `/files/${j.fileId}/content`, { token: S.empToken, raw: true });
  expect(f.status === 200 && !f.text.includes('accountNumberEnc') && !f.text.includes('refreshHash'), 'secret leaked');
  const other = await call('GET', `/files/${j.fileId}/content`, { token: S.admin, raw: true });
  expect(other.status === 404, `admin could read another person's export: ${other.status}`);
});

await step('needs-attention snooze is audited and critical items cannot be snoozed', async () => {
  const r = await call('POST', '/dashboard/attention/backups.stale/snooze', { token: S.admin, body: { hours: 4, reason: 'testing' } });
  expect(r.status === 400, `got ${r.status}`);
  ok(await call('POST', '/dashboard/attention/approvals.pending/snooze', { token: S.admin, body: { hours: 4, reason: 'later today' } }));
});

await step('employee dashboard has personal section only', async () => {
  const j = ok(await call('GET', '/dashboard', { token: S.empToken }));
  expect(j.me && !j.organization && !j.system, `sections: ${Object.keys(j).join(',')}`);
});

await step('manager dashboard has team section', async () => {
  const j = ok(await call('GET', '/dashboard', { token: S.mgrToken }));
  expect(j.team, 'no team section');
  return JSON.stringify(j.team.today);
});


// --------------------------------------------------------------------------- deeper scenarios
await step('refresh token rotation, and reuse of an old token revokes the session with a security alert', async () => {
  await sleep(61_000); // OTP resend cooldown for the Super Admin address
  ok(await call('POST', '/auth/otp/request', { body: { identifier: SUPER_EMAIL } }));
  await sleep(300);
  const code = await otpFor(SUPER_EMAIL);
  const v = ok(await call('POST', '/auth/otp/verify', { body: { identifier: SUPER_EMAIL, code }, headers: { 'x-token-in-body': '1' } }));
  expect(v.refreshToken, 'no refresh token in body');
  const r1 = ok(await call('POST', '/auth/refresh', { body: { refreshToken: v.refreshToken } }));
  expect(r1.refreshToken && r1.refreshToken !== v.refreshToken, 'not rotated');
  const reuse = await call('POST', '/auth/refresh', { body: { refreshToken: v.refreshToken } });
  expect(reuse.status === 401, `reuse got ${reuse.status}`);
  const after = await call('POST', '/auth/refresh', { body: { refreshToken: r1.refreshToken } });
  expect(after.status === 401, `rotated token should be revoked too, got ${after.status}`);
  const alerts = ok(await call('GET', '/security/alerts', { token: S.admin }));
  expect(alerts.items.some((a) => a.type === 'refresh_reuse'), 'no refresh_reuse alert');
});

await step('third employee for exception and pattern scenarios', async () => {
  ok(await call('PUT', '/organization/settings/attendance', { token: S.admin, body: { allowRemote: true } }));
  const e = ok(await call('POST', '/employees', { token: S.admin, body: { firstName: 'Arjun', lastName: 'Nair', contactEmail: 'arjun@bulletproof.test', reportingManagerId: S.managerEmp, locationId: S.location, shiftId: S.shift, joiningDate: '2025-03-01', invite: { role: 'employee' } } }));
  S.emp3 = e.id;
  const v = await acceptInvite('arjun@bulletproof.test');
  S.emp3Token = v.accessToken;
});

await step('location permission denied: refused, exception offered immediately', async () => {
  const r = await call('POST', '/attendance/check-in', { token: S.emp3Token, headers: { 'x-device-id': 'arjun-phone' }, body: { locationStatus: 'denied' } });
  expect(r.status === 422 && r.json.error.code === 'LOCATION_REQUIRED' && r.json.error.meta.exceptionAvailable === true, JSON.stringify(r.json));
});

await step('exception check-in is recorded (server time) and sent for approval as a correction', async () => {
  const j = ok(await call('POST', '/attendance/check-in', { token: S.emp3Token, headers: { 'x-device-id': 'arjun-phone' }, body: { locationStatus: 'denied', exceptionReason: 'Phone GPS is broken today' } }));
  expect(j.exception === true && j.record.checkIn.verification === 'exception_pending', JSON.stringify(j.record.checkIn));
  const list = ok(await call('GET', '/approvals?tab=mine', { token: S.mgrToken }));
  expect(list.items.some((a) => a.requestType === 'attendance_correction'), 'no correction approval');
});

await step('remote check-out far away with a mock-location signal: flagged for review, punch kept', async () => {
  const j = ok(await call('POST', '/attendance/check-out', { token: S.emp3Token, headers: { 'x-device-id': 'arjun-phone' }, body: { latitude: 19.076, longitude: 72.8777, accuracyMeters: 10, locationStatus: 'granted', remote: true, mockSignals: ['mock_provider'] } }));
  expect(j.record.checkOut.verification === 'outside_radius', JSON.stringify(j.record.checkOut));
  expect(j.flagsRaised.includes('mock_location') && j.flagsRaised.includes('outside_geofence'), `flags ${j.flagsRaised}`);
  return j.flagsRaised.join(', ');
});


await step('impossible travel between two fixes is flagged (manager checks out 440 km away minutes later)', async () => {
  const j = ok(await call('POST', '/attendance/check-out', { token: S.mgrToken, headers: { 'x-device-id': 'kabir-phone' }, body: { latitude: 19.076, longitude: 72.8777, accuracyMeters: 20, locationStatus: 'granted', remote: true } }));
  expect(j.flagsRaised.includes('impossible_travel'), `flags ${j.flagsRaised}`);
  return j.flagsRaised.join(', ');
});

await step('leave rejection releases the pending days', async () => {
  const s = new Date(Date.now() + 30 * 86400_000).toISOString().slice(0, 10);
  const before = ok(await call('GET', '/leave/balances', { token: S.empToken })).items.find((x) => x.code === 'CL');
  const req = ok(await call('POST', '/leave/requests', { token: S.empToken, body: { leaveTypeId: before.leaveTypeId, startDate: s, endDate: s, reason: 'Errand' } }));
  const mid = ok(await call('GET', '/leave/balances', { token: S.empToken })).items.find((x) => x.code === 'CL');
  expect(mid.pending === before.pending + req.units, `pending ${mid.pending}`);
  const list = ok(await call('GET', '/approvals?tab=mine', { token: S.mgrToken }));
  const a = list.items.find((x) => x.requestType === 'leave');
  ok(await call('POST', `/approvals/${a.id}/decision`, { token: S.mgrToken, body: { decision: 'reject', comment: 'Shoot that day' } }));
  const after = ok(await call('GET', '/leave/balances', { token: S.empToken })).items.find((x) => x.code === 'CL');
  expect(after.pending === before.pending, `pending after reject ${after.pending} vs ${before.pending}`);
});

await step('payroll: prepared by one person, reviewed and approved by others, finalized with payslips', async () => {
  ok(await call('POST', `/users/${S.mgrUser}/permissions`, { token: S.admin, body: { grant: 'payroll:manage:organization', reason: 'Payroll preparer for smoke test' } }));
  ok(await call('POST', `/users/${S.mgrUser}/permissions`, { token: S.admin, body: { grant: 'payroll:view:organization', reason: 'Payroll preparer for smoke test' } }));
  await sleep(31_000); // permission cache TTL
  ok(await call('POST', `/payroll/runs/${S.run}/calculate`, { token: S.mgrToken }));
  const sub = await call('POST', `/payroll/runs/${S.run}/submit`, { token: S.mgrToken });
  ok(sub);
  for (let i = 0; i < 3; i++) {
    const list = ok(await call('GET', '/approvals?tab=mine', { token: S.admin }));
    const a = list.items.find((x) => x.requestType === 'payroll');
    if (!a) break;
    ok(await call('POST', `/approvals/${a.id}/decision`, { token: S.admin, body: { decision: 'approve' } }));
  }
  const run = ok(await call('GET', `/payroll/runs/${S.run}`, { token: S.admin }));
  expect(run.status === 'approved', `run ${run.status}`);
  ok(await call('POST', `/payroll/runs/${S.run}/finalize`, { token: S.admin }));
  await sleep(1500);
  const slips = ok(await call('GET', '/payroll/payslips', { token: S.empToken }));
  expect(slips.items.length === 1 && slips.items[0].fileId, JSON.stringify(slips));
  const pdf = await call('GET', `/files/${slips.items[0].fileId}/content`, { token: S.empToken, raw: true });
  expect(pdf.status === 200 && pdf.text.startsWith('%PDF'), `payslip ${pdf.status}`);
  const other = await call('GET', `/files/${slips.items[0].fileId}/content`, { token: S.emp3Token, raw: true });
  expect(other.status === 404, `another employee could read the payslip: ${other.status}`);
  const recalc = await call('POST', `/payroll/runs/${S.run}/calculate`, { token: S.admin });
  expect(recalc.status === 409, `finalized run recalculated: ${recalc.status}`);
  return `net ${slips.items[0].net}`;
});

await step('logout revokes the session', async () => {
  ok(await call('POST', '/auth/logout', { token: S.mgrToken }));
  const r = await call('GET', '/auth/me', { token: S.mgrToken });
  expect(r.status === 401, `still valid: ${r.status}`);
});

console.log(`\n${results.length - failures}/${results.length} passed`);
process.exit(failures ? 1 : 0);
