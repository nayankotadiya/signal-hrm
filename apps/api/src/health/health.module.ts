import { Module } from '@nestjs/common';
import { ApiHealthCheck, BackupsHealthCheck, DatabaseHealthCheck, JobsHealthCheck, NotificationsHealthCheck, RedisHealthCheck, StorageHealthCheck } from './checks/checks';
import { HealthController } from './health.controller';
import { HEALTH_CHECKS, HealthService } from './health.service';
import type { HealthCheck } from './health.types';

const CHECKS = [ApiHealthCheck, DatabaseHealthCheck, RedisHealthCheck, StorageHealthCheck, BackupsHealthCheck, JobsHealthCheck, NotificationsHealthCheck];

@Module({
  controllers: [HealthController],
  providers: [
    ...CHECKS,
    { provide: HEALTH_CHECKS, inject: CHECKS, useFactory: (...checks: HealthCheck[]): HealthCheck[] => checks },
    HealthService,
  ],
  exports: [HealthService],
})
export class HealthModule {}
