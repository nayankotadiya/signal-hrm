import { Body, Controller, Get, Header, HttpCode, Param, Post, Put, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import { C, Can, Ctx, Feature, Idempotent, RequireReauth } from '../../common/auth/context';
import { badRequest, dayString, listQuery, objectId, parse } from '../../common/http/validation';
import { expenseInput, ExpensesService } from './expenses.service';
import { PayrollService, salaryInput, statutoryInput } from './payroll.service';

const categoryBody = z.object({
  name: z.string().trim().min(2).max(60),
  code: z.string().max(20).optional(),
  perClaimLimit: z.number().min(0).optional().nullable(),
  monthlyLimit: z.number().min(0).optional().nullable(),
  receiptRequiredAbove: z.number().min(0).optional().nullable(),
  active: z.boolean().default(true),
});

@ApiTags('expenses')
@Feature('expenses')
@Controller({ path: 'expenses', version: '1' })
export class ExpensesController {
  constructor(private readonly svc: ExpensesService) {}

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(ctx, parse(listQuery.extend({ mine: z.coerce.boolean().optional(), employeeId: objectId.optional(), reimbursementStatus: z.string().optional(), categoryId: objectId.optional(), from: dayString.optional(), to: dayString.optional() }), q));
  }

  @Post()
  @Idempotent()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.create(ctx, parse(expenseInput, body));
  }

  /** Live policy-limit hints for the new-expense drawer. */
  @Post('check')
  @HttpCode(200)
  check(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.object({ categoryId: objectId, amount: z.number().positive(), expenseDate: dayString }), body);
    if (!ctx.employeeOid) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    return this.svc.policyCheck(ctx, ctx.employeeOid, b);
  }

  @Get('summary')
  summary(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(z.object({ from: dayString, to: dayString, mine: z.coerce.boolean().default(false) }), q);
    return this.svc.summary(ctx, b.from, b.to, b.mine);
  }

  @Get('categories')
  async categories(@C() ctx: Ctx) {
    return { items: await this.svc.listCategories(ctx) };
  }

  @Post('categories')
  createCategory(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.saveCategory(ctx, parse(categoryBody, body));
  }

  @Put('categories/:id')
  updateCategory(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.saveCategory(ctx, parse(categoryBody, body), id);
  }

  @Get('reimbursements')
  async reimbursements(@C() ctx: Ctx, @Query() q: unknown) {
    return { items: await this.svc.listReimbursements(ctx, parse(z.object({ status: z.string().optional() }), q).status) };
  }

  @Post('reimbursements')
  @Idempotent()
  schedule(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.scheduleReimbursement(ctx, parse(z.object({ expenseIds: z.array(objectId).min(1).max(500) }), body).expenseIds);
  }

  @Post('reimbursements/:id/paid')
  @Idempotent()
  @HttpCode(200)
  paid(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.markPaid(ctx, id, parse(z.object({ paymentReference: z.string().trim().min(3).max(80) }), body).paymentReference);
  }

  @Post(':id/submit')
  @Idempotent()
  @HttpCode(200)
  submit(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.submit(ctx, id);
  }

  @Post(':id/cancel')
  @HttpCode(200)
  cancel(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.cancel(ctx, id);
  }
}

@ApiTags('payroll')
@Feature('payroll')
@Controller({ path: 'payroll', version: '1' })
export class PayrollController {
  constructor(private readonly svc: PayrollService) {}

  @Get('salary/:employeeId')
  salary(@C() ctx: Ctx, @Param('employeeId') id: string) {
    return this.svc.salaryHistory(ctx, id);
  }

  /** Proposes a new compensation version; it applies only after approval. */
  @Post('salary/:employeeId')
  @Idempotent()
  @RequireReauth()
  proposeSalary(@C() ctx: Ctx, @Param('employeeId') id: string, @Body() body: unknown) {
    return this.svc.draftSalary(ctx, id, parse(salaryInput, body));
  }

  @Get('rules')
  async rules(@C() ctx: Ctx) {
    return { items: await this.svc.listRules(ctx) };
  }

  @Put('rules')
  saveRule(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.saveRule(ctx, parse(statutoryInput, body));
  }

  @Post('rules/:code/validate')
  @RequireReauth()
  @HttpCode(200)
  validateRule(@C() ctx: Ctx, @Param('code') code: string) {
    return this.svc.validateRule(ctx, code);
  }

  @Get('runs')
  async runs(@C() ctx: Ctx) {
    return { items: await this.svc.listRuns(ctx) };
  }

  @Post('runs')
  @Idempotent()
  open(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.openRun(ctx, parse(z.object({ period: z.string() }), body).period);
  }

  @Get('runs/:id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.get(ctx, id);
  }

  @Get('runs/:id/lines')
  async lines(@C() ctx: Ctx, @Param('id') id: string, @Query() q: unknown) {
    return { items: await this.svc.linesOf(ctx, id, parse(z.object({ anomalies: z.coerce.boolean().optional() }), q).anomalies) };
  }

  @Post('runs/:id/calculate')
  @Idempotent()
  @HttpCode(200)
  calculate(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.calculate(ctx, id);
  }

  @Post('runs/:id/submit')
  @Idempotent()
  @HttpCode(200)
  submit(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.submit(ctx, id);
  }

  /** Irreversible: confirmation dialog + re-authentication on the client, pending state until done. */
  @Post('runs/:id/finalize')
  @Idempotent()
  @RequireReauth()
  @HttpCode(200)
  finalize(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.finalize(ctx, id);
  }

  @Post('runs/:id/payments')
  @Idempotent()
  @HttpCode(200)
  payments(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(z.object({ payments: z.array(z.object({ lineId: objectId, status: z.enum(['paid', 'failed']), paymentReference: z.string().trim().min(3).max(80) })).min(1).max(2000) }), body);
    return this.svc.recordPayments(ctx, id, b.payments);
  }

  @Get('runs/:id/bank-file')
  @Can('payroll', 'export', 'organization')
  @RequireReauth()
  @Header('Content-Type', 'text/csv; charset=utf-8')
  @Header('Cache-Control', 'no-store')
  bankFile(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.bankFile(ctx, id);
  }

  @Post('adjustments')
  @Idempotent()
  adjust(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.adjust(ctx, parse(z.object({ runId: objectId, employeeId: objectId, kind: z.enum(['adjustment', 'reversal']), amount: z.number().positive().max(10_000_000), reason: z.string().trim().min(5).max(300) }), body));
  }

  @Get('payslips')
  async payslips(@C() ctx: Ctx, @Query() q: unknown) {
    return { items: await this.svc.myPayslips(ctx, parse(z.object({ employeeId: objectId.optional() }), q).employeeId) };
  }

  @Post('payslips/:id/viewed')
  @HttpCode(200)
  async viewed(@C() ctx: Ctx, @Param('id') id: string) {
    await this.svc.markViewed(ctx, id);
    return { ok: true };
  }
}
