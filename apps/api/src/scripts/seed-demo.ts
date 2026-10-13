/**
 * Demo data for development and staging ONLY. Refuses to run when APP_ENV=production.
 *
 *   npm run seed:demo -- --admin-email you@example.com
 *
 * Creates a separate organization named "Signal HRM Demo" so demo records can never mix with a
 * real organization's data. Every demo employee uses the reserved domain demo.signal-hrm.test.
 * Re-running removes the previous demo organization's records first.
 */
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { Model, Types } from 'mongoose';
import { loadEnv } from '../config/env.schema';
import { DatabaseService } from '../database/database.service';
import { MODELS } from '../database/models.module';
import { ProvisioningService } from '../modules/setup/provisioning.service';
import { ScriptsModule } from './scripts.module';

const DEMO_ORG = 'Signal HRM Demo';
const DOMAIN = 'demo.signal-hrm.test';

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : undefined;
}

/** Small deterministic generator so the demo looks the same on every run. */
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function day(offset: number): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + offset);
  return d.toISOString().slice(0, 10);
}

function at(dayStr: string, hhmm: string): Date {
  // Demo organization uses Asia/Kolkata (UTC+05:30).
  const [h, m] = hhmm.split(':').map(Number);
  return new Date(Date.parse(`${dayStr}T00:00:00Z`) + ((h * 60 + m - 330) * 60_000));
}

async function main(): Promise<void> {
  try {
    process.loadEnvFile('.env');
  } catch {
    /* env from process */
  }
  const env = loadEnv();
  if (env.APP_ENV === 'production') throw new Error('Refusing to seed demo data in production.');
  if (!env.MONGODB_URI) throw new Error('MONGODB_URI is required');
  const adminEmail = arg('admin-email')?.toLowerCase();

  const app = await NestFactory.createApplicationContext(ScriptsModule, { logger: ['error', 'warn'] });
  const db = app.get(DatabaseService);
  await db.connection.asPromise();
  const m = (n: string): Model<any> => db.connection.model(n);

  // Clean previous demo organization (org-scoped collections only).
  const previous = await m('Organization').findOne({ name: DEMO_ORG }).lean<any>();
  if (previous) {
    for (const name of Object.keys(MODELS)) {
      if (name === 'AuditLog') continue; // append-only by design: the old demo's audit trail is kept
      const model = m(name);
      if (model.schema.path('organizationId')) await model.deleteMany({ organizationId: previous._id });
    }
    await m('Organization').deleteOne({ _id: previous._id });
  }

  const org = (await m('Organization').create({ name: DEMO_ORG, legalName: 'Signal HRM Demo Pvt Ltd', timezone: 'Asia/Kolkata', supportEmail: `hr@${DOMAIN}` })).toObject();
  const o = org._id as Types.ObjectId;
  await app.get(ProvisioningService).provision(o);
  const r = rng(42);
  const pick = <T>(a: T[]): T => a[Math.floor(r() * a.length)];

  const depts = await m('Department').find({ organizationId: o }).lean<any[]>();
  const loc = await m('Location').create({ organizationId: o, name: 'Ahmedabad studio', address: 'SG Highway, Ahmedabad', latitude: 23.0225, longitude: 72.5714, radiusMeters: 150, active: true });
  const shift = await m('Shift').create({ organizationId: o, name: 'General', startTime: '10:00', endTime: '19:00', breakMinutes: 60, graceMinutes: 10, workingDays: [1, 2, 3, 4, 5, 6], locationIds: [loc._id] });

  const people: [string, string, string, string][] = [
    ['Aarav', 'Shah', 'Founder', 'super_admin'],
    ['Diya', 'Patel', 'HR Manager', 'hr'],
    ['Kabir', 'Mehta', 'Content Lead', 'manager'],
    ['Isha', 'Desai', 'Meta Ads Lead', 'manager'],
    ['Rohan', 'Joshi', 'Shopify Lead', 'manager'],
    ['Meera', 'Iyer', 'Content Writer', 'employee'],
    ['Vihaan', 'Rao', 'Video Editor', 'employee'],
    ['Anaya', 'Kulkarni', 'Media Buyer', 'employee'],
    ['Arjun', 'Nair', 'Performance Analyst', 'employee'],
    ['Saanvi', 'Bhat', 'Store Developer', 'employee'],
    ['Reyansh', 'Trivedi', 'Catalogue Executive', 'employee'],
    ['Kiara', 'Chopra', 'Community Moderator', 'moderator'],
  ];
  if (adminEmail && (await m('User').exists({ email: adminEmail }))) throw new Error(`${adminEmail} already has an account in another organization. Use a different --admin-email.`);
  const otherSuperAdmin = await m('User').exists({ role: 'super_admin' });
  const deptFor = (i: number) => depts[i < 2 ? 0 : (i - 2) % depts.length]._id;
  const emps: any[] = [];
  for (let i = 0; i < people.length; i++) {
    const [first, last, designation, baseRole] = people[i];
    const role = baseRole === 'super_admin' && otherSuperAdmin ? 'admin' : baseRole;
    const email = i === 0 && adminEmail ? adminEmail : `${first.toLowerCase()}.${last.toLowerCase()}@${DOMAIN}`;
    const e = await m('Employee').create({
      organizationId: o,
      employeeCode: `DEMO-${String(i + 1).padStart(3, '0')}`,
      firstName: first,
      lastName: last,
      contactEmail: email,
      designation,
      departmentId: deptFor(i),
      locationId: loc._id,
      shiftId: shift._id,
      status: i === 11 ? 'probation' : 'active',
      probation: i === 11 ? { status: 'on_probation', endsOn: new Date(Date.now() + 7 * 86400_000) } : { status: 'none' },
      joiningDate: new Date(Date.now() - (60 + i * 45) * 86400_000),
    });
    const u = await m('User').create({ organizationId: o, fullName: `${first} ${last}`, displayName: first, email, emailVerified: true, role, status: 'active', employeeId: e._id, timezone: 'Asia/Kolkata' });
    await m('Employee').updateOne({ _id: e._id }, { $set: { userId: u._id } });
    emps.push({ ...e.toObject(), userId: u._id, role });
  }
  // Reporting lines: leads report to the founder, team members to their department lead.
  const leadByDept = new Map<string, any>();
  for (const e of emps.filter((x) => x.role === 'manager')) leadByDept.set(String(e.departmentId), e);
  for (const e of emps.slice(1)) {
    const mgr = e.role === 'manager' || e.role === 'hr' ? emps[0] : (leadByDept.get(String(e.departmentId)) ?? emps[0]);
    await m('Employee').updateOne({ _id: e._id }, { $set: { reportingManagerId: mgr._id } });
  }
  for (const [dept, lead] of leadByDept) await m('Department').updateOne({ _id: new Types.ObjectId(dept) }, { $set: { headEmployeeId: lead._id } });

  // Attendance: last 14 days, Monday-Saturday.
  let attendanceRows = 0;
  for (let d = -13; d <= -1; d++) {
    const ds = day(d);
    if (new Date(`${ds}T00:00:00Z`).getUTCDay() === 0) continue;
    for (const e of emps) {
      if (r() < 0.07) continue; // absent
      const lateMin = r() < 0.18 ? Math.floor(r() * 40) + 11 : 0;
      const inAt = at(ds, `10:${String(Math.min(59, Math.max(0, lateMin ? lateMin : Math.floor(r() * 9)))).padStart(2, '0')}`);
      const outAt = new Date(inAt.getTime() + (8.5 + r() * 1.5) * 3600_000);
      const worked = Math.round((outAt.getTime() - inAt.getTime()) / 60_000) - 60;
      const dist = Math.round(r() * 90);
      await m('Attendance').create({
        organizationId: o,
        employeeId: e._id,
        workDate: ds,
        shiftId: shift._id,
        checkIn: { at: inAt, method: 'geofence', latitude: 23.0225, longitude: 72.5714, accuracyMeters: 12 + Math.round(r() * 30), locationId: loc._id, distanceMeters: dist, verification: 'within_radius' },
        checkOut: { at: outAt, method: 'geofence', latitude: 23.0225, longitude: 72.5714, accuracyMeters: 15, locationId: loc._id, distanceMeters: dist, verification: 'within_radius' },
        breakMinutes: 60,
        workedMinutes: worked,
        lateMinutes: lateMin,
        status: lateMin ? 'late' : 'present',
      });
      attendanceRows++;
    }
  }

  // Leave: balances are created lazily by the app; add a few requests.
  const types = await m('LeaveType').find({ organizationId: o }).lean<any[]>();
  const cl = types.find((t) => t.code === 'CL');
  const sl = types.find((t) => t.code === 'SL');
  await m('LeaveRequest').create({ organizationId: o, employeeId: emps[5]._id, leaveTypeId: cl._id, startDate: day(5), endDate: day(6), units: 2, reason: 'Family function', status: 'pending' });
  await m('LeaveRequest').create({ organizationId: o, employeeId: emps[7]._id, leaveTypeId: sl._id, startDate: day(-3), endDate: day(-3), units: 1, reason: 'Fever', status: 'approved', decidedAt: new Date() });

  // Holidays and an announcement.
  const year = new Date().getUTCFullYear();
  for (const [date, name] of [[`${year}-10-20`, 'Diwali'], [`${year}-10-21`, 'Govardhan Puja'], [`${year}-11-05`, 'Guru Nanak Jayanti'], [`${year}-12-25`, 'Christmas']]) {
    await m('Holiday').create({ organizationId: o, date, name, locationIds: [] });
  }
  await m('Announcement').create({ organizationId: o, kind: 'announcement', title: 'Welcome to the Signal HRM demo', body: 'This organization contains demo data for evaluation only.', pinned: true, publishedAt: new Date(), createdBy: emps[1].userId });

  // Tasks and leads.
  const statuses = ['todo', 'in_progress', 'in_review', 'completed'];
  for (let i = 0; i < 18; i++) {
    const a = pick(emps.slice(2));
    await m('Task').create({ organizationId: o, title: pick(['Draft reel script', 'Refresh ad creatives', 'Fix product filters', 'Write blog post', 'Weekly ROAS report', 'Update size chart', 'Edit testimonial video']) + ` #${i + 1}`, createdBy: emps[2].userId, assigneeIds: [a._id], departmentId: a.departmentId, priority: pick(['low', 'medium', 'high']), status: pick(statuses), dueDate: day(Math.floor(r() * 14) - 5), order: i });
  }
  for (let i = 0; i < 24; i++) {
    const owner = pick(emps.filter((e) => String(e.departmentId) === String(depts[1]?._id)).concat(emps[3]));
    await m('Lead').create({ organizationId: o, name: `Demo lead ${i + 1}`, company: pick(['Kaya Foods', 'Urban Loom', 'Nimbus Labs', 'Sattva Home', 'Craft Kettle']), phone: `+9198${String(10000000 + i * 7919).slice(0, 8)}`, phoneNormalized: `+9198${String(10000000 + i * 7919).slice(0, 8)}`, source: pick(['meta', 'website', 'referral', 'manual']), ownerEmployeeId: owner._id, status: pick(['new', 'contacted', 'qualified', 'proposal', 'won', 'lost']), interest: pick(['cold', 'warm', 'hot']), estimatedValue: Math.round(r() * 200) * 1000, nextFollowUpAt: new Date(Date.now() + (Math.floor(r() * 10) - 4) * 86400_000), createdBy: owner.userId });
  }

  /* eslint-disable no-console */
  console.log(`\nDemo organization "${DEMO_ORG}" created: ${emps.length} employees, ${attendanceRows} attendance records, 18 tasks, 24 leads.`);
  const adminRole = otherSuperAdmin ? 'Admin' : 'Super Admin';
  console.log(adminEmail ? `Sign in as ${adminEmail} (${adminRole} of the demo organization).` : `Demo accounts use @${DOMAIN}. Pass --admin-email to sign in as the demo ${adminRole}.`);
  await app.close();
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e); // eslint-disable-line no-console
  process.exit(1);
});
