import { Inject, Injectable } from '@nestjs/common';
import { APP_CONFIG } from '../config/config.module';
import type { AppEnv } from '../config/env.schema';
import { aggregateHealth, ComponentHealth, HealthCheck, HealthSummary, withTimeout } from './health.types';

export const HEALTH_CHECKS = Symbol('HEALTH_CHECKS');
export const APP_VERSION = process.env.npm_package_version ?? '0.1.0';

@Injectable()
export class HealthService {
  private cachedSummary?: { summary: HealthSummary; expiresAt: number };

  constructor(
    @Inject(HEALTH_CHECKS) private readonly checks: HealthCheck[],
    @Inject(APP_CONFIG) private readonly env: AppEnv,
  ) {}

  async summary(force = false): Promise<HealthSummary> {
    const now = Date.now();
    if (!force && this.cachedSummary && now < this.cachedSummary.expiresAt) {
      return this.cachedSummary.summary;
    }
    const components: ComponentHealth[] = await Promise.all(
      this.checks.map(async (c) => {
        let result: Awaited<ReturnType<HealthCheck['check']>>;
        try {
          result = await withTimeout(c.check(), this.env.HEALTH_CHECK_TIMEOUT_MS + 500);
        } catch (e) {
          result = { state: c.critical ? 'unavailable' : 'unknown', reason: e instanceof Error && e.message === 'timeout' ? 'timeout' : 'check_failed' };
        }
        return { component: c.component, critical: c.critical, checkedAt: new Date().toISOString(), ...result };
      }),
    );
    const summary: HealthSummary = {
      state: aggregateHealth(components),
      checkedAt: new Date().toISOString(),
      version: APP_VERSION,
      environment: this.env.APP_ENV,
      components,
    };
    this.cachedSummary = { summary, expiresAt: now + 30_000 };
    return summary;
  }
}
