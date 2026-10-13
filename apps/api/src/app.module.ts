import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { APP_FILTER, APP_GUARD } from '@nestjs/core';
import { ScheduleModule } from '@nestjs/schedule';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { CommonModule } from './common/common.module';
import { CorrelationIdMiddleware } from './common/correlation/correlation-id.middleware';
import { AllExceptionsFilter } from './common/errors/all-exceptions.filter';
import { APP_CONFIG, AppConfigModule } from './config/config.module';
import type { AppEnv } from './config/env.schema';
import { DatabaseModule } from './database/database.module';
import { ModelsModule } from './database/models.module';
import { HealthModule } from './health/health.module';
import { ApprovalsModule } from './modules/approvals/approvals.module';
import { AuthModule } from './modules/auth/auth.module';
import { BackupsModule } from './modules/backups/backups.module';
import { DocumentsModule } from './modules/documents/documents.module';
import { FilesModule } from './modules/files/files.module';
import { FinanceModule } from './modules/finance/finance.module';
import { NotificationsModule } from './modules/notifications/notifications.module';
import { OrganizationModule } from './modules/organization/organization.module';
import { PeopleModule } from './modules/people/people.module';
import { ReportsModule } from './modules/reports/reports.module';
import { SecurityModule } from './modules/security/security.module';
import { IntegrationsModule } from './modules/integrations/integrations.module';
import { DashboardModule } from './modules/dashboard/dashboard.module';
import { SetupModule } from './modules/setup/setup.module';
import { TimeModule } from './modules/time/time.module';
import { SystemCoreModule } from './modules/system/system-core.module';
import { SystemModule } from './modules/system/system.module';
import { UsersModule } from './modules/users/users.module';
import { WorkModule } from './modules/work/work.module';
import { RedisModule } from './redis/redis.module';
import { StorageModule } from './storage/storage.module';

/**
 * Root module. Feature modules live in src/modules/<name> and share the global services:
 * authorization (CommonModule), approvals, notifications, audit, storage and jobs.
 */
@Module({
  imports: [
    AppConfigModule,
    ThrottlerModule.forRootAsync({
      inject: [APP_CONFIG],
      useFactory: (env: AppEnv) => [{ ttl: env.RATE_LIMIT_TTL_MS, limit: env.RATE_LIMIT_MAX }],
    }),
    ScheduleModule.forRoot(),
    DatabaseModule,
    ModelsModule,
    RedisModule,
    StorageModule,
    CommonModule,
    SystemCoreModule,
    NotificationsModule,
    FilesModule,
    ApprovalsModule,
    AuthModule,
    UsersModule,
    SetupModule,
    OrganizationModule,
    PeopleModule,
    TimeModule,
    FinanceModule,
    WorkModule,
    DocumentsModule,
    ReportsModule,
    BackupsModule,
    SecurityModule,
    IntegrationsModule,
    DashboardModule,
    SystemModule,
    HealthModule,
  ],
  providers: [
    { provide: APP_GUARD, useClass: ThrottlerGuard },
    { provide: APP_FILTER, useClass: AllExceptionsFilter },
  ],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(CorrelationIdMiddleware).forRoutes('{*path}');
  }
}
