import { Module } from '@nestjs/common';
import { RolesController } from '../roles/roles.controller';
import { OrganizationController } from './organization.controller';

@Module({ controllers: [OrganizationController, RolesController] })
export class OrganizationModule {}
