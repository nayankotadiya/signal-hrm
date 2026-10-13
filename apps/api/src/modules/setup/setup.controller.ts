import { Body, Controller, Get, HttpCode, HttpStatus, Inject, Post } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import { Public } from '../../common/auth/context';
import { safeEqual } from '../../common/crypto/crypto';
import { ApiError } from '../../common/errors/api-error';
import { parse } from '../../common/http/validation';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { FirstAdminService } from './first-admin.service';

const firstAdmin = z.object({
  token: z.string().min(1).max(300),
  organization: z.string().trim().min(2).max(120),
  fullName: z.string().trim().min(2).max(120),
  email: z.string().trim().email().max(160),
  password: z.string().min(1).max(200),
});

/**
 * Public sign-in screen configuration and the one-time first-admin setup for hosts without a
 * shell (for example Render). Setup needs the SETUP_TOKEN from the server's environment and only
 * works while no Super Admin exists.
 */
@ApiTags('setup')
@Public()
@Controller({ path: 'setup', version: '1' })
export class SetupController {
  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly firstAdmin: FirstAdminService,
  ) {}

  @Get('status')
  async status() {
    const needsSetup = await this.firstAdmin.needsSetup();
    return {
      needsSetup,
      setupAvailable: needsSetup && !!this.env.SETUP_TOKEN,
      passwordLogin: this.env.PASSWORD_LOGIN,
      emailCodes: !!this.env.SMTP_HOST || this.env.APP_ENV === 'development',
      smsCodes: !!this.env.TWILIO_ACCOUNT_SID || !!this.env.FAST2SMS_API_KEY || !!this.env.SMS_GATEWAY_URL || this.env.APP_ENV === 'development',
      googleAuth: this.env.GOOGLE_CLIENT_IDS.length > 0,
    };
  }

  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('first-admin')
  @HttpCode(201)
  async create(@Body() body: unknown) {
    const b = parse(firstAdmin, body);
    if (!this.env.SETUP_TOKEN) throw new ApiError(HttpStatus.NOT_FOUND, 'SETUP_DISABLED', 'Setup from the sign-in screen is turned off on this server.');
    if (!safeEqual(b.token.trim(), this.env.SETUP_TOKEN)) throw new ApiError(HttpStatus.FORBIDDEN, 'SETUP_TOKEN_INVALID', "That setup key doesn't match the server's SETUP_TOKEN.");
    if (!this.env.PASSWORD_LOGIN) {
      throw new ApiError(HttpStatus.CONFLICT, 'PASSWORD_LOGIN_DISABLED', 'Set PASSWORD_LOGIN=true on the server first, so you can sign in with the password you choose.');
    }
    return this.firstAdmin.create({ organization: b.organization, fullName: b.fullName, email: b.email, password: b.password }, 'setup_screen');
  }
}
