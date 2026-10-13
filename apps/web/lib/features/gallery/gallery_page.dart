import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/preferences.dart';
import '../../shell/app_shell.dart';

/// N UI component gallery (dev and staging only; hidden in production builds).
/// Everything here is labelled sample content for design review, not live data.
class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  int _section = 0;

  static const _sections = [
    NPillItem(label: 'Signature', icon: Icons.auto_awesome_rounded),
    NPillItem(label: 'Data', icon: Icons.insights_rounded),
    NPillItem(label: 'Feedback', icon: Icons.notifications_active_rounded),
    NPillItem(label: 'Responsive', icon: Icons.devices_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NEntrance(
          order: 0,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const NGreeting(lead: 'Component', bold: 'gallery'),
            const SizedBox(height: 6),
            Text('$kNUiAttribution · sample content for design review, not live data', style: t.text.body(color: t.muted)),
          ]),
        ),
        SizedBox(height: t.space(18)),
        NEntrance(
          order: 1,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: NSlidingPills(
              semanticLabel: 'Gallery sections',
              items: _sections,
              selectedIndex: _section,
              onChanged: (i) => setState(() => _section = i),
            ),
          ),
        ),
        SizedBox(height: t.space(18)),
        NViewSwitcher(
          index: _section,
          child: switch (_section) {
            0 => const _SignatureSection(),
            1 => const _DataSection(),
            2 => const _FeedbackSection(),
            _ => const _ResponsiveSection(),
          },
        ),
      ]),
    );
  }
}

class _Specimen extends StatelessWidget {
  const _Specimen({required this.title, required this.child, this.note});
  final String title;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return NGlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: t.text.title()),
        if (note != null) ...[const SizedBox(height: 2), Text(note!, style: t.text.caption())],
        SizedBox(height: t.space(14)),
        child,
      ]),
    );
  }
}

// ------------------------------------------------------------------ Signature

class _SignatureSection extends StatefulWidget {
  const _SignatureSection();
  @override
  State<_SignatureSection> createState() => _SignatureSectionState();
}

class _SignatureSectionState extends State<_SignatureSection> {
  int _a = 1;
  int _b = 0;
  int _c = 2;
  int _view = 0;
  int _cardMode = 1;
  bool _failNext = false;
  List<NActionItem> _approvals = _seedApprovals();
  List<NActionItem> _tasks = const [
    NActionItem(id: 't1', title: 'Upload PAN card', meta: 'Today', done: true),
    NActionItem(id: 't2', title: 'Acknowledge leave policy', meta: 'Today'),
    NActionItem(id: 't3', title: 'Complete profile photo', meta: 'Fri'),
    NActionItem(id: 't4', title: 'Meet your buddy', meta: 'Mon', done: true),
    NActionItem(id: 't5', title: 'Set up attendance selfie', meta: 'Mon', done: true),
  ];

  static List<NActionItem> _seedApprovals() => const [
        NActionItem(id: 'a1', title: 'Asha Patel · Casual leave', subtitle: 'Thu 15 – Fri 16 Oct · 2 days', meta: '2h'),
        NActionItem(id: 'a2', title: 'Ravi Shah · Expense ₹1,840', subtitle: 'Client lunch · receipt attached', meta: '1d'),
        NActionItem(id: 'a3', title: 'Meera Joshi · Attendance correction', subtitle: 'Missed check-out on 9 Oct', meta: '3d'),
      ];

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final views = ['Today', 'Week', 'Month', 'Quarter'];
    return NBentoGrid(items: [
      NBentoItem(
        span: 2,
        tabletSpan: 2,
        child: _Specimen(
          title: 'NSlidingPills',
          note: 'One travelling indicator · spring 550ms · width 450ms · labels 350ms',
          child: Wrap(spacing: 12, runSpacing: 12, children: [
            NSlidingPills(
              size: NPillSize.small,
              items: const [NPillItem(label: 'Today'), NPillItem(label: 'Week'), NPillItem(label: 'Month')],
              selectedIndex: _a,
              onChanged: (i) => setState(() => _a = i),
            ),
            NSlidingPills(
              items: const [
                NPillItem(label: 'All'),
                NPillItem(label: 'Pending', badgeCount: 4),
                NPillItem(label: 'Approved'),
                NPillItem(label: 'Rejected'),
              ],
              selectedIndex: _b,
              onChanged: (i) => setState(() => _b = i),
            ),
            NSlidingPills(
              size: NPillSize.large,
              items: const [
                NPillItem(label: 'People', icon: Icons.groups_rounded),
                NPillItem(label: 'Time', icon: Icons.schedule_rounded),
                NPillItem(label: 'Work', icon: Icons.task_alt_rounded),
              ],
              selectedIndex: _c,
              onChanged: (i) => setState(() => _c = i),
            ),
          ]),
        ),
      ),
      NBentoItem(
        span: 2,
        tabletSpan: 2,
        child: _Specimen(
          title: 'NViewSwitcher',
          note: 'Exit 220ms toward travel, then enter 520ms from the other side',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            NSlidingPills(
              size: NPillSize.small,
              items: [for (final v in views) NPillItem(label: v)],
              selectedIndex: _view,
              onChanged: (i) => setState(() => _view = i),
            ),
            SizedBox(height: t.space(12)),
            SizedBox(
              height: 120,
              child: NViewSwitcher(
                index: _view,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(t.radiusTile),
                    gradient: LinearGradient(colors: [t.chartStart.withValues(alpha: 0.25), t.chartEnd.withValues(alpha: 0.25)]),
                  ),
                  alignment: Alignment.center,
                  child: Text(views[_view], style: t.text.bigNumber(40)),
                ),
              ),
            ),
          ]),
        ),
      ),
      NBentoItem(
        span: 4,
        tabletSpan: 2,
        child: _Specimen(
          title: 'NDarkActionCard',
          note: 'One per screen. Approve uses held commit: Undo for 5s, then sent with an idempotency key.',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              NSlidingPills(
                size: NPillSize.small,
                items: const [NPillItem(label: 'Check mode'), NPillItem(label: 'Approve mode')],
                selectedIndex: _cardMode,
                onChanged: (i) => setState(() => _cardMode = i),
              ),
              SizedBox(
                width: 260,
                child: NSwitch(
                  label: 'Next commit fails',
                  description: 'Simulate a server rejection',
                  value: _failNext,
                  onChanged: (v) => setState(() => _failNext = v),
                ),
              ),
              NButton(
                label: 'Reset rows',
                compact: true,
                variant: NButtonVariant.secondary,
                onPressed: () => setState(() => _approvals = _seedApprovals()),
              ),
            ]),
            SizedBox(height: t.space(14)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _cardMode == 0
                  ? NDarkActionCard.check(
                      title: 'My onboarding',
                      items: _tasks,
                      onToggle: (item, done) => setState(() {
                        _tasks = [for (final x in _tasks) x.id == item.id ? NActionItem(id: x.id, title: x.title, meta: x.meta, done: done) : x];
                      }),
                    )
                  : NDarkActionCard.approve(
                      title: 'Team approvals',
                      items: _approvals,
                      describeError: (_) => 'Not saved: the request changed while you were deciding. Refresh and try again.',
                      commit: (item, decision, key) async {
                        await Future<void>.delayed(const Duration(milliseconds: 300));
                        if (_failNext) {
                          if (mounted) setState(() => _failNext = false);
                          throw StateError('simulated');
                        }
                        if (mounted) setState(() => _approvals = _approvals.where((a) => a.id != item.id).toList());
                      },
                    ),
            ),
          ]),
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ Data

class _DataSection extends StatefulWidget {
  const _DataSection();
  @override
  State<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<_DataSection> {
  final _rnd = math.Random();
  num? _a = 128;
  num? _b = 7;
  num? _c = 96.4;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return NBentoGrid(items: [
      NBentoItem(
        span: 4,
        tabletSpan: 2,
        child: _Specimen(
          title: 'NHeroRow',
          note: 'Greeting with one bold word · four proportional meters (one lime) · three count-up KPIs',
          child: NHeroRow(
            greeting: const NGreeting(lead: 'Welcome in,', bold: 'Priya'),
            meters: const [
              NMeter(label: 'Present', valueText: '42', fraction: 0.62, highlighted: true),
              NMeter(label: 'Remote', valueText: '9', fraction: 0.18),
              NMeter(label: 'On leave', valueText: '4', fraction: 0.12),
              NMeter(label: 'Late', valueText: '3', fraction: 0.08),
            ],
            kpis: [
              NKpi(label: 'Headcount', value: _a),
              NKpi(label: 'Pending', value: _b),
              NKpi(label: 'On time', value: _c, suffix: '%'),
            ],
          ),
        ),
      ),
      NBentoItem(
        span: 2,
        tabletSpan: 1,
        child: _Specimen(
          title: 'NKpi',
          note: 'Counts from the previous value · 1.1s ease-out cubic · dash when unavailable',
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            NButton(
              label: 'New values',
              compact: true,
              onPressed: () => setState(() {
                _a = 80 + _rnd.nextInt(120);
                _b = _rnd.nextInt(20);
                _c = (800 + _rnd.nextInt(200)) / 10;
              }),
            ),
            NButton(
              label: 'Unavailable',
              compact: true,
              variant: NButtonVariant.secondary,
              onPressed: () => setState(() => _a = _b = _c = null),
            ),
          ]),
        ),
      ),
      NBentoItem(
        span: 2,
        tabletSpan: 1,
        child: _Specimen(
          title: 'NStatusChip',
          note: 'Health has exactly four states; color always paired with icon and text',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            const NStatusChip.health(NHealth.healthy),
            const NStatusChip.health(NHealth.degraded),
            const NStatusChip.health(NHealth.unavailable),
            const NStatusChip.health(NHealth.unknown),
            const NStatusChip.status(label: 'Approved', tone: NTone.positive),
            const NStatusChip.status(label: 'Pending', tone: NTone.warning),
            const NStatusChip.status(label: 'Rejected', tone: NTone.negative),
            NLiveDot(color: t.green),
          ]),
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ Feedback

class _FeedbackSection extends StatefulWidget {
  const _FeedbackSection();
  @override
  State<_FeedbackSection> createState() => _FeedbackSectionState();
}

class _FeedbackSectionState extends State<_FeedbackSection> {
  bool _on = true;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final toast = NToast.of(context);
    return NBentoGrid(items: [
      NBentoItem(
        span: 2,
        tabletSpan: 2,
        child: _Specimen(
          title: 'NButton · NIconButton',
          child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            NButton(label: 'Check in', icon: Icons.login_rounded, onPressed: () {}),
            NButton(label: 'Apply for leave', variant: NButtonVariant.accent, onPressed: () {}),
            NButton(label: 'Export', variant: NButtonVariant.secondary, onPressed: () {}),
            NButton(
              label: 'Finalize payroll',
              busy: _busy,
              onPressed: () async {
                setState(() => _busy = true);
                await Future<void>.delayed(const Duration(seconds: 2));
                if (mounted) setState(() => _busy = false);
              },
            ),
            const NButton(label: 'Disabled', onPressed: null),
            NIconButton(icon: Icons.notifications_none_rounded, label: 'Notifications', badgeCount: 3, onPressed: () {}),
            NIconButton(icon: Icons.person_rounded, label: 'Account', filled: true, onPressed: () {}),
          ]),
        ),
      ),
      NBentoItem(
        span: 2,
        tabletSpan: 2,
        child: _Specimen(
          title: 'NToast',
          note: 'Dark pill, bottom centre, announced politely; optional Undo in lime',
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            NButton(label: 'Show toast', compact: true, onPressed: () => toast.show('Published')),
            NButton(
              label: 'Toast with Undo',
              compact: true,
              variant: NButtonVariant.secondary,
              onPressed: () => toast.show(
                'Task marked done',
                action: NToastAction(label: 'Undo', onPressed: () => toast.show('Restored')),
              ),
            ),
          ]),
        ),
      ),
      NBentoItem(
        span: 2,
        tabletSpan: 1,
        child: _Specimen(
          title: 'NSwitch',
          child: NSwitch(
            label: 'Email me when a request needs me',
            description: 'Essential security notices are always on',
            value: _on,
            onChanged: (v) => setState(() => _on = v),
          ),
        ),
      ),
      const NBentoItem(
        span: 2,
        tabletSpan: 1,
        child: _Specimen(title: 'NSkeleton', note: 'Lists load with skeletons, never spinners', child: NSkeletonList(rows: 3)),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ Responsive

class _ResponsiveSection extends StatefulWidget {
  const _ResponsiveSection();
  @override
  State<_ResponsiveSection> createState() => _ResponsiveSectionState();
}

class _ResponsiveSectionState extends State<_ResponsiveSection> {
  int _theme = 2; // 0 light, 1 dark, 2 both

  static const _devices = [('Mobile · 390', Size(390, 780)), ('Tablet · 820', Size(820, 900)), ('Desktop · 1280', Size(1280, 820))];

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final brightnesses = switch (_theme) {
      0 => [Brightness.light],
      1 => [Brightness.dark],
      _ => [Brightness.light, Brightness.dark],
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NSlidingPills(
        size: NPillSize.small,
        items: const [NPillItem(label: 'Light'), NPillItem(label: 'Dark'), NPillItem(label: 'Both')],
        selectedIndex: _theme,
        onChanged: (i) => setState(() => _theme = i),
      ),
      SizedBox(height: t.space(14)),
      for (final (label, size) in _devices) ...[
        Text(label, style: t.text.title()),
        SizedBox(height: t.space(8)),
        LayoutBuilder(builder: (context, c) {
          final gap = t.gap;
          final perFrame = (c.maxWidth - gap * (brightnesses.length - 1)) / brightnesses.length;
          final narrow = perFrame < 260;
          final frames = [for (final b in brightnesses) _DeviceFrame(size: size, brightness: b, maxWidth: narrow ? c.maxWidth : perFrame)];
          return narrow
              ? Column(children: [for (final f in frames) Padding(padding: EdgeInsets.only(bottom: gap), child: f)])
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (var i = 0; i < frames.length; i++) ...[if (i > 0) SizedBox(width: gap), frames[i]],
                ]);
        }),
        SizedBox(height: t.space(20)),
      ],
    ]);
  }
}

/// Renders a sample screen at a real device width with its own theme and breakpoint, then scales
/// it down to fit. Layout happens at full size, so this is what that device would show.
class _DeviceFrame extends StatelessWidget {
  const _DeviceFrame({required this.size, required this.brightness, required this.maxWidth});
  final Size size;
  final Brightness brightness;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final prefs = PreferencesScope.of(context).value;
    final scale = math.min(1.0, maxWidth / size.width);
    final theme = NTheme.build(prefs, brightness);
    return SizedBox(
      width: size.width * scale,
      height: size.height * scale,
      child: FittedBox(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: size,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(size: size, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
            child: Theme(
              data: theme,
              child: NBreakpointScope(
                breakpoint: NBreakpoint.fromWidth(size.width),
                width: size.width,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: const NPageBackground(child: _SampleScreen()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SampleScreen extends StatelessWidget {
  const _SampleScreen();

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final bp = NBreakpoint.of(context);
    final card = NDarkActionCard.check(
      title: 'My tasks',
      items: const [
        NActionItem(id: '1', title: 'Upload PAN card', done: true),
        NActionItem(id: '2', title: 'Read leave policy'),
        NActionItem(id: '3', title: 'Meet your buddy'),
      ],
      onToggle: (_, __) {},
    );
    Widget tile(String title, String value) => NGlassCard(
          blur: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.text.caption()),
            const SizedBox(height: 6),
            Text(value, style: t.text.bigNumber(30)),
          ]),
        );
    final grid = NBentoGrid(wideColumns: 3, items: [
      NBentoItem(smallTile: true, child: tile('Leave left', '12')),
      NBentoItem(smallTile: true, child: tile('Tasks due', '3')),
      NBentoItem(smallTile: true, child: tile('Hours today', '6.5')),
      NBentoItem(span: 3, tabletSpan: 2, child: tile('Payslip · Sep', '₹48,200')),
    ]);
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.all(bp.isMobile ? 10 : 18),
      child: NPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const NHeroRow(
            greeting: NGreeting(lead: 'Welcome in,', bold: 'Priya'),
            meters: [
              NMeter(label: 'Present', valueText: '42', fraction: 0.6, highlighted: true),
              NMeter(label: 'Remote', valueText: '9', fraction: 0.2),
              NMeter(label: 'Leave', valueText: '4', fraction: 0.12),
              NMeter(label: 'Late', valueText: '3', fraction: 0.08),
            ],
            kpis: [NKpi(label: 'Headcount', value: 58), NKpi(label: 'Pending', value: 7), NKpi(label: 'Overdue', value: 2)],
          ),
          SizedBox(height: t.space(16)),
          if (bp.isWide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 300, child: grid),
              SizedBox(width: t.gap),
              Expanded(flex: 112, child: card),
            ])
          else ...[
            card,
            SizedBox(height: t.gap),
            grid,
          ],
        ]),
      ),
    );
  }
}
