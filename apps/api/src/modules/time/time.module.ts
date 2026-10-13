import { Module } from '@nestjs/common';
import { AttendanceService } from './attendance.service';
import { LeaveService } from './leave.service';
import { ShiftsService } from './shifts.service';
import { AttendanceController, HolidaysController, LeaveController, LocationsController, ShiftsController } from './time.controllers';

@Module({
  controllers: [AttendanceController, LocationsController, ShiftsController, LeaveController, HolidaysController],
  providers: [AttendanceService, ShiftsService, LeaveService],
  exports: [AttendanceService, ShiftsService, LeaveService],
})
export class TimeModule {}
