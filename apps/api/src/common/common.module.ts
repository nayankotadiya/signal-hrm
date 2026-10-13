import { Global, Module } from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { JwtModule } from '@nestjs/jwt';
import { APP_CONFIG } from '../config/config.module';
import { AppEnv, secretOf } from '../config/env.schema';
import { AuditService } from './audit/audit.service';
import { AuthGuard } from './auth/auth.guard';
import { PermissionsService } from './authz/permissions.service';
import { ScopeService } from './authz/scope.service';
import { IdempotencyInterceptor } from './idempotency/idempotency.interceptor';
import { MailService } from './mail/mail.service';
import { OrgSettingsService } from './org/org-settings.service';
import { SmsService } from './sms/sms.service';

@Global()
@Module({
  imports: [
    JwtModule.registerAsync({
      global: true,
      inject: [APP_CONFIG],
      useFactory: (env: AppEnv) => ({
        secret: secretOf(env, 'JWT_SECRET'),
        signOptions: { algorithm: 'HS256', expiresIn: env.ACCESS_TOKEN_TTL_SECONDS, issuer: 'signal-hrm' },
        verifyOptions: { algorithms: ['HS256'], issuer: 'signal-hrm' },
      }),
    }),
  ],
  providers: [
    PermissionsService,
    ScopeService,
    AuditService,
    MailService,
    SmsService,
    OrgSettingsService,
    { provide: APP_GUARD, useClass: AuthGuard },
    { provide: APP_INTERCEPTOR, useClass: IdempotencyInterceptor },
  ],
  exports: [PermissionsService, ScopeService, AuditService, MailService, SmsService, OrgSettingsService],
})
export class CommonModule {}
