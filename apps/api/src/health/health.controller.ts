import { Controller, Get, HttpCode, Res } from '@nestjs/common';
import { ApiOkResponse, ApiOperation, ApiServiceUnavailableResponse, ApiTags } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';
import type { Response } from 'express';
import { AllowWithoutDatabase, Public } from '../common/auth/context';
import { HealthService } from './health.service';
import type { HealthSummary } from './health.types';

/**
 * Public health endpoints. Responses contain states, reasons and latencies only: no hosts,
 * connection strings or driver messages. Detailed error logs are a privileged view (Phase 11).
 */
@ApiTags('health')
@Public()
@AllowWithoutDatabase()
@SkipThrottle()
@Controller({ path: 'health', version: '1' })
export class HealthController {
  constructor(private readonly health: HealthService) {}

  @Get()
  @ApiOperation({ summary: 'Per-component health: healthy | degraded | unavailable | unknown' })
  @ApiOkResponse({ description: 'Health summary (always 200; read `state`)' })
  async summary(): Promise<HealthSummary> {
    return this.health.summary();
  }

  @Get('live')
  @HttpCode(200)
  @ApiOperation({ summary: 'Liveness probe: the process is running' })
  live(): { state: 'healthy' } {
    return { state: 'healthy' };
  }

  @Get('ready')
  @ApiOperation({ summary: 'Readiness probe: 503 when a critical component is unavailable' })
  @ApiServiceUnavailableResponse({ description: 'Not ready to serve traffic' })
  async ready(@Res({ passthrough: true }) res: Response): Promise<HealthSummary> {
    const summary = await this.health.summary();
    if (summary.state === 'unavailable') res.status(503);
    return summary;
  }
}
