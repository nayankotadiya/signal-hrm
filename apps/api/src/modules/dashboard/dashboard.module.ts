import { Module } from '@nestjs/common';
import { HealthModule } from '../../health/health.module';
import { AttentionService } from './attention.service';
import { DashboardController, PrivacyController } from './dashboard.controller';
import { DashboardService } from './dashboard.service';
import { PrivacyService } from './privacy.service';
import { SetupChecklistService } from './setup-checklist.service';

@Module({
  imports: [HealthModule],
  controllers: [DashboardController, PrivacyController],
  providers: [DashboardService, AttentionService, SetupChecklistService, PrivacyService],
})
export class DashboardModule {}
