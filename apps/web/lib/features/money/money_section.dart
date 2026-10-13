import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../platform/bridge.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_kit.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';

class MoneySection extends StatelessWidget {
  const MoneySection({super.key, this.tab});
  final String? tab;

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      basePath: '/money',
      tabId: tab,
      title: 'Money',
      boldWord: 'matters',
      subtitle: 'Expenses, reimbursements, payroll and payslips.',
      tabs: [
        SectionTab('expenses', 'Expenses', Icons.receipt_long_rounded, (_) => const ExpensesTab(), visible: (me) => me.feature('expenses') && me.can('expenses', 'view')),
        SectionTab('payslips', 'Payslips', Icons.request_quote_rounded, (_) => const PayslipsTab(), visible: (me) => me.feature('payroll') && me.can('payslips', 'view') && me.employeeId != null),
        SectionTab('payroll', 'Payroll', Icons.payments_rounded, (_) => const PayrollTab(), visible: (me) => me.feature('payroll') && me.can('payroll', 'view', 'organization')),
        SectionTab('salary', 'Salary', Icons.savings_rounded, (_) => const SalaryTab(), visible: (me) => me.feature('payroll') && me.can('salary', 'view', 'team')),
        SectionTab('reimbursements', 'Reimbursements', Icons.account_balance_rounded, (_) => const ReimbursementsTab(), visible: (me) => me.feature('expenses') && me.can('expenses', 'manage', 'organization')),
      ],
    );
  }
}

// ======================================================================= expenses

class ExpensesTab extends StatefulWidget {
  const ExpensesTab({super.key});

  @override
  State<ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<ExpensesTab> {
  String _status = '';
  bool _mine = true;
  int _rev = 0;

  Future<void> _new() async {
    final r = await showFormSheet<Json>(
      context,
      title: 'New expense',
      subtitle: 'Policy limits are checked before it is sent.',
      initial: {'expenseDate': Fmt.day(DateTime.now()), 'submit': true},
      fields: const [
        FieldSpec('categoryId', 'Category', kind: FieldKind.asyncSelect, loadOptions: Lookups.expenseCategories, required: true),
        FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true, min: 0.01),
        FieldSpec('expenseDate', 'Date', kind: FieldKind.date, required: true),
        FieldSpec('merchant', 'Merchant'),
        FieldSpec('description', 'What was it for?', kind: FieldKind.multiline),
        FieldSpec('receiptFileId', 'Receipt', kind: FieldKind.file, filePurpose: 'receipt', fileAccept: 'image/*,application/pdf', fileCapture: 'environment', helper: 'Photo or PDF. Some categories need one above a limit.'),
        FieldSpec('submit', 'Send for approval now', kind: FieldKind.toggle, description: 'Turn off to keep it as a draft.'),
      ],
      submitLabel: 'Save',
      successMessage: 'Expense saved.',
      submit: (v, key) async => jsonMap(await context.api.post('/expenses', body: {...v, 'submit': v['submit'] == true}, idempotencyKey: key)),
    );
    if (r != null) setState(() => _rev++);
  }

  Future<void> _act(Json e, String action) async {
    try {
      await context.api.post('/expenses/${e['id']}/$action');
      if (mounted) {
        NToast.of(context).show(action == 'submit' ? 'Sent for approval.' : 'Expense cancelled.');
        setState(() => _rev++);
      }
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    final now = DateTime.now();
    final from = Fmt.day(DateTime(now.year, now.month - 5, 1));
    final to = Fmt.day(now);
    final canTeam = me.can('expenses', 'view', 'team');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AsyncView<Json>(
        reloadKey: '$_mine$_rev',
        compact: true,
        skeletonRows: 2,
        load: () async => jsonMap(await context.api.get('/expenses/summary', query: {'from': from, 'to': to, 'mine': _mine})),
        builder: (context, s, _) {
          final cats = jsonList(s['byCategory']);
          final months = jsonList(s['byMonth']);
          final pending = jsonMap(s['pendingReimbursement']);
          return CardGrid(minTileWidth: 320, children: [
            InfoCard(
              title: 'By category, last 6 months',
              child: NDonut(semanticLabel: 'Expenses by category', formatter: (v) => Fmt.money(v, me.currency), data: [for (final c in cats.take(6)) NDatum('${c['name']}', c['total'] as num)]),
            ),
            InfoCard(
              title: 'By month',
              child: months.isEmpty ? const Text('No expenses yet.') : NBars(semanticLabel: 'Expenses per month', formatter: (v) => Fmt.money(v, me.currency), showValues: false, data: [for (final m in months) NDatum('${m['month']}'.substring(5), m['total'] as num)], highlightLast: true),
            ),
            InfoCard(
              title: 'Waiting to be paid',
              subtitle: 'Approved but not yet reimbursed',
              child: Text('${Fmt.money(pending['total'], me.currency)} · ${pending['count']} claims', style: NTokens.of(context).text.title(size: 20)),
            ),
          ]);
        },
      ),
      const SizedBox(height: 14),
      Toolbar(children: [
        if (canTeam) NFilterChips<bool>(value: _mine, onChanged: (v) => setState(() => _mine = v), options: const [NOption(true, 'Mine'), NOption(false, 'Everyone I manage')]),
        NFilterChips<String>(
          value: _status,
          onChanged: (v) => setState(() => _status = v),
          options: const [NOption('', 'All'), NOption('draft', 'Draft'), NOption('submitted', 'Submitted'), NOption('approved', 'Approved'), NOption('rejected', 'Rejected')],
        ),
        if (me.can('expenses', 'create')) NButton(label: 'New expense', icon: Icons.add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _new),
      ]),
      PagedList(
        path: '/expenses',
        query: {'status': _status, if (_mine || !canTeam) 'mine': true},
        reloadKey: '$_status|$_mine|$_rev',
        emptyTitle: 'No expenses',
        emptyIcon: Icons.receipt_long_rounded,
        itemBuilder: (_, __, ___) => const SizedBox.shrink(),
        wrap: (context, items, _) => NDataTable(
          columns: [
            if (!_mine) const NColumn('Person', flex: 2),
            const NColumn('Date'),
            const NColumn('Category', flex: 2),
            const NColumn('Merchant', flex: 2, hideOnTablet: true),
            const NColumn('Amount', numeric: true),
            const NColumn('Approval'),
            const NColumn('Payment', hideOnTablet: true),
            const NColumn('', flex: 1),
          ],
          rows: [
            for (final e in items)
              [
                if (!_mine) Text('${e['employeeName'] ?? ''}'),
                Text(Fmt.shortDate(e['expenseDate'])),
                Text('${e['categoryName'] ?? ''}${(e['policyWarnings'] as List? ?? const []).isNotEmpty ? ' ⚠' : ''}'),
                Text('${e['merchant'] ?? '—'}'),
                Text(Fmt.money(e['amount'], '${e['currency'] ?? me.currency}')),
                StatusChip('${e['status']}'),
                StatusChip('${e['reimbursementStatus']}', label: e['reimbursementStatus'] == 'not_applicable' ? '—' : null),
                PopupMenuButton<String>(
                  tooltip: 'Actions',
                  onSelected: (a) => a == 'receipt' ? _receipt(e) : _act(e, a),
                  itemBuilder: (_) => [
                    if (e['status'] == 'draft' && e['employeeId'] == me.employeeId) const PopupMenuItem(value: 'submit', child: Text('Send for approval')),
                    if ((e['status'] == 'draft' || e['status'] == 'submitted') && e['employeeId'] == me.employeeId) const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                    if (e['receiptFileId'] != null) const PopupMenuItem(value: 'receipt', child: Text('Download receipt')),
                  ],
                ),
              ],
          ],
        ),
      ),
    ]);
  }

  Future<void> _receipt(Json e) async {
    try {
      final f = await context.api.download('/files/${e['receiptFileId']}/content');
      bridge.downloadBytes(f.bytes, f.fileName, f.mimeType);
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }
}

class ReimbursementsTab extends StatefulWidget {
  const ReimbursementsTab({super.key});

  @override
  State<ReimbursementsTab> createState() => _ReimbursementsTabState();
}

class _ReimbursementsTabState extends State<ReimbursementsTab> {
  int _rev = 0;
  final Set<String> _selected = {};

  Future<void> _schedule() async {
    try {
      await context.api.post('/expenses/reimbursements', body: {'expenseIds': _selected.toList()});
      if (mounted) {
        NToast.of(context).show('Reimbursement scheduled.');
        setState(() {
          _selected.clear();
          _rev++;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const NBanner(message: 'Approval and payment are separate: approved claims are paid only when you schedule and confirm a reimbursement.', tone: NBannerTone.info),
      const SizedBox(height: 12),
      InfoCard(
        title: 'Approved, waiting for payment',
        trailing: NButton(label: 'Schedule ${_selected.length}', compact: true, onPressed: _selected.isEmpty ? null : _schedule),
        child: PagedList(
          path: '/expenses',
          query: const {'status': 'approved', 'reimbursementStatus': 'pending'},
          reloadKey: _rev,
          limit: 100,
          emptyTitle: 'Nothing waiting',
          itemBuilder: (context, e, _) => NCheckRow(
            label: '${e['employeeName'] ?? ''} · ${Fmt.money(e['amount'], me.currency)}',
            description: '${e['categoryName'] ?? ''} · ${Fmt.date(e['expenseDate'])}${e['merchant'] != null ? ' · ${e['merchant']}' : ''}',
            value: _selected.contains(e['id']),
            onChanged: (v) => setState(() => v ? _selected.add('${e['id']}') : _selected.remove('${e['id']}')),
          ),
        ),
      ),
      const SizedBox(height: 14),
      InfoCard(
        title: 'Reimbursements',
        child: AsyncView<List<Json>>(
          reloadKey: _rev,
          load: () async => jsonList(await context.api.get('/expenses/reimbursements')),
          builder: (context, items, reload) => items.isEmpty
              ? const NEmptyState(title: 'No reimbursements yet', compact: true)
              : NDataTable(
                  columns: const [NColumn('Person', flex: 2), NColumn('Amount', numeric: true), NColumn('Claims', numeric: true), NColumn('Reference', flex: 2, hideOnTablet: true), NColumn('Status'), NColumn('', flex: 1)],
                  rows: [
                    for (final r in items)
                      [
                        Text('${r['employeeName'] ?? r['employeeId']}'),
                        Text(Fmt.money(r['amount'], me.currency)),
                        Text('${(r['expenseIds'] as List? ?? const []).length}'),
                        Text('${r['paymentReference'] ?? '—'}'),
                        StatusChip('${r['status']}'),
                        r['status'] == 'scheduled'
                            ? TextButton(
                                onPressed: () async {
                                  final c = await showNConfirm(context, title: 'Mark as paid', message: 'Record the bank or UPI reference of the payment.', confirmLabel: 'Mark paid', reasonLabel: 'Payment reference');
                                  if (!c.confirmed || c.reason == null || !context.mounted) return;
                                  try {
                                    await context.api.post('/expenses/reimbursements/${r['id']}/paid', body: {'paymentReference': c.reason});
                                    reload();
                                  } catch (e) {
                                    if (context.mounted) showError(context, e);
                                  }
                                },
                                child: const Text('Mark paid'),
                              )
                            : const SizedBox.shrink(),
                      ],
                  ],
                ),
        ),
      ),
    ]);
  }
}

// ======================================================================= payslips

class PayslipsTab extends StatelessWidget {
  const PayslipsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return AsyncView<List<Json>>(
      load: () async => jsonList(await context.api.get('/payroll/payslips')),
      builder: (context, items, reload) => items.isEmpty
          ? const NEmptyState(title: 'No payslips yet', message: 'Payslips appear here after payroll is finalized.', icon: Icons.request_quote_rounded)
          : InfoCard(
              title: 'My payslips',
              child: Column(children: [
                for (final p in items)
                  NListRow(
                    leading: const Icon(Icons.picture_as_pdf_rounded),
                    title: '${p['period']}',
                    subtitle: 'Net ${Fmt.money(p['net'], me.currency)} · published ${Fmt.date(p['publishedAt'])}',
                    trailing: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (p['viewedAt'] == null) const StatusChip('new', label: 'New'),
                      IconButton(
                        tooltip: 'Download PDF',
                        icon: const Icon(Icons.download_rounded),
                        onPressed: () async {
                          try {
                            final api = context.api;
                            final f = await api.download('/files/${p['fileId']}/content');
                            bridge.downloadBytes(f.bytes, f.fileName == 'download' ? 'payslip-${p['period']}.pdf' : f.fileName, 'application/pdf');
                            await api.post('/payroll/payslips/${p['id']}/viewed');
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      ),
                    ]),
                  ),
              ]),
            ),
    );
  }
}

// ======================================================================= payroll

class PayrollTab extends StatefulWidget {
  const PayrollTab({super.key});

  @override
  State<PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends State<PayrollTab> {
  final _rev = 0;

  Future<void> _open() async {
    final now = DateTime.now();
    final r = await showFormSheet<Json>(
      context,
      title: 'Open payroll',
      initial: {'period': '${now.year}-${now.month.toString().padLeft(2, '0')}'},
      fields: const [FieldSpec('period', 'Month', required: true, hint: 'YYYY-MM')],
      submitLabel: 'Open',
      successMessage: 'Payroll opened.',
      submit: (v, key) async => jsonMap(await context.api.post('/payroll/runs', body: v, idempotencyKey: key)),
    );
    if (r != null && mounted) context.go('/money/payroll/${r['id']}');
  }

  @override
  Widget build(BuildContext context) {
    final me = context.me;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [
        if (me.can('payroll', 'manage', 'organization')) NButton(label: 'Open payroll', icon: Icons.add_rounded, compact: true, variant: NButtonVariant.accent, onPressed: _open),
        if (me.can('payroll', 'configure', 'organization')) NButton(label: 'Statutory rules', icon: Icons.rule_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: () => _rules(context)),
      ]),
      AsyncView<List<Json>>(
        reloadKey: _rev,
        load: () async => jsonList(await context.api.get('/payroll/runs')),
        builder: (context, runs, _) => runs.isEmpty
            ? const NEmptyState(title: 'No payroll runs yet', message: 'Open the first month when salary structures are approved.', icon: Icons.payments_rounded)
            : NDataTable(
                columns: const [NColumn('Period', flex: 2), NColumn('People', numeric: true), NColumn('Gross', numeric: true, hideOnTablet: true), NColumn('Net', numeric: true), NColumn('Anomalies', numeric: true), NColumn('Status')],
                onTapRow: (i) => context.go('/money/payroll/${runs[i]['id']}'),
                rows: [
                  for (final r in runs)
                    [
                      Text('${r['label'] ?? r['periodStart']}'),
                      Text('${jsonMap(r['totals'])['employees'] ?? '—'}'),
                      Text(jsonMap(r['totals'])['gross'] == null ? '—' : Fmt.money(jsonMap(r['totals'])['gross'], me.currency)),
                      Text(jsonMap(r['totals'])['net'] == null ? '—' : Fmt.money(jsonMap(r['totals'])['net'], me.currency)),
                      Text('${r['anomalies'] ?? 0}'),
                      StatusChip('${r['status']}'),
                    ],
                ],
              ),
      ),
    ]);
  }

  Future<void> _rules(BuildContext context) async {
    await showNSheet<void>(context, title: 'Statutory rules', subtitle: 'Rules stay inactive until validated and switched on.', builder: (ctx) => ApiScope(api: context.api, child: const _RulesSheet()));
  }
}

class _RulesSheet extends StatefulWidget {
  const _RulesSheet();

  @override
  State<_RulesSheet> createState() => _RulesSheetState();
}

class _RulesSheetState extends State<_RulesSheet> {
  int _rev = 0;

  Future<void> _edit([Json? r]) async {
    final res = await showFormSheet<Json>(
      context,
      title: r == null ? 'New rule' : 'Edit ${r['code']}',
      initial: r ?? const {'kind': 'deduction', 'basis': 'component'},
      fields: [
        const FieldSpec('code', 'Code', required: true, hint: 'PF_EE'),
        const FieldSpec('name', 'Name'),
        const FieldSpec('kind', 'Kind', kind: FieldKind.select, options: [NOption('deduction', 'Employee deduction'), NOption('employer_contribution', 'Employer contribution')]),
        const FieldSpec('basis', 'Based on', kind: FieldKind.select, options: [NOption('component', 'A salary component'), NOption('gross', 'Gross pay'), NOption('slab', 'Slabs (e.g. professional tax)')]),
        FieldSpec('basisComponent', 'Component code', hint: 'BASIC', visibleWhen: (v) => v['basis'] == 'component'),
        FieldSpec('percent', 'Percent', kind: FieldKind.number, min: 0, max: 100, visibleWhen: (v) => v['basis'] != 'slab'),
        FieldSpec('wageCeiling', 'Wage ceiling', kind: FieldKind.money, visibleWhen: (v) => v['basis'] != 'slab'),
        FieldSpec('cap', 'Maximum amount', kind: FieldKind.money, visibleWhen: (v) => v['basis'] != 'slab'),
        FieldSpec('slabsText', 'Slabs', hint: '15000:0, 20000:150, 999999999:200', helper: 'up-to-amount:deduction pairs, comma-separated', visibleWhen: (v) => v['basis'] == 'slab'),
      ],
      successMessage: 'Rule saved (inactive until validated).',
      submit: (v, key) async {
        final body = <String, dynamic>{...v}..remove('slabsText');
        if (v['slabsText'] != null) {
          body['slabs'] = [
            for (final p in '${v['slabsText']}'.split(','))
              if (p.contains(':')) {'upTo': num.tryParse(p.split(':')[0].trim()) ?? 0, 'amount': num.tryParse(p.split(':')[1].trim()) ?? 0},
          ];
        }
        body['active'] = r?['active'] == true;
        return jsonMap(await ApiScope.of(context).put('/payroll/rules', body: body, idempotencyKey: key));
      },
    );
    if (res != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<Json>>(
      reloadKey: _rev,
      load: () async => jsonList(await ApiScope.of(context).get('/payroll/rules')),
      builder: (context, items, reload) => NSheetBody(
        actions: [NButton(label: 'New rule', icon: Icons.add_rounded, compact: true, onPressed: () => _edit())],
        children: [
          if (items.isEmpty) const NEmptyState(title: 'No statutory rules', compact: true),
          for (final r in items)
            NListRow(
              title: '${r['code']} · ${r['name'] ?? ''}',
              subtitle: '${Fmt.label(r['kind'])} · ${Fmt.label(r['basis'])}${r['percent'] != null ? ' · ${r['percent']}%' : ''}${r['validatedAt'] != null ? ' · validated ${Fmt.date(r['validatedAt'])}' : ' · not validated'}',
              trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                StatusChip(r['active'] == true ? 'active' : 'draft', label: r['active'] == true ? 'Active' : 'Inactive'),
                IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_rounded, size: 18), onPressed: () => _edit(r)),
                IconButton(
                  tooltip: 'Validate and activate',
                  icon: const Icon(Icons.verified_rounded, size: 18),
                  onPressed: () async {
                    try {
                      await ApiScope.of(context).post('/payroll/rules/${r['code']}/validate');
                      reload();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

class PayrollRunPage extends StatefulWidget {
  const PayrollRunPage({super.key, required this.id});
  final String id;

  @override
  State<PayrollRunPage> createState() => _PayrollRunPageState();
}

class _PayrollRunPageState extends State<PayrollRunPage> {
  final _view = GlobalKey<AsyncViewState<Json>>();
  bool _anomaliesOnly = false;
  bool _busy = false;
  int _rev = 0;

  Future<void> _step(String path, String done, {String? confirm}) async {
    final api = context.api;
    if (confirm != null) {
      final c = await showNConfirm(context, title: 'Are you sure?', message: confirm, confirmLabel: 'Continue', destructive: path.contains('finalize'));
      if (!c.confirmed) return;
    }
    setState(() => _busy = true);
    try {
      await api.post('/payroll/runs/${widget.id}/$path');
      if (mounted) {
        NToast.of(context).show(done);
        _view.currentState?.reload();
        setState(() => _rev++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bankFile() async {
    try {
      final f = await context.api.download('/payroll/runs/${widget.id}/bank-file');
      bridge.downloadBytes(f.bytes, f.fileName == 'download' ? 'bank-file.csv' : f.fileName, 'text/csv');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _adjust(Json line) async {
    final r = await showFormSheet<Json>(
      context,
      title: 'Adjustment for ${line['employeeName']}',
      subtitle: 'Finalized payroll is never edited. Adjustments apply to the next run.',
      fields: const [
        FieldSpec('kind', 'Kind', kind: FieldKind.select, required: true, options: [NOption('adjustment', 'Extra payment'), NOption('reversal', 'Recovery')]),
        FieldSpec('amount', 'Amount', kind: FieldKind.money, required: true, min: 1),
        FieldSpec('reason', 'Reason', kind: FieldKind.multiline, required: true),
      ],
      successMessage: 'Adjustment recorded.',
      submit: (v, key) async => jsonMap(await context.api.post('/payroll/adjustments', idempotencyKey: key, body: {...v, 'runId': widget.id, 'employeeId': line['employeeId']})),
    );
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final manage = me.can('payroll', 'manage', 'organization');
    return PageFrame(
      child: AsyncView<Json>(
        key: _view,
        load: () async => jsonMap(await context.api.get('/payroll/runs/${widget.id}')),
        builder: (context, run, _) {
          final totals = jsonMap(run['totals']);
          final prev = run['previous'] == null ? null : jsonMap(run['previous']);
          final status = '${run['status']}';
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: () => context.go('/money/payroll'), icon: const Icon(Icons.arrow_back_rounded, size: 18), label: const Text('Payroll'))),
            NSectionHeader(title: 'Payroll', boldWord: '${run['label'] ?? run['periodStart']}', subtitle: '${Fmt.date(run['periodStart'])} – ${Fmt.date(run['periodEnd'])}', trailing: [StatusChip(status)]),
            Wrap(spacing: 24, runSpacing: 12, children: [
              NKpi(label: 'People', value: totals['employees'] as num?, size: 34),
              NKpi(label: 'Gross', value: totals['gross'] as num?, size: 34, formatter: (v) => Fmt.money(v, me.currency)),
              NKpi(label: 'Deductions', value: totals['deductions'] as num?, size: 34, formatter: (v) => Fmt.money(v, me.currency)),
              NKpi(label: 'Net pay', value: totals['net'] as num?, size: 34, formatter: (v) => Fmt.money(v, me.currency)),
              NKpi(label: 'Employer cost', value: totals['employerCost'] as num?, size: 34, formatter: (v) => Fmt.money(v, me.currency)),
              NKpi(label: 'Anomalies', value: run['anomalies'] as num?, size: 34),
            ]),
            if (prev != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Previous: ${prev['label']} · net ${Fmt.money(jsonMap(prev['totals'])['net'], me.currency)}', style: t.text.caption())),
            const SizedBox(height: 14),
            if (manage)
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (status == 'open' || status == 'calculated' || status == 'in_review')
                  NButton(label: status == 'open' ? 'Calculate' : 'Recalculate', icon: Icons.calculate_rounded, compact: true, busy: _busy, onPressed: () => _step('calculate', 'Calculated from attendance, leave and salary structures.')),
                if (status == 'calculated') NButton(label: 'Send for approval', icon: Icons.send_rounded, compact: true, variant: NButtonVariant.accent, busy: _busy, onPressed: () => _step('submit', 'Sent for approval.', confirm: 'Reviewer and final approver will be asked to approve. High-severity anomalies block submission.')),
                if (status == 'approved')
                  NButton(label: 'Finalize and lock', icon: Icons.lock_rounded, compact: true, variant: NButtonVariant.accent, busy: _busy, onPressed: () => _step('finalize', 'Finalized. Payslips are being generated.', confirm: 'Finalizing locks this payroll and publishes payslips. Later changes become adjustments in the next run. You will confirm with a code.')),
                if ((status == 'finalized' || status == 'paid') && me.can('payroll', 'export', 'organization')) NButton(label: 'Bank file', icon: Icons.download_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: _bankFile),
              ]),
            const SizedBox(height: 14),
            InfoCard(
              title: 'Lines',
              trailing: SizedBox(width: 190, child: NCheckRow(label: 'Anomalies only', value: _anomaliesOnly, onChanged: (v) => setState(() => _anomaliesOnly = v))),
              child: AsyncView<List<Json>>(
                reloadKey: '$_anomaliesOnly|$_rev|$status',
                load: () async => jsonList(await context.api.get('/payroll/runs/${widget.id}/lines', query: {if (_anomaliesOnly) 'anomalies': true})),
                builder: (context, lines, _) => lines.isEmpty
                    ? NEmptyState(title: status == 'open' ? 'Not calculated yet' : 'No lines', compact: true)
                    : NDataTable(
                        columns: const [NColumn('Employee', flex: 3), NColumn('Payable days', numeric: true, hideOnTablet: true), NColumn('Gross', numeric: true), NColumn('Deductions', numeric: true, hideOnTablet: true), NColumn('Net', numeric: true), NColumn('Change', numeric: true, hideOnTablet: true), NColumn('Payment'), NColumn('', flex: 1)],
                        onTapRow: (i) => _lineDetail(lines[i]),
                        rows: [
                          for (final l in lines)
                            [
                              Text('${l['employeeName']}${jsonList(l['anomalies']).isNotEmpty ? '  ⚠ ${jsonList(l['anomalies']).length}' : ''}'),
                              Text('${jsonMap(l['inputs'])['payableDays'] ?? '—'}'),
                              Text(Fmt.money(l['gross'], me.currency)),
                              Text(Fmt.money(l['totalDeductions'], me.currency)),
                              Text(Fmt.money(l['net'], me.currency)),
                              Text(l['diff'] == null ? '—' : '${(l['diff'] as num) >= 0 ? '+' : ''}${Fmt.money(l['diff'], me.currency)}'),
                              StatusChip('${l['paymentStatus']}'),
                              (manage && (status == 'finalized' || status == 'paid'))
                                  ? IconButton(tooltip: 'Adjustment for next run', icon: const Icon(Icons.exposure_rounded, size: 18), onPressed: () => _adjust(l))
                                  : const SizedBox.shrink(),
                            ],
                        ],
                      ),
              ),
            ),
          ]);
        },
      ),
    );
  }

  void _lineDetail(Json l) {
    final me = context.me;
    showNSheet<void>(
      context,
      title: '${l['employeeName']}',
      subtitle: 'Payroll line',
      builder: (ctx) {
        final t = NTokens.of(ctx);
        final inputs = jsonMap(l['inputs']);
        return ListView(padding: const EdgeInsets.all(20), children: [
          for (final a in jsonList(l['anomalies'])) Padding(padding: const EdgeInsets.only(bottom: 8), child: NBanner(tone: a['severity'] == 'high' ? NBannerTone.danger : NBannerTone.warning, message: '${a['message']}')),
          const NCardTitle('Inputs'),
          for (final e in inputs.entries) NInfoRow(label: Fmt.label(e.key), value: '${e.value}'),
          const SizedBox(height: 10),
          const NCardTitle('Earnings'),
          for (final e in jsonList(l['earnings'])) NInfoRow(label: '${e['name']}', value: Fmt.money(e['amount'], me.currency)),
          const SizedBox(height: 10),
          const NCardTitle('Deductions'),
          for (final e in jsonList(l['deductions'])) NInfoRow(label: '${e['name']}', value: Fmt.money(e['amount'], me.currency)),
          if (jsonList(l['employerContributions']).isNotEmpty) ...[
            const SizedBox(height: 10),
            const NCardTitle('Employer contributions'),
            for (final e in jsonList(l['employerContributions'])) NInfoRow(label: '${e['name']}', value: Fmt.money(e['amount'], me.currency)),
          ],
          const Divider(),
          NInfoRow(label: 'Net pay', value: Fmt.money(l['net'], me.currency)),
          if (l['paymentReference'] != null) NInfoRow(label: 'Payment reference', value: '${l['paymentReference']}'),
          Text('Calculation version ${l['calculationVersion'] ?? '—'}', style: t.text.caption()),
        ]);
      },
    );
  }
}

// ======================================================================= salary

class SalaryTab extends StatefulWidget {
  const SalaryTab({super.key});

  @override
  State<SalaryTab> createState() => _SalaryTabState();
}

class _SalaryTabState extends State<SalaryTab> {
  String? _employee;
  int _rev = 0;

  Future<void> _propose(List<Json> versions) async {
    final current = versions.where((v) => v['status'] == 'approved').toList();
    final comps = current.isEmpty ? <Json>[] : jsonList(current.first['components']);
    final text = comps.isEmpty
        ? 'BASIC:Basic:earning:fixed:25000\nHRA:House rent:earning:percent_of:40:BASIC\nSPECIAL:Special allowance:earning:fixed:10000'
        : comps.map((c) => [c['code'], c['name'], c['kind'], c['calc'], c['calc'] == 'percent_of' ? c['percent'] : c['amount'], if (c['of'] != null) c['of']].join(':')).join('\n');
    final r = await showFormSheet<Json>(
      context,
      title: 'Propose salary structure',
      subtitle: 'Goes for approval; payroll uses only approved versions.',
      initial: {'effectiveFrom': Fmt.day(DateTime.now()), 'componentsText': text},
      fields: const [
        FieldSpec('effectiveFrom', 'Effective from', kind: FieldKind.date, required: true),
        FieldSpec('componentsText', 'Components (monthly)', kind: FieldKind.multiline, required: true, helper: 'One per line: CODE:Name:earning|deduction:fixed|percent_of:amount-or-percent[:OF_CODE]'),
        FieldSpec('note', 'Note'),
      ],
      submitLabel: 'Send for approval',
      successMessage: 'Salary proposal sent.',
      submit: (v, key) async {
        final components = <Json>[];
        for (final line in '${v['componentsText']}'.split('\n')) {
          final p = line.split(':').map((s) => s.trim()).toList();
          if (p.length < 5) continue;
          final calc = p[3];
          final n = num.tryParse(p[4]) ?? 0;
          components.add({'code': p[0], 'name': p[1], 'kind': p[2], 'calc': calc, if (calc == 'percent_of') 'percent': n else 'amount': n, if (p.length > 5) 'of': p[5]});
        }
        return jsonMap(await context.api.post('/payroll/salary/$_employee', idempotencyKey: key, body: {'effectiveFrom': v['effectiveFrom'], 'components': components, if (v['note'] != null) 'note': v['note']}));
      },
    );
    if (r != null) setState(() => _rev++);
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 360,
        child: AsyncView<List<NOption<String>>>(
          load: () => Lookups.employees(context.api),
          compact: true,
          skeletonRows: 1,
          builder: (context, opts, _) => NSelect<String>(label: 'Employee', value: _employee, options: opts, onChanged: (v) => setState(() => _employee = v)),
        ),
      ),
      const SizedBox(height: 14),
      if (_employee == null)
        const NEmptyState(title: 'Choose an employee', message: 'Salary is visible only to people with the salary permission. Every view is audited.', icon: Icons.lock_outline_rounded)
      else
        AsyncView<List<Json>>(
          reloadKey: '$_employee|$_rev',
          load: () async => jsonList(await context.api.get('/payroll/salary/$_employee')),
          builder: (context, versions, _) => InfoCard(
            title: 'Salary versions',
            trailing: me.can('salary', 'edit') ? NButton(label: 'Propose change', compact: true, onPressed: () => _propose(versions)) : null,
            child: versions.isEmpty
                ? const NEmptyState(title: 'No salary structure yet', compact: true)
                : Column(children: [
                    for (final v in versions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text('Version ${v['version']} · from ${Fmt.date(v['effectiveFrom'])}', style: t.text.body(weight: FontWeight.w600))),
                            StatusChip('${v['status']}'),
                          ]),
                          for (final c in jsonList(v['components']))
                            NInfoRow(label: '${c['name']} (${c['code']})', value: c['calc'] == 'percent_of' ? '${c['percent']}% of ${c['of']}' : Fmt.money(c['amount'], me.currency)),
                          if (v['monthlyGross'] != null) NInfoRow(label: 'Monthly gross', value: Fmt.money(v['monthlyGross'], me.currency)),
                        ]),
                      ),
                  ]),
          ),
        ),
    ]);
  }
}
