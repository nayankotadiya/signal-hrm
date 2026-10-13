/**
 * Pure payroll arithmetic (no I/O), so it can be unit-tested exhaustively.
 * Amounts are rupees with paise precision; every intermediate is rounded to 2 decimals.
 * No tax rates are hardcoded: statutory deductions come only from configured, validated rules.
 */

export interface Component {
  code: string;
  name: string;
  kind: 'earning' | 'deduction';
  calc: 'fixed' | 'percent_of';
  amount?: number;
  percent?: number;
  of?: string;
  prorate?: boolean;
}

export interface StatutoryRule {
  code: string;
  name?: string;
  kind: 'deduction' | 'employer_contribution';
  basis: 'component' | 'gross' | 'slab';
  basisComponent?: string;
  percent?: number;
  cap?: number;
  wageCeiling?: number;
  slabs?: { upTo: number; amount: number }[];
}

export interface PayInputs {
  periodDays: number; // days used as the divisor (calendar, working or fixed 30)
  payableDays: number; // periodDays minus loss-of-pay days
  adjustments?: { amount: number; reason: string }[]; // + adds, - recovers
  reimbursements?: number;
}

export interface Line {
  earnings: { code: string; name: string; amount: number }[];
  deductions: { code: string; name: string; amount: number }[];
  employerContributions: { code: string; name: string; amount: number }[];
  gross: number;
  totalDeductions: number;
  net: number;
}

export const r2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100;

/** Monthly (full-period) value of every component, resolving percent_of chains (cycles are rejected). */
export function resolveComponents(components: Component[]): Map<string, number> {
  const byCode = new Map(components.map((c) => [c.code, c]));
  const out = new Map<string, number>();
  const visiting = new Set<string>();
  const value = (code: string): number => {
    if (out.has(code)) return out.get(code)!;
    const c = byCode.get(code);
    if (!c) throw new Error(`Component ${code} is referenced but not defined`);
    if (visiting.has(code)) throw new Error(`Component ${code} refers to itself through percent_of`);
    visiting.add(code);
    const v = c.calc === 'fixed' ? (c.amount ?? 0) : r2(((c.percent ?? 0) / 100) * value(c.of ?? ''));
    visiting.delete(code);
    out.set(code, r2(v));
    return out.get(code)!;
  };
  for (const c of components) value(c.code);
  return out;
}

export function monthlyGross(components: Component[]): number {
  const v = resolveComponents(components);
  return r2(components.filter((c) => c.kind === 'earning').reduce((a, c) => a + (v.get(c.code) ?? 0), 0));
}

function statutory(rule: StatutoryRule, earnings: Map<string, number>, gross: number): number {
  if (rule.basis === 'slab') {
    const slab = (rule.slabs ?? []).slice().sort((a, b) => a.upTo - b.upTo).find((s) => gross <= s.upTo);
    return r2(slab?.amount ?? 0);
  }
  let base = rule.basis === 'gross' ? gross : (earnings.get(rule.basisComponent ?? '') ?? 0);
  if (rule.wageCeiling) base = Math.min(base, rule.wageCeiling);
  let amt = r2(((rule.percent ?? 0) / 100) * base);
  if (rule.cap != null) amt = Math.min(amt, rule.cap);
  return r2(amt);
}

/** One employee's line for one period. */
export function calculateLine(components: Component[], inputs: PayInputs, rules: StatutoryRule[]): Line {
  if (inputs.periodDays <= 0) throw new Error('periodDays must be positive');
  const payable = Math.max(0, Math.min(inputs.payableDays, inputs.periodDays));
  const factor = payable / inputs.periodDays;
  const full = resolveComponents(components);

  const earnings: Line['earnings'] = [];
  const earnedBy = new Map<string, number>();
  for (const c of components.filter((x) => x.kind === 'earning')) {
    const amount = r2((full.get(c.code) ?? 0) * (c.prorate === false ? 1 : factor));
    earnedBy.set(c.code, amount);
    earnings.push({ code: c.code, name: c.name, amount });
  }
  if (inputs.reimbursements) earnings.push({ code: 'REIMB', name: 'Reimbursements', amount: r2(inputs.reimbursements) });
  for (const a of inputs.adjustments ?? []) if (a.amount > 0) earnings.push({ code: 'ADJ', name: `Adjustment: ${a.reason}`, amount: r2(a.amount) });

  const gross = r2(earnings.filter((e) => e.code !== 'REIMB').reduce((a, e) => a + e.amount, 0));

  const deductions: Line['deductions'] = [];
  for (const c of components.filter((x) => x.kind === 'deduction')) {
    deductions.push({ code: c.code, name: c.name, amount: r2((full.get(c.code) ?? 0) * (c.prorate === false ? 1 : factor)) });
  }
  const employerContributions: Line['employerContributions'] = [];
  for (const rule of rules) {
    const amount = statutory(rule, earnedBy, gross);
    if (!amount) continue;
    (rule.kind === 'deduction' ? deductions : employerContributions).push({ code: rule.code, name: rule.name ?? rule.code, amount });
  }
  for (const a of inputs.adjustments ?? []) if (a.amount < 0) deductions.push({ code: 'RECOVERY', name: `Recovery: ${a.reason}`, amount: r2(-a.amount) });

  const totalDeductions = r2(deductions.reduce((a, d) => a + d.amount, 0));
  const reimb = r2(inputs.reimbursements ?? 0);
  return { earnings, deductions, employerContributions, gross, totalDeductions, net: r2(gross + reimb - totalDeductions) };
}

/** Loss-of-pay days from attendance: absent days + unpaid leave + half of half-days. */
export function lopDays(i: { absentDays: number; unpaidLeaveDays: number; halfDays: number }): number {
  return r2(i.absentDays + i.unpaidLeaveDays + i.halfDays * 0.5);
}
