import { Body, Controller, Delete, Get, Headers, HttpCode, Param, Post, Put, Query, Req } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { RawBodyRequest } from '@nestjs/common';
import type { Request } from 'express';
import { z } from 'zod';
import { C, Ctx, Public } from '../../common/auth/context';
import { objectId, parse } from '../../common/http/validation';
import { IntegrationsService } from './integrations.service';

const PROVIDERS = z.enum(['meta_leads', 'whatsapp', 'sms']);

@ApiTags('integrations')
@Controller({ path: 'integrations', version: '1' })
export class IntegrationsController {
  constructor(private readonly svc: IntegrationsService) {}

  @Get()
  list(@C() ctx: Ctx) {
    return this.svc.list(ctx);
  }

  @Put('meta')
  connectMeta(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.connectMeta(
      ctx,
      parse(
        z.object({
          accessToken: z.string().trim().min(20).max(1000),
          pageId: z.string().trim().regex(/^\d{3,30}$/, 'Page ID is numeric.'),
          defaultOwnerEmployeeId: objectId.optional(),
          formIds: z.array(z.string().regex(/^\d{3,30}$/)).max(50).optional(),
        }),
        body,
      ),
    );
  }

  @Delete(':provider')
  async disconnect(@C() ctx: Ctx, @Param('provider') provider: string) {
    await this.svc.disconnect(ctx, parse(PROVIDERS, provider));
    return { disconnected: true };
  }

  @Get(':provider/logs')
  logs(@C() ctx: Ctx, @Param('provider') provider: string) {
    return this.svc.syncLogs(ctx, parse(PROVIDERS, provider));
  }

  @Post('logs/:id/retry')
  @HttpCode(200)
  retry(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.retry(ctx, id);
  }
}

/** Meta webhook: public, authenticated by verify token (GET) and HMAC signature (POST). */
@ApiTags('webhooks')
@Public()
@Controller({ path: 'webhooks/meta', version: '1' })
export class MetaWebhookController {
  constructor(private readonly svc: IntegrationsService) {}

  @Get()
  verify(@Query('hub.mode') mode?: string, @Query('hub.verify_token') token?: string, @Query('hub.challenge') challenge?: string) {
    return this.svc.verifyChallenge(mode, token, challenge);
  }

  @Post()
  @HttpCode(200)
  receive(@Req() req: RawBodyRequest<Request>, @Headers('x-hub-signature-256') sig: string | undefined, @Body() body: unknown) {
    return this.svc.receive(req.rawBody, sig, body);
  }
}
