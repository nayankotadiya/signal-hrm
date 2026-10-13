import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { configureApp } from '../src/bootstrap';
import { loadEnv } from '../src/config/env.schema';

describe('Health API (e2e, no data stores configured)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    process.env.APP_ENV = 'development';
    delete process.env.MONGODB_URI;
    delete process.env.REDIS_URL;
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication({ logger: false });
    configureApp(app, loadEnv());
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /api/v1/health reports every component and never claims green without a check', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/health').expect(200);
    const byName = Object.fromEntries(res.body.components.map((c: { component: string }) => [c.component, c]));
    expect(Object.keys(byName).sort()).toEqual(['api', 'backups', 'database', 'jobs', 'notifications', 'redis', 'storage']);
    expect(byName.api.state).toBe('healthy');
    expect(byName.database).toMatchObject({ state: 'unknown', reason: 'not_configured', critical: true });
    expect(byName.redis).toMatchObject({ state: 'unknown', reason: 'not_configured' });
    expect(byName.backups.state).toBe('unknown');
    // a critical component could not be checked -> overall unknown, not healthy
    expect(res.body.state).toBe('unknown');
    expect(res.headers['x-correlation-id']).toMatch(/^[0-9a-f-]{36}$/);
  });

  it('reuses a well-formed incoming correlation ID and replaces a malformed one', async () => {
    const ok = await request(app.getHttpServer()).get('/api/v1/health/live').set('x-correlation-id', 'pwa-abc12345');
    expect(ok.headers['x-correlation-id']).toBe('pwa-abc12345');
    const bad = await request(app.getHttpServer()).get('/api/v1/health/live').set('x-correlation-id', '<script>');
    expect(bad.headers['x-correlation-id']).not.toBe('<script>');
  });

  it('GET /api/v1/health/ready is 200 when nothing critical is unavailable', async () => {
    await request(app.getHttpServer()).get('/api/v1/health/ready').expect(200);
  });

  it('unknown routes return the structured error shape', async () => {
    const res = await request(app.getHttpServer()).get('/api/v1/nope').expect(404);
    expect(res.body.error).toMatchObject({ status: 404, code: 'NOT_FOUND' });
    expect(res.body.error.correlationId).toEqual(res.headers['x-correlation-id']);
  });

  it('serves OpenAPI docs outside production', async () => {
    await request(app.getHttpServer()).get('/api/docs-json').expect(200);
  });
});
