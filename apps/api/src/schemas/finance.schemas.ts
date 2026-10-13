import { Schema } from 'mongoose';
import { baseOptions, orgScoped } from '../database/model';

const { ObjectId, Mixed } = Schema.Types;

// ---------------------------------------------------------------- expenses
export const ExpenseCategorySchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true, trim: true },
      code: String,
      perClaimLimit: Number,
      monthlyLimit: Number,
      receiptRequiredAbove: Number,
      active: { type: Boolean, default: true },
    },
    { ...baseOptions, collection: 'expense_categories' },
  ),
);
ExpenseCategorySchema.index({ organizationId: 1, name: 1 }, { unique: true });

export const ExpenseSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      categoryId: { type: ObjectId, required: true },
      amount: { type: Number, required: true, min: 0 },
      currency: { type: String, default: 'INR' },
      expenseDate: { type: String, required: true },
      merchant: String,
      description: String,
      receiptFileId: ObjectId,
      taskId: ObjectId,
      travelRequestId: ObjectId,
      policyWarnings: [String],
      submittedAt: Date,
      /** Approval status. Approval never means paid. */
      status: { type: String, enum: ['draft', 'submitted', 'approved', 'rejected', 'cancelled'], default: 'draft', index: true },
      approvalId: ObjectId,
      decisionComment: String,
      /** Payment is its own status with its own action. */
      reimbursementStatus: { type: String, enum: ['not_applicable', 'pending', 'scheduled', 'paid'], default: 'not_applicable' },
      reimbursementId: ObjectId,
    },
    baseOptions,
  ),
);
ExpenseSchema.index({ organizationId: 1, expenseDate: -1 });

export const ReimbursementSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      expenseIds: [ObjectId],
      amount: { type: Number, required: true },
      currency: { type: String, default: 'INR' },
      status: { type: String, enum: ['scheduled', 'paid', 'failed'], default: 'scheduled' },
      paidAt: Date,
      paymentReference: String,
      paidBy: ObjectId,
      payrollRunId: ObjectId,
    },
    baseOptions,
  ),
);

// ---------------------------------------------------------------- salary structures (versioned)
const ComponentSchema = new Schema(
  {
    code: { type: String, required: true },
    name: { type: String, required: true },
    kind: { type: String, enum: ['earning', 'deduction'], required: true },
    /** fixed = amount per month; percent_of = percentage of another component (e.g. HRA 40% of BASIC) */
    calc: { type: String, enum: ['fixed', 'percent_of'], default: 'fixed' },
    amount: Number,
    percent: Number,
    of: String,
    taxable: { type: Boolean, default: true },
    statutory: { type: Boolean, default: false },
    prorate: { type: Boolean, default: true }, // reduced by loss-of-pay days
  },
  { _id: false },
);

export const SalaryStructureSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      version: { type: Number, required: true },
      effectiveFrom: { type: String, required: true },
      effectiveTo: String,
      currency: { type: String, default: 'INR' },
      components: { type: [ComponentSchema], default: [] },
      monthlyGross: Number,
      annualCtc: Number,
      status: { type: String, enum: ['draft', 'pending_approval', 'approved', 'rejected', 'superseded'], default: 'draft' },
      approvalId: ObjectId,
      createdBy: ObjectId,
      approvedBy: ObjectId,
      note: String,
    },
    { ...baseOptions, collection: 'salary_structures' },
  ),
);
SalaryStructureSchema.index({ organizationId: 1, employeeId: 1, version: 1 }, { unique: true });

/** Jurisdiction rules are configuration, never hardcoded (structure section 14). */
export const StatutoryRuleSchema = orgScoped(
  new Schema(
    {
      code: { type: String, required: true }, // e.g. PF_EMPLOYEE, ESI_EMPLOYEE, PT_GJ, TDS
      name: String,
      kind: { type: String, enum: ['deduction', 'employer_contribution'], default: 'deduction' },
      basis: { type: String, enum: ['component', 'gross', 'slab'], default: 'component' },
      basisComponent: String,
      percent: Number,
      cap: Number, // max deduction per month
      wageCeiling: Number, // apply on min(basis, ceiling)
      slabs: [{ upTo: Number, amount: Number }],
      active: { type: Boolean, default: false },
      validatedBy: ObjectId, // must be validated before production use
      validatedAt: Date,
    },
    { ...baseOptions, collection: 'statutory_rules' },
  ),
);

// ---------------------------------------------------------------- payroll
export const PAYROLL_STAGES = ['collect', 'calculate', 'review', 'approve', 'finalize', 'pay'] as const;

export const PayrollRunSchema = orgScoped(
  new Schema(
    {
      periodStart: { type: String, required: true },
      periodEnd: { type: String, required: true },
      label: String, // "Oct 2026"
      stage: { type: String, enum: PAYROLL_STAGES, default: 'collect' },
      status: { type: String, enum: ['open', 'calculated', 'in_review', 'pending_approval', 'approved', 'finalized', 'paid', 'cancelled'], default: 'open' },
      calculationVersion: { type: Number, default: 0 },
      totals: { employees: Number, gross: Number, deductions: Number, net: Number, employerCost: Number },
      anomalies: { type: Number, default: 0 },
      approvalId: ObjectId,
      preparedBy: ObjectId,
      reviewedBy: ObjectId,
      finalizedBy: ObjectId,
      finalizedAt: Date,
      lockedAt: Date,
      paidAt: Date,
    },
    { ...baseOptions, collection: 'payroll_runs' },
  ),
);
PayrollRunSchema.index({ organizationId: 1, periodStart: 1 }, { unique: true });

/** One line per employee per run. */
export const PayrollLineSchema = orgScoped(
  new Schema(
    {
      runId: { type: ObjectId, required: true, index: true },
      employeeId: { type: ObjectId, required: true },
      salaryStructureId: ObjectId,
      salaryVersion: Number,
      inputs: {
        periodDays: Number,
        payableDays: Number,
        lopDays: Number,
        presentDays: Number,
        paidLeaveDays: Number,
        unpaidLeaveDays: Number,
        absentDays: Number,
        overtimeMinutes: Number,
        reimbursements: Number,
      },
      earnings: [{ code: String, name: String, amount: Number }],
      deductions: [{ code: String, name: String, amount: Number }],
      employerContributions: [{ code: String, name: String, amount: Number }],
      gross: Number,
      totalDeductions: Number,
      net: Number,
      anomalies: [{ code: String, message: String, severity: String }],
      previousNet: Number,
      paymentStatus: { type: String, enum: ['pending', 'paid', 'failed', 'on_hold'], default: 'pending' },
      paymentReference: String,
      payslipId: ObjectId,
      calculationVersion: Number,
    },
    { ...baseOptions, collection: 'payroll' },
  ),
);
PayrollLineSchema.index({ organizationId: 1, runId: 1, employeeId: 1 }, { unique: true });

/** Corrections to finalized payroll: audited adjustment or reversal, never an edit. */
export const PayrollAdjustmentSchema = orgScoped(
  new Schema(
    {
      runId: { type: ObjectId, required: true },
      lineId: ObjectId,
      employeeId: { type: ObjectId, required: true },
      kind: { type: String, enum: ['adjustment', 'reversal'], required: true },
      amount: Number, // + adds to net, - recovers
      reason: { type: String, required: true },
      appliesToRunId: ObjectId, // next period run that carries it
      status: { type: String, enum: ['pending', 'applied', 'cancelled'], default: 'pending' },
      createdBy: ObjectId,
    },
    { ...baseOptions, collection: 'payroll_adjustments' },
  ),
);

export const PayslipSchema = orgScoped(
  new Schema(
    {
      runId: { type: ObjectId, required: true },
      lineId: { type: ObjectId, required: true },
      employeeId: { type: ObjectId, required: true, index: true },
      period: String,
      fileId: ObjectId,
      net: Number,
      publishedAt: Date,
      viewedAt: Date,
    },
    baseOptions,
  ),
);
PayslipSchema.index({ organizationId: 1, employeeId: 1, period: -1 });

// ---------------------------------------------------------------- travel
export const TravelRequestSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      destination: { type: String, required: true },
      purpose: { type: String, required: true },
      departureDate: { type: String, required: true },
      returnDate: { type: String, required: true },
      transport: { mode: String, details: String },
      accommodation: { details: String, nights: Number },
      estimatedCost: { type: Number, default: 0 },
      currency: { type: String, default: 'INR' },
      attachmentFileIds: [ObjectId],
      status: { type: String, enum: ['draft', 'pending', 'approved', 'rejected', 'cancelled', 'booked', 'completed', 'settled'], default: 'pending' },
      approvalId: ObjectId,
      booking: { reference: String, details: String, bookedBy: ObjectId, bookedAt: Date },
      actualCost: Number,
      settlementStatus: { type: String, enum: ['not_started', 'pending', 'settled'], default: 'not_started' },
      settledAt: Date,
      settlementNote: String,
    },
    { ...baseOptions, collection: 'travel_requests' },
  ),
);

export const MixedPayload = Mixed;
