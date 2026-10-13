import { Module } from '@nestjs/common';
import { EmployeesController } from './employees.controller';
import { EmployeesService } from './employees.service';
import { DepartmentsController, TeamsController } from './org-structure.controller';

@Module({ controllers: [EmployeesController, DepartmentsController, TeamsController], providers: [EmployeesService], exports: [EmployeesService] })
export class PeopleModule {}
