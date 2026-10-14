import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/config.dart';
import '../../app/services.dart';
import '../../data/health_api.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../shell/app_shell.dart';

/// Phase 1 home. Answers "what needs me now?" for whoever is setting Signal HRM up: which parts of
/// the platform are actually running. Every number comes from the API's health endpoint; while it
/// loads or if it fails, numbers show a dash, never an invented value.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  HealthSummary? _summary;
  HealthApiException? _error;
  bool _loading = true;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load(initial: true);
    }
  }

  Future<void> _load({bool initial = false}) async {
    if (!initial) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final s = await ServicesScope.of(context).health.fetch();
      if (!mounted) return;
      setState(() {
        _summary = s;
        _loading = false;
      });
    } on HealthApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    final bp = NBreakpoint.of(context);
    final s = _error == null ? _summary : null;
    final total = s?.components.length ?? 0;

    double share(NHealth h) => total == 0 ? 0.25 : (s!.count(h) / total);
    String countText(NHealth h) => s == null ? '–' : '${s.count(h)}';

    final hero = NHeroRow(
      greeting: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        NGreeting(lead: l.homeLead, bold: l.homeBold),
        const SizedBox(height: 6),
        Text(l.homeSubtitle, style: t.text.body(color: t.muted)),
      ]),
      meters: [
        NMeter(label: l.healthHealthy, valueText: countText(NHealth.healthy), fraction: share(NHealth.healthy), highlighted: true),
        NMeter(label: l.healthDegraded, valueText: countText(NHealth.degraded), fraction: share(NHealth.degraded)),
        NMeter(label: l.healthUnavailable, valueText: countText(NHealth.unavailable), fraction: share(NHealth.unavailable)),
        NMeter(label: l.healthUnknown, valueText: countText(NHealth.unknown), fraction: share(NHealth.unknown)),
      ],
      kpis: [
        NKpi(label: l.homeKpiChecked, value: s?.components.length),
        NKpi(label: l.homeKpiHealthy, value: s?.count(NHealth.healthy)),
        NKpi(label: l.homeKpiLatency, value: s?['api']?.latencyMs),
      ],
    );

    final actionCard = NDarkActionCard.check(
      title: l.homeChecklistTitle,
      emptyText: l.homeChecklistEmpty,
      // Read-only: each item ticks itself only when the real check passes.
      items: [
        NActionItem(id: 'api', title: l.homeCheckApi, done: s != null, meta: _metaFor(l, s?['api'])),
        NActionItem(id: 'db', title: l.homeCheckDatabase, done: s?['database']?.state == NHealth.healthy, meta: _metaFor(l, s?['database'])),
        NActionItem(id: 'redis', title: l.homeCheckRedis, done: s?['redis']?.state == NHealth.healthy, meta: _metaFor(l, s?['redis'])),
        NActionItem(id: 'storage', title: l.homeCheckStorage, done: s?['storage']?.state == NHealth.healthy, meta: _metaFor(l, s?['storage'])),
        NActionItem(id: 'backups', title: l.homeCheckBackups, done: s?['backups']?.state == NHealth.healthy, meta: _metaFor(l, s?['backups'])),
      ],
    );

    final healthCard = NGlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Semantics(header: true, child: Text(l.homeSystemTitle, style: t.text.title()))),
          if (s != null) ...[
            Text(l.homeOverall, style: t.text.caption()),
            const SizedBox(width: 8),
            NStatusChip.health(s.state, labelOverride: _healthLabel(l, s.state)),
          ],
        ]),
        const SizedBox(height: 4),
        Text(
          _loading
              ? l.homeChecking
              : s != null
                  ? '${l.homeLastChecked(_time(context, s.checkedAt))} · v${s.version} · ${s.environment}'
                  : '',
          style: t.text.caption(),
        ),
        SizedBox(height: t.space(14)),
        if (_loading && s == null)
          const NSkeletonList(rows: 5)
        else if (_error != null)
          _ErrorBlock(
            message: l.homeApiUnreachable(AppConfig.apiBaseUrl),
            reference: _error!.correlationId,
            retryLabel: l.homeRefresh,
            onRetry: _load,
          )
        else if (s != null)
          for (final c in s.components) _ComponentRow(component: c),
        if (s != null) ...[
          SizedBox(height: t.space(12)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: NButton(label: l.homeRefresh, icon: Icons.refresh_rounded, variant: NButtonVariant.secondary, busy: _loading, onPressed: _load),
          ),
        ],
      ]),
    );

    final nextCard = NGlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.homeNextTitle, style: t.text.title()),
        const SizedBox(height: 8),
        Text(l.homeNextBody, style: t.text.body(color: t.muted)),
      ]),
    );

    final aboutCard = NGlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.appTitle, style: t.text.title()),
        const SizedBox(height: 4),
        Text(l.tagline, style: t.text.body(color: t.muted)),
        const SizedBox(height: 12),
        Text(l.attribution, style: t.text.caption()),
      ]),
    );

    // On laptop/desktop the dark card owns the 4th (1.12fr) column, so the grid uses three.
    final grid = NBentoGrid(wideColumns: 3, items: [
      NBentoItem(child: healthCard, span: 3, tabletSpan: 2),
      NBentoItem(child: nextCard, span: 2, tabletSpan: 1),
      NBentoItem(child: aboutCard, span: 1, tabletSpan: 1),
    ]);

    final Widget body;
    if (bp.isWide) {
      // Dark card in the right column (1.12fr), beside the grid.
      body = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 300, child: NEntrance(order: 1, child: grid)),
        SizedBox(width: t.gap),
        Expanded(flex: 112, child: NEntrance(order: 2, child: actionCard)),
      ]);
    } else {
      // Mobile and tablet: the dark card right after the hero answers "what needs me now?".
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NEntrance(order: 1, child: actionCard),
        SizedBox(height: t.gap),
        NEntrance(order: 2, child: grid),
      ]);
    }

    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NEntrance(order: 0, child: hero),
        SizedBox(height: t.space(22)),
        body,
      ]),
    );
  }

  static String _time(BuildContext context, DateTime at) =>
      MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(at));

  static String? _metaFor(AppLocalizations l, ComponentHealth? c) => c == null ? null : _healthLabel(l, c.state);
}

String _healthLabel(AppLocalizations l, NHealth h) => switch (h) {
      NHealth.healthy => l.healthHealthy,
      NHealth.degraded => l.healthDegraded,
      NHealth.unavailable => l.healthUnavailable,
      NHealth.unknown => l.healthUnknown,
    };

String _componentLabel(AppLocalizations l, String name) => switch (name) {
      'api' => l.compApi,
      'database' => l.compDatabase,
      'redis' => l.compRedis,
      'storage' => l.compStorage,
      'backups' => l.compBackups,
      'jobs' => l.compJobs,
      'notifications' => l.compNotifications,
      _ => name,
    };

String _reasonLabel(AppLocalizations l, String reason) => switch (reason) {
      'ok' => l.reasonOk,
      'not_configured' => l.reasonNotConfigured,
      'not_implemented' => l.reasonNotImplemented,
      'connecting' => l.reasonConnecting,
      'disconnected' => l.reasonDisconnected,
      'timeout' => l.reasonTimeout,
      'slow_response' => l.reasonSlowResponse,
      'event_loop_lag' => l.reasonEventLoopLag,
      'no_runs' => l.reasonOk,
      'no_verified_backup' => l.reasonOk,
      'check_failed' => l.reasonCheckFailed,
      _ => l.reasonOk,
    };

class _ComponentRow extends StatelessWidget {
  const _ComponentRow({required this.component});
  final ComponentHealth component;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    final latency = component.latencyMs == null ? '' : ' · ${component.latencyMs} ms';
    return Container(
      padding: EdgeInsets.symmetric(vertical: t.space(9)),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: t.divider))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_componentLabel(l, component.component), style: t.text.body(weight: FontWeight.w500)),
            Text('${_reasonLabel(l, component.reason)}$latency', style: t.text.caption()),
          ]),
        ),
        NStatusChip.health(component.state, labelOverride: _healthLabel(l, component.state)),
      ]),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.retryLabel, required this.onRetry, this.reference});
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  final String? reference;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: EdgeInsets.all(t.space(14)),
        decoration: BoxDecoration(color: t.dangerTint, borderRadius: BorderRadius.circular(t.radiusTile)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.cloud_off_rounded, color: t.dangerText, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: t.text.body(color: t.dangerText))),
          ]),
          if (reference != null) ...[
            const SizedBox(height: 6),
            SelectableText('Ref: $reference', style: t.text.caption()),
          ],
          const SizedBox(height: 10),
          NButton(label: retryLabel, icon: Icons.refresh_rounded, variant: NButtonVariant.primary, compact: true, onPressed: onRetry),
        ]),
      ),
    );
  }
}
