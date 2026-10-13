import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../data/lookups.dart';
import '../../platform/bridge.dart';
import '../../shell/app_shell.dart';
import '../../widgets/async_view.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';

/// Report catalog grouped by area. Only reports the caller may run are listed by the API.
class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const NSectionHeader(title: 'Reports', boldWord: '& analytics', subtitle: 'Every report is computed from live records within your access. Export any of them as CSV.'),
        AsyncView<Json>(
          load: () async {
            final api = context.api;
            final cat = jsonList(await api.get('/reports'));
            List<Json> saved = const [];
            try {
              saved = jsonList(await api.get('/reports/saved'));
            } catch (_) {}
            return {'catalog': cat, 'saved': saved};
          },
          builder: (context, d, reload) {
            final cat = jsonList(d['catalog']);
            final saved = jsonList(d['saved']);
            final groups = <String, List<Json>>{};
            for (final r in cat) {
              groups.putIfAbsent('${r['category'] ?? 'Other'}', () => []).add(r);
            }
            if (cat.isEmpty) return const NEmptyState(title: 'No reports available to you', icon: Icons.insights_rounded);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (saved.isNotEmpty) ...[
                InfoCard(
                  title: 'Saved views',
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in saved)
                      InputChip(
                        avatar: Icon(s['pinned'] == true ? Icons.push_pin_rounded : Icons.bookmark_rounded, size: 16),
                        label: Text('${s['name']}'),
                        onPressed: () => context.go(Uri(path: '/reports/run/${s['reportKey']}', queryParameters: {for (final e in jsonMap(s['filters']).entries) if (e.value != null) e.key: '${e.value}'}).toString()),
                        onDeleted: () async {
                          try {
                            await context.api.delete('/reports/saved/${s['id']}');
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                        deleteButtonTooltipMessage: 'Delete saved view',
                      ),
                  ]),
                ),
                const SizedBox(height: 14),
              ],
              CardGrid(minTileWidth: 300, children: [
                for (final g in groups.entries)
                  InfoCard(
                    title: Fmt.label(g.key),
                    subtitle: '${g.value.length} reports',
                    child: Column(children: [
                      for (final r in g.value)
                        NListRow(dense: true, title: '${r['title']}', subtitle: r['description'] as String?, trailing: Icon(Icons.chevron_right_rounded, color: t.muted), onTap: () => context.go('/reports/run/${r['key']}')),
                    ]),
                  ),
              ]),
            ]);
          },
        ),
      ]),
    );
  }
}

class ReportRunPage extends StatefulWidget {
  const ReportRunPage({super.key, required this.reportKey});
  final String reportKey;

  @override
  State<ReportRunPage> createState() => _ReportRunPageState();
}

class _ReportRunPageState extends State<ReportRunPage> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 29));
  DateTime _to = DateTime.now();
  String? _dept;
  bool _table = false;
  bool _init = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    try {
      final q = GoRouterState.of(context).uri.queryParameters;
      if (q['from'] != null) _from = DateTime.tryParse(q['from']!) ?? _from;
      if (q['to'] != null) _to = DateTime.tryParse(q['to']!) ?? _to;
      _dept = q['departmentId'];
    } catch (_) {}
  }

  Map<String, Object?> get _query => {'from': Fmt.day(_from), 'to': Fmt.day(_to), 'departmentId': _dept};

  String _cell(Object? v, String? type) {
    final me = context.me;
    if (v == null) return '—';
    return switch (type) {
      'money' => Fmt.money(v, me.currency),
      'number' => Fmt.number(v),
      'percent' => '${Fmt.number(v)}%',
      'minutes' => Fmt.minutes(v),
      'date' => Fmt.date(v),
      _ => '$v',
    };
  }

  Future<void> _export() async {
    try {
      final f = await context.api.download('/reports/${widget.reportKey}/export', query: _query);
      bridge.downloadBytes(f.bytes, f.fileName == 'download' ? '${widget.reportKey}.csv' : f.fileName, 'text/csv');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save(String title) async {
    final r = await showNConfirm(context, title: 'Save this view', message: 'Saves the report with the current filters.', confirmLabel: 'Save', reasonLabel: 'Name', reasonRequired: true);
    if (!r.confirmed || r.reason == null || !mounted) return;
    try {
      await context.api.post('/reports/saved', body: {'name': r.reason, 'reportKey': widget.reportKey, 'filters': {for (final e in _query.entries) if (e.value != null) e.key: e.value}});
      if (mounted) NToast.of(context).show('Saved.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _chart(Json r, List<Json> rows, List<Json> cols) {
    final x = r['x'] as String?;
    final ys = [for (final y in (r['y'] as List? ?? const [])) '$y'];
    final chart = '${r['chart']}';
    if (x == null || ys.isEmpty || rows.isEmpty || chart == 'table') return const SizedBox.shrink();
    final y = ys.first;
    final yCol = cols.firstWhere((c) => c['key'] == y, orElse: () => {'type': 'number'});
    String fmt(num v) => _cell(v, yCol['type'] as String?);
    final data = [
      for (final row in rows.take(24))
        if (row[y] is num) NDatum('${row[x] ?? ''}'.length > 10 ? '${row[x]}'.substring(0, 10) : '${row[x] ?? ''}', row[y] as num),
    ];
    if (data.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InfoCard(
        title: '${yCol['label'] ?? Fmt.label(y)} by ${Fmt.label(x)}',
        child: switch (chart) {
          'doughnut' || 'funnel' => NDonut(data: data.take(8).toList(), formatter: fmt, semanticLabel: '${r['title']}'),
          'line' => Column(children: [NSparkline(values: [for (final d in data) d.value], height: 120, semanticLabel: '${r['title']}'), NBars(data: data, formatter: fmt, showValues: false, height: 80)]),
          _ => NBars(data: data, formatter: fmt, semanticLabel: '${r['title']}', showValues: data.length <= 14),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageFrame(
      child: AsyncView<Json>(
        reloadKey: '${Fmt.day(_from)}|${Fmt.day(_to)}|$_dept',
        load: () async => jsonMap(await context.api.get('/reports/${widget.reportKey}', query: _query)),
        builder: (context, r, reload) {
          final cols = jsonList(r['columns']);
          final rows = jsonList(r['rows']);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: () => context.go('/reports'), icon: const Icon(Icons.arrow_back_rounded, size: 18), label: const Text('Reports'))),
            NSectionHeader(
              title: '${r['title']}',
              subtitle: '${r['summary'] ?? ''}',
              trailing: [
                NButton(label: 'Export CSV', icon: Icons.download_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: _export),
                NButton(label: 'Save view', icon: Icons.bookmark_add_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: () => _save('${r['title']}')),
              ],
            ),
            Toolbar(children: [
              SizedBox(width: 170, child: NDateField(label: 'From', value: _from, required: true, onChanged: (d) => setState(() => _from = d ?? _from))),
              SizedBox(width: 170, child: NDateField(label: 'To', value: _to, required: true, onChanged: (d) => setState(() => _to = d ?? _to))),
              SizedBox(
                width: 220,
                child: AsyncView<List<NOption<String>>>(
                  load: () => Lookups.departments(context.api),
                  compact: true,
                  skeletonRows: 1,
                  builder: (context, opts, _) => NSelect<String>(label: 'Department', value: _dept ?? '', options: [const NOption('', 'All'), ...opts], onChanged: (v) => setState(() => _dept = (v == null || v.isEmpty) ? null : v)),
                ),
              ),
              NFilterChips<bool>(value: _table, onChanged: (v) => setState(() => _table = v), options: const [NOption(false, 'Chart + table'), NOption(true, 'Table only')]),
            ]),
            if (!_table) _chart(r, rows, cols),
            if (rows.isEmpty)
              const NEmptyState(title: 'No data for this range', icon: Icons.insights_rounded)
            else
              InfoCard(
                title: '${rows.length} rows',
                subtitle: 'Generated ${Fmt.dateTime(r['generatedAt'])}',
                child: NDataTable(
                  columns: [for (final c in cols) NColumn('${c['label']}', numeric: ['number', 'money', 'percent', 'minutes'].contains(c['type']))],
                  rows: [
                    for (final row in rows.take(500)) [for (final c in cols) Text(_cell(row[c['key']], c['type'] as String?), maxLines: 2, overflow: TextOverflow.ellipsis)],
                  ],
                ),
              ),
          ]);
        },
      ),
    );
  }
}
