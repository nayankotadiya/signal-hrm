/**
 * One-time, server-side Super Admin bootstrap (structure section 3).
 *
 *   npm run bootstrap -- --org "Bulletproof Brands" --name "Nayan Kotadiya" --email nayan@example.com [--password '…']
 *
 * Creates the organization (if none exists), provisions roles and defaults, creates the first
 * Super Admin with an employee record, and prints 10 recovery codes ONCE (only hashes are stored).
 * Refuses to run when a Super Admin already exists: recovery uses the normal recovery flow instead.
 */
import 'reflect-metadata';
import * as dns from 'node:dns';
import { NestFactory } from '@nestjs/core';
import { loadEnv } from '../config/env.schema';
import { DatabaseService } from '../database/database.service';
import { FirstAdminService } from '../modules/setup/first-admin.service';
import { ScriptsModule } from './scripts.module';

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : undefined;
}

async function main(): Promise<void> {
  try {
    const current = dns.getServers();
    if (!current.includes('8.8.8.8')) {
      dns.setServers(['8.8.8.8', '8.8.4.4', ...current]);
    }
  } catch {}
  try {
    process.loadEnvFile('.env');
  } catch {
    /* env from process */
  }
  const env = loadEnv();
  const orgName = arg('org') ?? 'Signal HRM';
  const name = arg('name') ?? 'Nayan Kotadiya';
  const email = arg('email')?.toLowerCase();
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('Pass --email name@company.com');
  if (!env.MONGODB_URI) throw new Error('MONGODB_URI is required');

  const password = arg('password');
  const app = await NestFactory.createApplicationContext(ScriptsModule, { logger: ['error', 'warn'] });
  const db = app.get(DatabaseService);
  await db.connection.asPromise();
  const result = await app.get(FirstAdminService).create({ organization: orgName, fullName: name, email, password }, 'script');

  /* eslint-disable no-console */
  console.log(`\nSuper Admin created: ${name} <${result.email}> in "${result.organization}".`);
  console.log(password ? 'Sign in with this email and the password you chose.\n' : 'Sign in on the normal login screen with an email code.\n');
  console.log('Recovery codes (shown once; store them offline):');
  for (const c of result.recoveryCodes) console.log(`  ${c}`);
  console.log('');
  await app.close();
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
