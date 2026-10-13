import { Module } from '@nestjs/common';
import { CrmService } from './crm.service';
import { TasksService } from './tasks.service';
import { MeetingsService, TravelService } from './travel-meetings.service';
import { CrmController, MeetingsController, TasksController, TravelController } from './work.controllers';

@Module({
  controllers: [TasksController, CrmController, TravelController, MeetingsController],
  providers: [TasksService, CrmService, TravelService, MeetingsService],
  exports: [TasksService, CrmService, TravelService, MeetingsService],
})
export class WorkModule {}
