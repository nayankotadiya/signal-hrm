import { Module } from '@nestjs/common';
import { WorkModule } from '../work/work.module';
import { IntegrationsController, MetaWebhookController } from './integrations.controller';
import { IntegrationsService } from './integrations.service';

@Module({
  imports: [WorkModule],
  controllers: [IntegrationsController, MetaWebhookController],
  providers: [IntegrationsService],
})
export class IntegrationsModule {}
