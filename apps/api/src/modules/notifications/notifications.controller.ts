import { Body, Controller, Delete, Get, HttpCode, Param, Post, Put, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import { C, Can, Ctx } from '../../common/auth/context';
import { listQuery, parse } from '../../common/http/validation';
import { CHANNELS, NOTIFICATION_EVENTS, NotificationsService } from './notifications.service';

@ApiTags('notifications')
@Controller({ path: 'notifications', version: '1' })
export class NotificationsController {
  constructor(private readonly svc: NotificationsService) {}

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(ctx, parse(listQuery.extend({ unread: z.coerce.boolean().optional() }), q));
  }

  @Post('read')
  @HttpCode(200)
  read(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.object({ ids: z.union([z.array(z.string()).max(200), z.literal('all')]) }), body);
    return this.svc.markRead(ctx, b.ids);
  }

  @Get('preferences')
  prefs(@C() ctx: Ctx) {
    return this.svc.getPreferences(ctx);
  }

  @Put('preferences')
  setPrefs(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.setPreferences(ctx, parse(z.object({ channels: z.record(z.record(z.boolean())) }), body).channels);
  }

  @Get('deliveries')
  deliveries(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.deliveryHistory(ctx, parse(listQuery, q));
  }

  @Get('templates')
  @Can('notifications', 'configure')
  templates(@C() ctx: Ctx) {
    return this.svc.templatesList(ctx);
  }

  @Put('templates')
  @Can('notifications', 'configure', 'organization')
  upsert(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(
      z.object({ event: z.enum(NOTIFICATION_EVENTS), channel: z.enum(CHANNELS), subject: z.string().max(200).optional(), body: z.string().min(1).max(5000), active: z.boolean().optional() }),
      body,
    );
    return this.svc.upsertTemplate(ctx, b);
  }

  @Delete('templates/:id')
  @Can('notifications', 'configure', 'organization')
  async remove(@C() ctx: Ctx, @Param('id') id: string) {
    await this.svc.deleteTemplate(ctx, id);
    return { deleted: true };
  }
}
