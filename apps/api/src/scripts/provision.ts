/**
 * Re-applies default provisioning to every organization (safe to run repeatedly, e.g. after an upgrade
 * adds new permissions). Never overwrites customised roles other than Super Admin, which always holds
 * every grant.
 *
 *   npm run provision
 */
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { loadEnv } from '../config/env.schema';
import { DatabaseService } from '../database/database.service';
import { ProvisioningService } from '../modules/setup/provisioning.service';
import { ScriptsModule } from './scripts.module';

async function main(): Promise<void> {
  try {
    process.loadEnvFile('.env');
  } catch {
    /* env from process */
  }
  const env = loadEnv();
  if (!env.MONGODB_URI) throw new Error('MONGODB_URI is required');
  const app = await NestFactory.createApplicationContext(ScriptsModule, { logger: ['error', 'warn'] });
  const db = app.get(DatabaseService);
  await db.connection.asPromise();
  const orgs = await db.connection.model('Organization').find({}, { name: 1 }).lean<any[]>();
  for (const o of orgs) {
    await app.get(ProvisioningService).provision(o._id);
    // eslint-disable-next-line no-console
    console.log(`Provisioned: ${o.name}`);
  }
  if (!orgs.length) console.log('No organizations yet. Run "npm run bootstrap" first.'); // eslint-disable-line no-console
  await app.close();
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e); // eslint-disable-line no-console
  process.exit(1);
});
