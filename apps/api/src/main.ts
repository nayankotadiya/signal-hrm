import 'reflect-metadata';
import { Logger, LogLevel } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { configureApp } from './bootstrap';
import { loadEnv } from './config/env.schema';

const LEVELS: LogLevel[] = ['error', 'warn', 'log', 'debug', 'verbose'];

/** Loads `.env` from the working directory when present. Real environment variables win. */
function loadDotEnv(): void {
  try {
    process.loadEnvFile('.env');
  } catch {
    // no .env file: rely on the process environment (production containers)
  }
}

async function bootstrap(): Promise<void> {
  loadDotEnv();
  const env = loadEnv(); // fail fast with a readable list of configuration problems
  const app = await NestFactory.create(AppModule, {
    rawBody: true, // webhook signatures are verified over the exact bytes received
    logger: LEVELS.slice(0, LEVELS.indexOf(env.LOG_LEVEL) + 1),
  });
  configureApp(app, env);
  await app.listen(env.PORT, '0.0.0.0');
  Logger.log(`Signal HRM API (${env.APP_ENV}) on :${env.PORT}/${env.API_PREFIX}/v1`, 'Bootstrap');
}

bootstrap().catch((err: unknown) => {
  // eslint-disable-next-line no-console
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
