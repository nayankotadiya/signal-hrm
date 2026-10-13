import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/form_kit.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';

const requestTypeLabels = {
  'leave': 'Leave',
  'expense': 'Expense',
  'travel': 'Travel',
  'payroll': 'Payroll',
  'attendance_correction': 'Attendance correction',
  'shift_change': 'Shift change',
  'onboarding': 'Onboarding',
  'offboarding': 'Offboarding',
  'salary_change': 'Salary change',
};

/// Approval Center: everything waiting for the signed-in person, plus what they submitted and decided.
class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({super.key});

  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> {
  String _tab = 'mine';
  String _type = '';
  int _rev = 0;
  bool _openedFromLink = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    String? open;
    try {
      open = GoRouterState.of(context).uri.queryParameters['open'];
    } catch (_) {}
    if (open != null && !_openedFromLink) {
      _openedFromLink = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => openApproval(context, open!, onChanged: () => setState(() => _rev++)));
    }
  }

  Future<void> _decide(String id, String decision, String key, {String? comment}) async {
    await context.api.post('/approvals/$id/decision', idempotencyKey: key, body: {'decision': decision, if (comment != null) 'comment': comment});
  }

  Future<void> _confirm(NActionItem item, NDecision d) async {
    final reject = d == NDecision.decline;
    final r = await showNConfirm(
      context,
      title: reject ? 'Decline ${item.title}?' : 'Approve ${item.title}?',
      message: reject ? 'The requester sees your comment.' : 'This approval is final for your stage and is recorded in the history.',
      confirmLabel: reject ? 'Decline' : 'Approve',
      destructive: reject,
      reasonLabel: 'Comment',
      reasonRequired: reject,
    );
    if (!r.confirmed || !mounted) return;
    try {
      await _decide(item.id, reject ? 'reject' : 'approve', newIdempotencyKey(), comment: r.reason);
      if (mounted) {
        NToast.of(context).show(reject ? 'Declined.' : 'Approved.');
        setState(() => _rev++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NSectionHeader(
          title: 'Approval',
          boldWord: 'center',
          subtitle: 'Every decision is recorded with who, when and why.',
          trailing: [NButton(label: 'Delegate', icon: Icons.switch_account_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: () => _delegations(context))],
        ),
        Toolbar(children: [
          NFilterChips<String>(
            value: _tab,
            onChanged: (v) => setState(() => _tab = v),
            options: [
              const NOption('mine', 'Waiting for me'),
              const NOption('submitted', 'My requests'),
              const NOption('history', 'I decided'),
              if (me.can('approvals', 'view', 'team')) const NOption('all', 'All'),
              if (me.can('approvals', 'view', 'team')) const NOption('escalations', 'Escalated'),
            ],
          ),
          SizedBox(
            width: 220,
            child: NSelect<String>(label: 'Type', value: _type, options: [const NOption('', 'All types'), for (final e in requestTypeLabels.entries) NOption(e.key, e.value)], onChanged: (v) => setState(() => _type = v ?? '')),
          ),
        ]),
        AsyncView<Json>(
          reloadKey: '$_tab|$_type|$_rev',
          load: () async => jsonMap(await context.api.get('/approvals', query: {'tab': _tab, 'type': _type, 'limit': 100})),
          builder: (context, d, reload) {
            final items = jsonList(d['items']);
            if (_tab == 'mine') {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                NDarkActionCard.approve(
                  title: 'Waiting for you · ${items.length}',
                  items: [
                    for (final a in items)
                      NActionItem(
                        id: '${a['id']}',
                        title: '${a['title'] ?? requestTypeLabels[a['requestType']] ?? 'Request'}',
                        subtitle: [a['requestedByName'], a['summary'], if (a['amount'] != null) Fmt.money(a['amount'], me.currency)].whereType<String>().join(' · '),
                        meta: a['dueAt'] == null ? null : (Fmt.parse(a['dueAt'])!.isBefore(DateTime.now()) ? 'Overdue' : 'Due ${Fmt.relative(a['dueAt'])}'),
                      ),
                  ],
                  // Declines always ask for a comment; payroll and salary decisions are never held.
                  needsConfirmation: (item, decision) {
                    final a = items.firstWhere((x) => '${x['id']}' == item.id, orElse: () => const {});
                    return decision == NDecision.decline || a['requestType'] == 'payroll' || a['requestType'] == 'salary_change';
                  },
                  onConfirmRequired: _confirm,
                  commit: (item, decision, key) => _decide(item.id, decision == NDecision.approve ? 'approve' : 'reject', key),
                  describeError: describeError,
                ),
                const SizedBox(height: 12),
                for (final a in items)
                  NListRow(
                    dense: true,
                    leading: Icon(Icons.open_in_new_rounded, size: 16, color: t.muted),
                    title: 'Details: ${a['title'] ?? requestTypeLabels[a['requestType']]}',
                    onTap: () => openApproval(context, '${a['id']}', onChanged: reload),
                  ),
              ]);
            }
            if (items.isEmpty) return const NEmptyState(title: 'Nothing here', icon: Icons.fact_check_rounded);
            return NDataTable(
              columns: const [NColumn('Request', flex: 3), NColumn('Type', flex: 2), NColumn('Requested by', flex: 2, hideOnTablet: true), NColumn('When'), NColumn('Status')],
              onTapRow: (i) => openApproval(context, '${items[i]['id']}', onChanged: reload),
              rows: [
                for (final a in items)
                  [
                    Text('${a['title'] ?? ''}${a['escalated'] == true ? ' ⚑' : ''}', maxLines: 2),
                    Text(requestTypeLabels[a['requestType']] ?? Fmt.label(a['requestType'])),
                    Text('${a['requestedByName'] ?? ''}'),
                    Text(Fmt.relative(a['createdAt'])),
                    StatusChip('${a['status']}'),
                  ],
              ],
            );
          },
        ),
      ]),
    );
  }

  Future<void> _delegations(BuildContext context) async {
    await showNSheet<void>(context, title: 'Delegations', subtitle: 'Someone else approves on your behalf for a period. Their decisions show both names.', builder: (ctx) => ApiScope(api: context.api, child: const _Delegations()));
  }
}

class _Delegations extends StatefulWidget {
  const _Delegations();

  @override
  State<_Delegations> createState() => _DelegationsState();
}

class _DelegationsState extends State<_Delegations> {
  int _rev = 0;

  @override
  Widget build(BuildContext context) {
    final api = ApiScope.of(context);
    return AsyncView<List<Json>>(
      reloadKey: _rev,
      load: () async => jsonList(await api.get('/approvals/delegations')),
      builder: (context, items, reload) => NSheetBody(
        actions: [
          NButton(
            label: 'New delegation',
            icon: Icons.add_rounded,
            compact: true,
            onPressed: () async {
              final r = await showFormSheet<Json>(
                context,
                title: 'Delegate approvals',
                fields: [
                  const FieldSpec('toUserId', 'To', kind: FieldKind.asyncSelect, loadOptions: Lookups.users, required: true),
                  const FieldSpec('startsAt', 'From', kind: FieldKind.date, required: true),
                  const FieldSpec('endsAt', 'Until', kind: FieldKind.date, required: true),
                  FieldSpec('requestType', 'Only for', kind: FieldKind.select, options: [const NOption('', 'All request types'), for (final e in requestTypeLabels.entries) NOption(e.key, e.value)]),
                  const FieldSpec('reason', 'Reason'),
                ],
                successMessage: 'Delegation created.',
                submit: (v, key) async => jsonMap(await api.post('/approvals/delegations', idempotencyKey: key, body: {
                  'toUserId': v['toUserId'],
                  'startsAt': DateTime.parse('${v['startsAt']}T00:00:00').toUtc().toIso8601String(),
                  'endsAt': DateTime.parse('${v['endsAt']}T23:59:59').toUtc().toIso8601String(),
                  'requestTypes': [if ((v['requestType'] ?? '') != '') v['requestType']],
                  if (v['reason'] != null) 'reason': v['reason'],
                })),
              );
              if (r != null) setState(() => _rev++);
            },
          ),
        ],
        children: [
          if (items.isEmpty) const NEmptyState(title: 'No delegations', compact: true),
          for (final d in items)
            NListRow(
              title: '${d['toName'] ?? d['toUserId']}',
              subtitle: '${Fmt.date(d['startsAt'])} – ${Fmt.date(d['endsAt'])}${(d['requestTypes'] as List? ?? const []).isEmpty ? ' · all types' : ' · ${(d['requestTypes'] as List).join(', ')}'}',
              trailing: IconButton(
                tooltip: 'End delegation',
                icon: const Icon(Icons.close_rounded),
                onPressed: () async {
                  try {
                    await api.delete('/approvals/delegations/${d['id']}');
                    reload();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Approval detail: stages, people and the full decision history.
Future<void> openApproval(BuildContext context, String id, {VoidCallback? onChanged}) {
  final api = context.api;
  final currency = context.me.currency;
  return showNSheet<void>(
    context,
    title: 'Request',
    builder: (ctx) => ApiScope(
      api: api,
      child: AsyncView<Json>(
        load: () async => jsonMap(await api.get('/approvals/$id')),
        builder: (ctx, a, reload) {
          final t = NTokens.of(ctx);
          final people = jsonMap(a['people']);
          String name(Object? id) => '${people['$id'] ?? 'Someone'}';
          final stages = jsonList(a['stages']);
          Future<void> decide(String decision) async {
            final r = await showNConfirm(
              ctx,
              title: switch (decision) {
                'approve' => 'Approve',
                'reject' => 'Decline',
                _ => 'Ask for clarification',
              },
              message: decision == 'clarification' ? 'The requester is asked to add information and resubmit.' : 'Recorded in the approval history.',
              confirmLabel: Fmt.label(decision == 'reject' ? 'decline' : decision),
              reasonLabel: 'Comment',
              reasonRequired: decision != 'approve',
              destructive: decision == 'reject',
            );
            if (!r.confirmed) return;
            try {
              await api.post('/approvals/$id/decision', body: {'decision': decision, if (r.reason != null) 'comment': r.reason});
              reload();
              onChanged?.call();
            } catch (e) {
              if (ctx.mounted) showError(ctx, e);
            }
          }

          return ListView(padding: const EdgeInsets.all(20), children: [
            Text('${a['title'] ?? requestTypeLabels[a['requestType']]}', style: t.text.title(size: 20)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [StatusChip('${a['status']}'), Text(requestTypeLabels[a['requestType']] ?? '', style: t.text.caption())]),
            const SizedBox(height: 10),
            if (a['summary'] != null) Text('${a['summary']}', style: t.text.body()),
            if (a['amount'] != null) NInfoRow(label: 'Amount', value: Fmt.money(a['amount'], currency)),
            NInfoRow(label: 'Requested by', value: name(a['requestedBy'])),
            NInfoRow(label: 'Submitted', value: Fmt.dateTime(a['createdAt'])),
            if (a['decisionComment'] != null) NInfoRow(label: 'Decision note', value: '${a['decisionComment']}'),
            const SizedBox(height: 14),
            const NCardTitle('Stages'),
            for (var i = 0; i < stages.length; i++)
              NListRow(
                dense: true,
                leading: CircleAvatar(radius: 12, backgroundColor: i == a['currentStage'] && a['status'] == 'pending' ? t.accent : t.pillTrack, child: Text('${i + 1}', style: t.text.caption(color: t.ink))),
                title: '${stages[i]['name']} · ${Fmt.label(stages[i]['mode'])}',
                subtitle: (stages[i]['approverIds'] as List? ?? const []).map(name).join(', '),
                trailing: StatusChip('${stages[i]['status']}'),
              ),
            const SizedBox(height: 14),
            const NCardTitle('History'),
            NTimeline(entries: [
              for (final h in jsonList(a['history']))
                NTimelineEntry(
                  title: '${name(h['actorId'])}${h['onBehalfOf'] != null ? ' for ${name(h['onBehalfOf'])}' : ''} · ${Fmt.label(h['action'])}',
                  subtitle: h['comment'] as String?,
                  time: Fmt.dateTime(h['at'] ?? h['createdAt']),
                  color: switch (h['action']) {
                    'approved' => t.green,
                    'rejected' => t.red,
                    'escalated' => t.amber,
                    _ => t.muted,
                  },
                ),
            ]),
            if (a['canDecide'] == true) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                NButton(label: 'Approve', icon: Icons.check_rounded, variant: NButtonVariant.accent, onPressed: () => decide('approve')),
                NButton(label: 'Decline', icon: Icons.close_rounded, variant: NButtonVariant.secondary, onPressed: () => decide('reject')),
                NButton(label: 'Ask a question', icon: Icons.help_outline_rounded, variant: NButtonVariant.secondary, onPressed: () => decide('clarification')),
              ]),
            ],
            if (a['status'] == 'clarification' && a['requestedBy'] == ctx.me.userId) ...[
              const SizedBox(height: 16),
              NButton(
                label: 'Resubmit',
                icon: Icons.replay_rounded,
                onPressed: () async {
                  final r = await showNConfirm(ctx, title: 'Resubmit', message: 'Answer the question and send it back.', confirmLabel: 'Resubmit', reasonLabel: 'Your answer');
                  if (!r.confirmed) return;
                  try {
                    await api.post('/approvals/$id/resubmit', body: {if (r.reason != null) 'comment': r.reason});
                    reload();
                    onChanged?.call();
                  } catch (e) {
                    if (ctx.mounted) showError(ctx, e);
                  }
                },
              ),
            ],
          ]);
        },
      ),
    ),
  );
}
