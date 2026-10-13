import { DatabaseHealthCheck, NotYetImplementedCheck, StorageHealthCheck, timedCheck } from './checks';
import { NotConfiguredStorageProvider } from '../../storage/not-configured.provider';
import { loadEnv } from '../../config/env.schema';
import type { DatabaseService } from '../../database/database.service';

const env = loadEnv({ APP_ENV: 'development', HEALTH_CHECK_TIMEOUT_MS: '50', HEALTH_DB_DEGRADED_MS: '20' });

describe('timedCheck', () => {
  it('is healthy for a fast check', async () => {
    const r = await timedCheck(async () => undefined, 50, 20);
    expect(r.state).toBe('healthy');
    expect(r.latencyMs).toBeGreaterThanOrEqual(0);
  });
  it('is degraded for a slow but successful check', async () => {
    const r = await timedCheck(() => new Promise((res) => setTimeout(res, 30)), 200, 10);
    expect(r).toMatchObject({ state: 'degraded', reason: 'slow_response' });
  });
  it('is unavailable on timeout', async () => {
    const r = await timedCheck(() => new Promise((res) => setTimeout(res, 100)), 10, 5);
    expect(r).toMatchObject({ state: 'unavailable', reason: 'timeout' });
  });
  it('is unavailable on failure', async () => {
    const r = await timedCheck(() => Promise.reject(new Error('boom')), 50, 20);
    expect(r).toMatchObject({ state: 'unavailable', reason: 'check_failed' });
  });
});

describe('DatabaseHealthCheck', () => {
  const fakeDb = (over: Partial<DatabaseService> = {}) =>
    ({
      configured: true,
      readyState: 'connected',
      ping: async () => undefined,
      getStorageStats: async () => ({
        isAbove90Percent: false,
        percentUsed: 15,
        totalSizeMb: 76.8,
        limitMb: 512,
        dataSizeMb: 50,
        storageSizeMb: 60,
        indexSizeMb: 16.8,
      }),
      ...over,
    }) as unknown as DatabaseService;

  it('is unknown when no database is configured (never green without a check)', async () => {
    const r = await new DatabaseHealthCheck(fakeDb({ configured: false } as never), env).check();
    expect(r).toEqual({ state: 'unknown', reason: 'not_configured' });
  });
  it('is unavailable while disconnected', async () => {
    const r = await new DatabaseHealthCheck(fakeDb({ readyState: 'disconnected' } as never), env).check();
    expect(r.state).toBe('unavailable');
  });
  it('is healthy only after a real ping', async () => {
    let pinged = false;
    const r = await new DatabaseHealthCheck(fakeDb({ ping: async () => void (pinged = true) } as never), env).check();
    expect(pinged).toBe(true);
    expect(r.state).toBe('healthy');
  });
  it('is degraded with storage_almost_full when storage is above 90%', async () => {
    const r = await new DatabaseHealthCheck(
      fakeDb({
        getStorageStats: async () => ({
          isAbove90Percent: true,
          percentUsed: 94.2,
          totalSizeMb: 482.3,
          limitMb: 512,
          dataSizeMb: 400,
          storageSizeMb: 460,
          indexSizeMb: 22.3,
        }),
      }),
      env,
    ).check();
    expect(r.state).toBe('degraded');
    expect(r.reason).toBe('storage_almost_full');
  });
});

describe('placeholder checks', () => {
  it('storage without a provider is unknown/not_configured', async () => {
    const r = await new StorageHealthCheck(new NotConfiguredStorageProvider(), env).check();
    expect(r).toEqual({ state: 'unknown', reason: 'not_configured' });
  });
  it('unimplemented components are unknown, never healthy', async () => {
    const r = await new NotYetImplementedCheck('backups').check();
    expect(r.state).toBe('unknown');
  });
});
