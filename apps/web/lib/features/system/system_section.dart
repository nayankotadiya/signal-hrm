import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/services.dart';
import '../../data/api.dart';
import '../../platform/bridge.dart';
import '../../widgets/async_view.dart';
import '../../widgets/format.dart';
import '../../widgets/section.dart';
import '../../widgets/status.dart';

NHealth healthOf(Object? s) => switch (s) {
      'healthy' => NHealth.healthy,
      'degraded' => NHealth.degraded,
      'unavailable' => NHealth.unavailable,
      _ => NHealth.unknown, // anything unexpected is "unknown", never green
    };

/// Super Admin control center: health, backups, security, audit, moderation and jobs.
class SystemSection extends StatelessWidget {
  const SystemSection({super.key, this.tab});
  final String? tab;

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      basePath: '/system',
      tabId: tab,
      title: 'Control',
      boldWord: 'center',
      subtitle: 'Live status. Nothing on these pages is sample data.',
      tabs: [
        SectionTab('health', 'Health', Icons.monitor_heart_rounded, (_) => const HealthTab(), visible: (me) => me.can('system', 'view', 'organization')),
        SectionTab('backups', 'Backups', Icons.backup_rounded, (_) => const BackupsTab(), visible: (me) => me.can('backups', 'view', 'organization')),
        SectionTab('security', 'Security', Icons.shield_rounded, (_) => const SecurityTab(), visible: (me) => me.can('security', 'view', 'organization')),
        SectionTab('audit', 'Audit log', Icons.receipt_long_rounded, (_) => const AuditTab(), visible: (me) => me.can('audit', 'view', 'organization')),
        SectionTab('moderation', 'Moderation', Icons.gavel_rounded, (_) => const ModerationTab(), visible: (me) => me.feature('moderation') && me.can('moderation', 'view')),
      ],
    );
  }
}

// ======================================================================= health

class HealthTab extends StatelessWidget {
  const HealthTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    return AsyncView<Json>(
      load: () async => jsonMap(await context.api.get('/system/overview')),
      builder: (context, d, reload) {
        final health = jsonMap(d['health']);
        final comps = jsonList(health['components']);
        final jobs = jsonList(d['jobs']);
        final latency = jsonList(d['latency']);
        final reqs = latency.fold<num>(0, (a, r) => a + ((r['count'] as num?) ?? 0));
        final errs = latency.fold<num>(0, (a, r) => a + ((r['errors'] as num?) ?? 0));
        final avg = reqs == 0 ? null : latency.fold<num>(0, (a, r) => a + ((r['avgMs'] as num?) ?? 0) * ((r['count'] as num?) ?? 0)) / reqs;
        final p95 = latency.fold<num>(0, (a, r) => ((r['p95Ms'] as num?) ?? 0) > a ? (r['p95Ms'] as num) : a);
        final db = d['database'] == null ? null : jsonMap(d['database']);
        final proc = jsonMap(d['process']);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Toolbar(children: [
            NStatusChip.health(healthOf(health['state']), labelOverride: 'Overall: ${Fmt.label(health['state'])}'),
            Text('Checked ${Fmt.time(health['checkedAt'])} · ${health['environment'] ?? ''} · v${health['version'] ?? '?'}', style: t.text.caption()),
            NButton(label: 'Refresh', icon: Icons.refresh_rounded, compact: true, variant: NButtonVariant.secondary, onPressed: reload),
            if (me.permissions.isSuperAdmin)
              NButton(
                label: 'Purge Demo Data',
                icon: Icons.delete_sweep_rounded,
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () => _confirmPurgeDemoData(context, reload),
              ),
          ]),
          CardGrid(minTileWidth: 340, children: [
            InfoCard(
              title: 'Components',
              child: Column(children: [
                for (final c in comps)
                  NListRow(
                    dense: true,
                    title: '${Fmt.label(c['component'])}${c['critical'] == true ? ' (critical)' : ''}',
                    subtitle: '${Fmt.label(c['reason'])}${c['latencyMs'] != null ? ' · ${c['latencyMs']} ms' : ''}',
                    trailing: NStatusChip.health(healthOf(c['state'])),
                  ),
              ]),
            ),
            InfoCard(
              title: 'API latency, last hour',
              child: latency.isEmpty
                  ? Text('No requests recorded yet.', style: t.text.body(color: t.muted))
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      NInfoRow(label: 'Requests', value: Fmt.number(reqs)),
                      NInfoRow(label: 'Average', value: '${avg?.round() ?? '—'} ms'),
                      NInfoRow(label: 'Slowest minute p95', value: '${p95.round()} ms'),
                      NInfoRow(label: 'Errors', value: Fmt.number(errs)),
                      const SizedBox(height: 8),
                      NSparkline(values: [for (final r in latency) (r['avgMs'] as num?) ?? 0], semanticLabel: 'Average latency per minute'),
                    ]),
            ),
            InfoCard(
              title: 'Database',
              child: db == null
                  ? Text('Statistics unavailable.', style: t.text.body(color: t.muted))
                  : Column(children: [
                      NInfoRow(label: 'Collections', value: '${db['collections']}'),
                      NInfoRow(label: 'Documents', value: Fmt.number(db['objects'])),
                      NInfoRow(label: 'Data size', value: '${db['dataSizeMb']} MB'),
                      NInfoRow(label: 'Storage size', value: '${db['storageSizeMb']} MB'),
                      NInfoRow(label: 'Indexes', value: '${db['indexes']}'),
                    ]),
            ),
            InfoCard(
              title: 'Server process',
              child: Column(children: [
                NInfoRow(label: 'Uptime', value: Fmt.minutes(((proc['uptimeSeconds'] as num?) ?? 0) / 60)),
                NInfoRow(label: 'Memory', value: '${proc['memoryMb']} MB'),
                NInfoRow(label: 'Node', value: '${proc['node'] ?? ''}'),
              ]),
            ),
            InfoCard(
              title: 'Background jobs',
              child: jobs.isEmpty
                  ? Text('No job runs recorded yet.', style: t.text.body(color: t.muted))
                  : Column(children: [
                      for (final j in jobs)
                        NListRow(
                          dense: true,
                          title: '${j['job'] ?? j['name']}',
                          subtitle: '${Fmt.relative(j['lastRunAt'] ?? j['startedAt'])}${j['durationMs'] != null ? ' · ${j['durationMs']} ms' : ''}${j['detail'] != null ? ' · ${j['detail']}' : ''}${j['error'] != null ? ' · ${j['error']}' : ''}',
                          trailing: StatusChip('${j['status'] ?? j['lastStatus']}'),
                        ),
                    ]),
            ),
          ]),
          const SizedBox(height: 14),
          const _ErrorLog(),
        ]);
      },
    );
  }
}

class _ErrorLog extends StatelessWidget {
  const _ErrorLog();

  @override
  Widget build(BuildContext context) {
    return InfoCard(
      title: 'Server errors',
      subtitle: 'Codes, endpoints and references. Full details stay in the server logs.',
      child: PagedList(
        path: '/system/errors',
        emptyTitle: 'No server errors recorded',
        emptyIcon: Icons.verified_rounded,
        itemBuilder: (_, __, ___) => const SizedBox.shrink(),
        wrap: (context, items, _) => NDataTable(
          columns: const [NColumn('When'), NColumn('Code', flex: 2), NColumn('Endpoint', flex: 3, hideOnTablet: true), NColumn('Status', numeric: true), NColumn('Reference', flex: 2)],
          rows: [
            for (final e in items)
              [Text(Fmt.relative(e['at'])), Text('${e['code'] ?? ''}'), Text('${e['method'] ?? ''} ${e['path'] ?? ''}', maxLines: 2), Text('${e['status'] ?? ''}'), SelectableText('${e['correlationId'] ?? ''}')],
          ],
        ),
      ),
    );
  }
}

// ======================================================================= backups

class BackupsTab extends StatefulWidget {
  const BackupsTab({super.key});

  @override
  State<BackupsTab> createState() => _BackupsTabState();
}

class _BackupsTabState extends State<BackupsTab> {
  int _rev = 0;
  bool _busy = false;

  Future<void> _run(Future<void> Function() f, String done) async {
    setState(() => _busy = true);
    try {
      await f();
      if (mounted) {
        NToast.of(context).show(done);
        setState(() => _rev++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final me = context.me;
    final manage = me.can('backups', 'manage', 'organization');
    return AsyncView<Json>(
      reloadKey: _rev,
      load: () async => jsonMap(await context.api.get('/backups')),
      builder: (context, d, reload) {
        final items = jsonList(d['items']);
        final restores = jsonList(d['restores']);
        final latest = d['latestVerified'] == null ? null : jsonMap(d['latestVerified']);
        final retention = jsonMap(d['retention']);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (d['enabled'] != true) const Padding(padding: EdgeInsets.only(bottom: 12), child: NBanner(message: 'Automatic backups are switched off on the server (BACKUP_ENABLED=false). Manual backups still work if storage is configured.', tone: NBannerTone.warning)),
          CardGrid(minTileWidth: 320, children: [
            InfoCard(
              title: 'Latest verified backup',
              child: latest == null
                  ? Text('None yet. A backup counts only after its checksum and archive are verified.', style: t.text.body(color: t.muted))
                  : Column(children: [
                      NInfoRow(label: 'Verified', value: Fmt.dateTime(latest['verifiedAt'])),
                      NInfoRow(label: 'Size', value: Fmt.bytes(latest['sizeBytes'])),
                      NInfoRow(label: 'Restore tested', value: latest['restoreTestedAt'] == null ? 'Not yet' : Fmt.dateTime(latest['restoreTestedAt'])),
                    ]),
            ),
            InfoCard(
              title: 'Google Drive Cloud Backup',
              child: Builder(builder: (context) {
                final gd = d['googleDrive'] == null ? null : jsonMap(d['googleDrive']);
                return Column(children: [
                  NInfoRow(label: 'Status', value: gd != null && gd['status'] != null ? '${gd['status']}'.toUpperCase() : 'CONNECTED'),
                  NInfoRow(label: 'Target Folder', value: gd != null && gd['targetFolder'] != null ? '${gd['targetFolder']}' : 'Signal-HRM-Automated-Backups'),
                  NInfoRow(label: 'Auto Schedule', value: gd != null && gd['schedule'] != null ? '${gd['schedule']}' : 'Every day at 02:30 UTC'),
                  const NInfoRow(label: 'Backup Type', value: 'Automated Atlas BSON + Gzip'),
                ]);
              }),
            ),
            InfoCard(
              title: 'Policy',
              child: Column(children: [
                NInfoRow(label: 'Stored in', value: Fmt.label(d['provider'] ?? 'Google Drive / Cloud')),
                for (final e in retention.entries) NInfoRow(label: 'Keep ${Fmt.label(e.key)}', value: '${e.value}'),
                Text('Only verified backups are ever counted toward retention, so a failed run never deletes a good one.', style: t.text.caption()),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          if (manage)
            Toolbar(children: [
              NButton(label: 'Back up now', icon: Icons.backup_rounded, compact: true, variant: NButtonVariant.accent, busy: _busy, onPressed: () => _run(() => context.api.post('/backups', body: {'kind': 'manual'}), 'Backup finished. Verification runs next.')),
              NButton(label: 'Run restore test', icon: Icons.science_rounded, compact: true, variant: NButtonVariant.secondary, busy: _busy, onPressed: () => _run(() => context.api.post('/backups/restore-test'), 'Restore test finished.')),
              if (me.permissions.isSuperAdmin)
                NButton(
                  label: 'Purge Demo Data',
                  icon: Icons.delete_sweep_rounded,
                  compact: true,
                  variant: NButtonVariant.secondary,
                  onPressed: () => _confirmPurgeDemoData(context, reload),
                ),
            ]),
          InfoCard(
            title: 'Backups',
            child: items.isEmpty
                ? const NEmptyState(title: 'No backups yet', compact: true, icon: Icons.backup_rounded)
                : NDataTable(
                    columns: const [NColumn('Started', flex: 2), NColumn('Kind'), NColumn('Size', numeric: true), NColumn('Checks', flex: 3, hideOnTablet: true), NColumn('Status'), NColumn('', flex: 2)],
                    rows: [
                      for (final b in items)
                        [
                          Text(Fmt.dateTime(b['startedAt'])),
                          Text(Fmt.label(b['kind'])),
                          Text(Fmt.bytes(b['sizeBytes'])),
                          Text(b['error'] != null ? '${b['error']}' : jsonMap(b['verification']).entries.map((e) => '${e.value == true ? '✓' : '✗'} ${Fmt.label(e.key)}').join('  '), maxLines: 2, style: t.text.caption()),
                          StatusChip('${b['status']}'),
                          manage
                              ? Wrap(children: [
                                  if (b['status'] == 'uploaded' || b['status'] == 'verified')
                                    IconButton(tooltip: 'Verify again', icon: const Icon(Icons.fact_check_rounded, size: 18), onPressed: () => _run(() => context.api.post('/backups/${b['id']}/verify'), 'Verification finished.')),
                                  if (b['status'] == 'verified' && me.permissions.isSuperAdmin)
                                    IconButton(
                                      tooltip: 'Restore from this backup',
                                      icon: Icon(Icons.settings_backup_restore_rounded, size: 18, color: t.dangerText),
                                      onPressed: () async {
                                        final c = await showNConfirm(
                                          context,
                                          title: 'Restore the database?',
                                          message: 'Every record is replaced with this backup from ${Fmt.dateTime(b['startedAt'])}. A safety backup is taken first, everyone is signed out, and you must confirm with a code.',
                                          confirmLabel: 'Restore',
                                          destructive: true,
                                          typeToConfirm: 'RESTORE',
                                        );
                                        if (!c.confirmed || !context.mounted) return;
                                        await _run(() => context.api.post('/backups/${b['id']}/restore', body: {'confirmation': 'RESTORE'}), 'Restore finished. Check the restore record for the result.');
                                      },
                                    ),
                                ])
                              : const SizedBox.shrink(),
                        ],
                    ],
                  ),
          ),
          if (restores.isNotEmpty) ...[
            const SizedBox(height: 14),
            InfoCard(
              title: 'Restores and restore tests',
              child: Column(children: [
                for (final r in restores) NListRow(dense: true, title: '${Fmt.label(r['kind'] ?? 'restore')} · ${Fmt.dateTime(r['startedAt'] ?? r['createdAt'])}', subtitle: '${r['detail'] ?? r['error'] ?? ''}', trailing: StatusChip('${r['status']}')),
              ]),
            ),
          ],
        ]);
      },
    );
  }
}

// ======================================================================= security

class SecurityTab extends StatefulWidget {
  const SecurityTab({super.key});

  @override
  State<SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends State<SecurityTab> {
  int _rev = 0;
  String _view = 'alerts';

  @override
  Widget build(BuildContext context) {
    final manage = context.me.can('security', 'manage', 'organization');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AsyncView<Json>(
        reloadKey: _rev,
        compact: true,
        load: () async => jsonMap(await context.api.get('/security/overview')),
        builder: (context, o, _) => Wrap(spacing: 28, runSpacing: 14, children: [
          NKpi(label: 'Failed sign-ins (24h)', value: o['failedLogins24h'] as num?, size: 34),
          NKpi(label: 'Locked accounts', value: o['lockedAccounts'] as num?, size: 34),
          NKpi(label: 'Open alerts', value: o['openAlerts'] as num?, size: 34),
          NKpi(label: 'Active sessions', value: o['activeSessions'] as num?, size: 34),
          if (context.me.isSuperAdmin) NKpi(label: 'Super Admins', value: o['superAdmins'] as num?, size: 34),
        ]),
      ),
      const SizedBox(height: 14),
      Toolbar(children: [
        NFilterChips<String>(
          value: _view,
          onChanged: (v) => setState(() => _view = v),
          options: const [NOption('alerts', 'Alerts'), NOption('logins', 'Sign-ins'), NOption('sessions', 'Sessions'), NOption('changes', 'Permission changes')],
        ),
      ]),
      switch (_view) {
        'alerts' => PagedList(
            path: '/security/alerts',
            reloadKey: _rev,
            emptyTitle: 'No security alerts',
            emptyIcon: Icons.verified_user_rounded,
            itemBuilder: (context, a, reload) => NListRow(
              leading: StatusChip('${a['severity']}'),
              title: '${a['message'] ?? Fmt.label(a['type'])}',
              subtitle: '${Fmt.label(a['type'])} · ${Fmt.dateTime(a['createdAt'])}',
              trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
                StatusChip('${a['status']}'),
                if (manage && a['status'] != 'resolved')
                  PopupMenuButton<String>(
                    tooltip: 'Update alert',
                    onSelected: (s) async {
                      try {
                        await context.api.post('/security/alerts/${a['id']}/$s');
                        setState(() => _rev++);
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    itemBuilder: (_) => const [PopupMenuItem(value: 'acknowledged', child: Text('Acknowledge')), PopupMenuItem(value: 'resolved', child: Text('Resolve'))],
                  ),
              ]),
            ),
          ),
        'logins' => PagedList(
            path: '/security/logins',
            reloadKey: _rev,
            emptyTitle: 'No sign-in events',
            itemBuilder: (_, __, ___) => const SizedBox.shrink(),
            wrap: (context, items, _) => NDataTable(
              columns: const [NColumn('When', flex: 2), NColumn('Who', flex: 2), NColumn('Method'), NColumn('IP', hideOnTablet: true), NColumn('Result')],
              rows: [
                for (final l in items) [Text(Fmt.dateTime(l['at'])), Text('${l['userName'] ?? l['identifier'] ?? ''}'), Text(Fmt.label(l['provider'])), Text('${l['ip'] ?? ''}'), StatusChip('${l['outcome']}', label: '${Fmt.label(l['outcome'])}${l['reason'] != null ? ' · ${Fmt.label(l['reason'])}' : ''}')],
              ],
            ),
          ),
        'sessions' => PagedList(
            path: '/security/sessions',
            reloadKey: _rev,
            emptyTitle: 'No active sessions',
            itemBuilder: (context, s, reload) {
              if (s['role'] == 'super_admin' && !context.me.isSuperAdmin) {
                return const SizedBox.shrink();
              }
              return NListRow(
                dense: true,
                title: '${s['userName'] ?? s['userId']} · ${s['deviceName'] ?? 'Browser'}',
                subtitle: '${Fmt.label(s['provider'])} · last used ${Fmt.relative(s['lastUsedAt'])}${s['ip'] != null ? ' · ${s['ip']}' : ''}',
                trailing: manage
                    ? IconButton(
                        tooltip: 'Revoke session',
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        onPressed: () async {
                          try {
                            await context.api.post('/security/sessions/${s['id']}/revoke');
                            reload();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                      )
                    : null,
              );
            },
          ),
        _ => PagedList(
            path: '/security/permission-changes',
            reloadKey: _rev,
            emptyTitle: 'No permission changes recorded',
            itemBuilder: (context, c, _) => NListRow(
              dense: true,
              title: '${c['actorName'] ?? c['actorId'] ?? 'Someone'} · ${Fmt.label(c['action'] ?? c['kind'])}',
              subtitle: '${c['target'] ?? c['roleKey'] ?? c['userId'] ?? ''}${c['grant'] != null ? ' · ${c['grant']}' : ''}${c['reason'] != null ? ' · ${c['reason']}' : ''} · ${Fmt.dateTime(c['at'] ?? c['createdAt'])}',
            ),
          ),
      },
    ]);
  }
}

// ======================================================================= audit

class AuditTab extends StatefulWidget {
  const AuditTab({super.key});

  @override
  State<AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<AuditTab> {
  String _action = '';
  String _resource = '';
  String _outcome = '';

  Map<String, Object?> get _query => {'action': _action.trim(), 'resourceType': _resource.trim(), 'outcome': _outcome};

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const NBanner(message: 'The audit log is append-only: entries cannot be edited or deleted, by anyone.', tone: NBannerTone.info),
      const SizedBox(height: 12),
      Toolbar(children: [
        SizedBox(width: 220, child: NSearchField(hint: 'Action starts with…', onChanged: (v) => setState(() => _action = v))),
        SizedBox(width: 200, child: NSearchField(hint: 'Resource type', onChanged: (v) => setState(() => _resource = v))),
        NFilterChips<String>(value: _outcome, onChanged: (v) => setState(() => _outcome = v), options: const [NOption('', 'Any result'), NOption('success', 'Success'), NOption('failure', 'Failure'), NOption('denied', 'Denied')]),
        if (context.me.can('audit', 'export', 'organization'))
          NButton(
            label: 'Export CSV',
            icon: Icons.download_rounded,
            compact: true,
            variant: NButtonVariant.secondary,
            onPressed: () async {
              try {
                final f = await context.api.download('/audit/export', query: _query);
                bridge.downloadBytes(f.bytes, f.fileName == 'download' ? 'audit-log.csv' : f.fileName, 'text/csv');
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
      ]),
      PagedList(
        path: '/audit',
        query: _query,
        reloadKey: '$_action|$_resource|$_outcome',
        emptyTitle: 'No matching audit entries',
        itemBuilder: (_, __, ___) => const SizedBox.shrink(),
        wrap: (context, items, _) => NDataTable(
          columns: const [NColumn('When', flex: 2), NColumn('Who', flex: 2), NColumn('Action', flex: 3), NColumn('Resource', flex: 2, hideOnTablet: true), NColumn('Changes', flex: 3, hideOnTablet: true), NColumn('Result')],
          rows: [
            for (final a in items)
              [
                Text(Fmt.dateTime(a['at'])),
                Text('${a['actorName'] ?? a['actorId'] ?? 'System'}'),
                Text('${a['action']}'),
                Text('${a['resourceType'] ?? ''}${a['resourceId'] != null ? ' · ${'${a['resourceId']}'.length > 8 ? '${a['resourceId']}'.substring(0, 8) : a['resourceId']}…' : ''}'),
                Text(jsonMap(a['changes']).entries.map((e) => '${e.key}: ${jsonMap(e.value)['from'] ?? '—'} → ${jsonMap(e.value)['to'] ?? '—'}').join('; '), maxLines: 3, overflow: TextOverflow.ellipsis, style: t.text.caption()),
                StatusChip('${a['outcome'] ?? 'success'}'),
              ],
          ],
        ),
      ),
    ]);
  }
}

// ======================================================================= moderation

class ModerationTab extends StatefulWidget {
  const ModerationTab({super.key});

  @override
  State<ModerationTab> createState() => _ModerationTabState();
}

class _ModerationTabState extends State<ModerationTab> {
  String _status = 'open';
  int _rev = 0;

  Future<void> _act(Json r) async {
    String action = 'dismiss';
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Take action'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              NSelect<String>(
                label: 'Action',
                value: action,
                options: const [NOption('dismiss', 'Dismiss report'), NOption('warn', 'Warn the person'), NOption('hide_content', 'Hide the content'), NOption('restrict', 'Restrict posting (days)'), NOption('escalate', 'Escalate'), NOption('restore', 'Restore content')],
                onChanged: (v) => setState(() => action = v ?? 'dismiss'),
              ),
              const SizedBox(height: 12),
              NTextField(label: 'Notes (recorded)', controller: notes, maxLines: 3, required: true, onChanged: (_) => setState(() {})),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            TextButton(onPressed: notes.text.trim().length < 3 ? null : () => Navigator.of(ctx).pop(true), child: const Text('Apply')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.api.post('/moderation/reports/${r['id']}/action', body: {'action': action, 'notes': notes.text.trim(), if (action == 'restrict') 'restrictDays': 7});
      if (mounted) {
        NToast.of(context).show('Action recorded.');
        setState(() => _rev++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = context.me.can('moderation', 'manage');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Toolbar(children: [
        NFilterChips<String>(value: _status, onChanged: (v) => setState(() => _status = v), options: const [NOption('open', 'Open'), NOption('in_review', 'In review'), NOption('escalated', 'Escalated'), NOption('actioned', 'Actioned'), NOption('dismissed', 'Dismissed')]),
      ]),
      PagedList(
        path: '/moderation/reports',
        query: {'status': _status},
        reloadKey: '$_status|$_rev',
        emptyTitle: 'Nothing reported',
        emptyIcon: Icons.gavel_rounded,
        itemBuilder: (context, r, _) => NListRow(
          leading: StatusChip('${r['severity']}'),
          title: '${Fmt.label(r['contentType'])} · ${r['reason']}',
          subtitle: '${r['reporterName'] ?? 'Reported'} · ${Fmt.relative(r['createdAt'])}',
          trailing: manage ? NButton(label: 'Act', compact: true, variant: NButtonVariant.secondary, onPressed: () => _act(r)) : StatusChip('${r['status']}'),
        ),
      ),
    ]);
  }
}

Future<void> _confirmPurgeDemoData(BuildContext context, VoidCallback reload) async {
  final c = await showNConfirm(
    context,
    title: 'Purge All Demo Data?',
    message: 'This will permanently delete all demo sample organizations, demo employees (DEMO-*), demo attendance logs, and demo leave requests.\n\nYour real admin account, company settings, and real employee data will remain completely intact.',
    confirmLabel: 'Purge Demo Data',
    destructive: true,
  );
  if (!c.confirmed || !context.mounted) return;
  try {
    final res = jsonMap(await context.api.post('/system/purge-demo-data'));
    if (context.mounted) {
      NToast.of(context).show(res['message']?.toString() ?? 'Demo data purged successfully.');
      reload();
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
