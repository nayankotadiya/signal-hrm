import { calculateLine, lopDays, monthlyGross, r2, resolveComponents } from './payroll.calc';

const structure = [
  { code: 'BASIC', name: 'Basic', kind: 'earning' as const, calc: 'fixed' as const, amount: 25000 },
  { code: 'HRA', name: 'House rent', kind: 'earning' as const, calc: 'percent_of' as const, percent: 40, of: 'BASIC' },
  { code: 'SPECIAL', name: 'Special', kind: 'earning' as const, calc: 'fixed' as const, amount: 10000 },
  { code: 'CANTEEN', name: 'Canteen', kind: 'deduction' as const, calc: 'fixed' as const, amount: 500, prorate: false },
];

describe('payroll arithmetic', () => {
  it('rounds to paise without float drift', () => {
    expect(r2(0.1 + 0.2)).toBe(0.3);
    expect(r2(1.005)).toBe(1.01);
  });

  it('resolves percent_of chains and rejects cycles and missing references', () => {
    expect(resolveComponents(structure).get('HRA')).toBe(10000);
    expect(monthlyGross(structure)).toBe(45000);
    expect(() => resolveComponents([{ code: 'A', name: 'A', kind: 'earning', calc: 'percent_of', percent: 10, of: 'B' }, { code: 'B', name: 'B', kind: 'earning', calc: 'percent_of', percent: 10, of: 'A' }])).toThrow(/itself/);
    expect(() => resolveComponents([{ code: 'A', name: 'A', kind: 'earning', calc: 'percent_of', percent: 10, of: 'X' }])).toThrow(/not defined/);
  });

  it('full month: gross, fixed deduction, statutory rules from configuration only', () => {
    const line = calculateLine(structure, { periodDays: 30, payableDays: 30 }, [
      { code: 'PF_EE', kind: 'deduction', basis: 'component', basisComponent: 'BASIC', percent: 12, wageCeiling: 15000 },
      { code: 'PF_ER', kind: 'employer_contribution', basis: 'component', basisComponent: 'BASIC', percent: 12, wageCeiling: 15000 },
      { code: 'PT', kind: 'deduction', basis: 'slab', slabs: [{ upTo: 15000, amount: 0 }, { upTo: 20000, amount: 150 }, { upTo: 1e12, amount: 200 }] },
    ]);
    expect(line.gross).toBe(45000);
    expect(line.deductions.find((d) => d.code === 'PF_EE')!.amount).toBe(1800); // 12% of the 15,000 ceiling
    expect(line.deductions.find((d) => d.code === 'PT')!.amount).toBe(200);
    expect(line.employerContributions[0].amount).toBe(1800);
    expect(line.totalDeductions).toBe(2500);
    expect(line.net).toBe(42500);
  });

  it('no rules configured means no statutory deductions are invented', () => {
    const line = calculateLine(structure, { periodDays: 30, payableDays: 30 }, []);
    expect(line.deductions.map((d) => d.code)).toEqual(['CANTEEN']);
  });

  it('loss of pay prorates prorated components only', () => {
    const line = calculateLine(structure, { periodDays: 30, payableDays: 27 }, []);
    expect(line.gross).toBe(40500);
    expect(line.deductions[0].amount).toBe(500); // not prorated
    expect(line.net).toBe(40000);
  });

  it('payable days are clamped to the period', () => {
    expect(calculateLine(structure, { periodDays: 30, payableDays: 45 }, []).gross).toBe(45000);
    expect(calculateLine(structure, { periodDays: 30, payableDays: -3 }, []).gross).toBe(0);
    expect(() => calculateLine(structure, { periodDays: 0, payableDays: 0 }, [])).toThrow();
  });

  it('adjustments and reimbursements: reimbursements are paid but not part of gross', () => {
    const line = calculateLine(structure, { periodDays: 30, payableDays: 30, reimbursements: 1200, adjustments: [{ amount: 2000, reason: 'Bonus' }, { amount: -300, reason: 'Advance' }] }, []);
    expect(line.gross).toBe(47000);
    expect(line.deductions.find((d) => d.code === 'RECOVERY')!.amount).toBe(300);
    expect(line.net).toBe(47000 + 1200 - 500 - 300);
  });

  it('caps statutory amounts', () => {
    const line = calculateLine(structure, { periodDays: 30, payableDays: 30 }, [{ code: 'ESI', kind: 'deduction', basis: 'gross', percent: 0.75, cap: 100 }]);
    expect(line.deductions.find((d) => d.code === 'ESI')!.amount).toBe(100);
  });

  it('LOP days from attendance', () => {
    expect(lopDays({ absentDays: 2, unpaidLeaveDays: 1, halfDays: 3 })).toBe(4.5);
  });
});
