import { Global, Module } from '@nestjs/common';
import { SystemCoreModule } from '../system/system-core.module';
import { NotificationsController } from './notifications.controller';
import { NotificationsService } from './notifications.service';
import { RealtimeGateway } from './realtime.gateway';
import { RealtimeService } from './realtime.service';

@Global()
@Module({
  imports: [SystemCoreModule],
  controllers: [NotificationsController],
  providers: [NotificationsService, RealtimeService, RealtimeGateway],
  exports: [NotificationsService, RealtimeService],
})
export class NotificationsModule {}
