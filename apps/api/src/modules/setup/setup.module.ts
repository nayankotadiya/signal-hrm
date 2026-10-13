import { Global, Module } from '@nestjs/common';
import { FirstAdminService } from './first-admin.service';
import { ProvisioningService } from './provisioning.service';
import { SetupController } from './setup.controller';

@Global()
@Module({ controllers: [SetupController], providers: [ProvisioningService, FirstAdminService], exports: [ProvisioningService, FirstAdminService] })
export class SetupModule {}
