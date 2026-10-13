import { Global, Module } from '@nestjs/common';
import { BackupsController } from './backups.controller';
import { BackupsService } from './backups.service';

@Global()
@Module({ controllers: [BackupsController], providers: [BackupsService], exports: [BackupsService] })
export class BackupsModule {}
