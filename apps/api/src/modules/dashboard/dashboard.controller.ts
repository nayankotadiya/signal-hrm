import { Body, Controller, Delete, Get, HttpCode, Param, Post, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import { C, Ctx, Idempotent } from '../../common/auth/context';
import { parse } from '../../common/http/validation';
import { AttentionService } from './attention.service';
import { DashboardService } from './dashboard.service';
import { PrivacyService } from './privacy.service';
import { SetupChecklistService } from './setup-checklist.service';

const itemKey = z.string().regex(/^[a-z_]+\.[a-z_]+$/, 'Unknown item.');

@ApiTags('dashboard')
@Controller({ path: 'dashboard', version: '1' })
export class DashboardController {
  constructor(
    private readonly dashboard: DashboardService,
    private readonly attention: AttentionService,
    private readonly checklist: SetupChecklistService,
  ) {}

  @Get()
  get(@C() ctx: Ctx) {
    return this.dashboard.get(ctx);
  }

  @Get('attention')
  async items(@C() ctx: Ctx, @Query('includeSnoozed') includeSnoozed?: string) {
    return this.attention.compute(ctx, includeSnoozed === 'true');
  }

  /** Snoozing is audited and requires a reason. Critical items cannot be snoozed. */
  @Post('attention/:key/snooze')
  @HttpCode(200)
  async snooze(@C() ctx: Ctx, @Param('key') key: string, @Body() body: unknown) {
    const b = parse(z.object({ hours: z.number().int().min(1).max(24 * 14), reason: z.string().trim().min(3).max(300) }), body);
    await this.attention.snooze(ctx, parse(itemKey, key), b.hours, b.reason);
    return { snoozed: true };
  }

  @Delete('attention/:key/snooze')
  async unsnooze(@C() ctx: Ctx, @Param('key') key: string) {
    await this.attention.unsnooze(ctx, parse(itemKey, key));
    return { snoozed: false };
  }

  @Get('setup-checklist')
  setup(@C() ctx: Ctx) {
    return this.checklist.get(ctx);
  }
}

@ApiTags('privacy')
@Controller({ path: 'me/data-exports', version: '1' })
export class PrivacyController {
  constructor(private readonly privacy: PrivacyService) {}

  @Get()
  list(@C() ctx: Ctx) {
    return this.privacy.list(ctx);
  }

  @Post()
  @Idempotent()
  request(@C() ctx: Ctx) {
    return this.privacy.request(ctx);
  }
}
