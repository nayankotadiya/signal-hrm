import { INestApplication, VersioningType } from '@nestjs/common';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import helmet from 'helmet';
import type { AppEnv } from './config/env.schema';

/** Shared HTTP setup for main.ts and e2e tests so tests exercise the real configuration. */
export function configureApp(app: INestApplication, env: AppEnv): void {
  app.setGlobalPrefix(env.API_PREFIX);
  app.enableVersioning({ type: VersioningType.URI, defaultVersion: '1' }); // -> /api/v1/...
  if (env.TRUST_PROXY > 0) app.getHttpAdapter().getInstance().set('trust proxy', env.TRUST_PROXY);
  app.use(helmet());
  const origins: (string | RegExp)[] = env.CORS_ORIGINS.map((o) =>
    o.includes('*') ? new RegExp(`^${o.replace(/\./g, '\\.').replace(/\*/g, '.*')}$`) : o,
  );
  app.enableCors({
    origin: origins.length ? origins : env.APP_ENV === 'development',
    credentials: true,
    exposedHeaders: ['x-correlation-id', 'content-disposition'],
    allowedHeaders: ['content-type', 'authorization', 'idempotency-key', 'x-correlation-id', 'x-device-id'],
  });
  app.enableShutdownHooks();

  if (env.APP_ENV !== 'production') {
    const doc = new DocumentBuilder()
      .setTitle('Signal HRM API')
      .setDescription('People • Work • Time • Operations')
      .setVersion('1')
      .addBearerAuth()
      .build();
    SwaggerModule.setup(`${env.API_PREFIX}/docs`, app, SwaggerModule.createDocument(app, doc));
  }
}
