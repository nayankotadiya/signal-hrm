import { Module } from '@nestjs/common';
import { ExpensesController, PayrollController } from './finance.controllers';
import { ExpensesService } from './expenses.service';
import { PayrollService } from './payroll.service';

@Module({ controllers: [ExpensesController, PayrollController], providers: [ExpensesService, PayrollService], exports: [ExpensesService, PayrollService] })
export class FinanceModule {}
