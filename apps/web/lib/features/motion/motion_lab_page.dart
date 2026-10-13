import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/preferences.dart';
import '../../shell/app_shell.dart';

/// Phase 1 acceptance demo: the sliding pill and direction-aware transitions, including reduced
/// motion, RTL, text scale, resize, overflow and swipe tracking. Dev and staging only.
class MotionLabPage extends StatefulWidget {
  const MotionLabPage({super.key});

  @override
  State<MotionLabPage> createState() => _MotionLabPageState();
}

class _MotionLabPageState extends State<MotionLabPage> {
  bool _rtl = false;
  double _textScale = 1.0;
  double _width = 1.0; // fraction of available width for the resize demo
  int _nav = 1;
  int _overflow = 0;
  int _page = 0;
  int _view = 0;
  final _pager = PageController();

  static const _navItems = [
    NPillItem(label: 'Home', icon: Icons.space_dashboard_rounded),
    NPillItem(label: 'People', icon: Icons.groups_rounded),
    NPillItem(label: 'Time', icon: Icons.schedule_rounded),
    NPillItem(label: 'Work', icon: Icons.task_alt_rounded),
    NPillItem(label: 'Approvals', icon: Icons.fact_check_rounded, badgeCount: 5),
  ];
  static const _pages = ['Leave', 'Attendance', 'Expenses', 'Travel'];
  static const _views = ['Collect', 'Calculate', 'Review', 'Approve', 'Finalize', 'Pay'];

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final prefs = PreferencesScope.of(context);
    final reduced = NMotion.reduced(context);

    Widget block(String title, String note, Widget child) => Padding(
          padding: EdgeInsets.only(bottom: t.gap),
          child: NGlassCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(title, style: t.text.title()),
              const SizedBox(height: 2),
              Text(note, style: t.text.caption()),
              SizedBox(height: t.space(14)),
              child,
            ]),
          ),
        );

    final controls = NGlassCard(
      child: Wrap(spacing: 18, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 250,
          child: NSwitch(
            label: 'Reduce motion',
            description: reduced ? 'Indicator jumps, views swap' : 'Springs and slides on',
            value: prefs.value.reducedMotion,
            onChanged: (v) => prefs.update((p) => p.copyWith(reducedMotion: v)),
          ),
        ),
        SizedBox(
          width: 200,
          child: NSwitch(label: 'Right-to-left', value: _rtl, onChanged: (v) => setState(() => _rtl = v)),
        ),
        SizedBox(
          width: 260,
          child: Row(children: [
            Text('Text ${(_textScale * 100).round()}%', style: t.text.body()),
            Expanded(
              child: Slider(value: _textScale, min: 0.85, max: 2.0, onChanged: (v) => setState(() => _textScale = v)),
            ),
          ]),
        ),
      ]),
    );

    final demos = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      block(
        'Sliding pill',
        'Click, use arrow keys / Home / End, or resize. The indicator re-measures and never jumps on first layout.',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Width', style: t.text.caption()),
            Expanded(child: Slider(value: _width, min: 0.35, max: 1, onChanged: (v) => setState(() => _width = v))),
          ]),
          FractionallySizedBox(
            widthFactor: _width,
            child: NSlidingPills(
              semanticLabel: 'Demo navigation',
              expand: true,
              items: _navItems,
              selectedIndex: _nav,
              onChanged: (i) => setState(() => _nav = i),
            ),
          ),
          SizedBox(height: t.space(12)),
          NSlidingPills(
            items: _navItems,
            selectedIndex: _nav,
            onChanged: (i) => setState(() => _nav = i),
          ),
        ]),
      ),
      block(
        'Overflow',
        'More labels than space: the track scrolls without a scrollbar and the active label scrolls to centre.',
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: NSlidingPills(
            size: NPillSize.small,
            items: [
              for (final s in const ['Profile', 'Branding', 'Departments', 'Teams', 'Locations', 'Working days', 'Attendance rules', 'Leave policies', 'Payroll', 'Security'])
                NPillItem(label: s),
            ],
            selectedIndex: _overflow,
            onChanged: (i) => setState(() => _overflow = i),
          ),
        ),
      ),
      block(
        'Swipe',
        'Pages linked to the pills: drag the panel and the indicator follows your finger, then settles.',
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NSlidingPills(
            items: [for (final p in _pages) NPillItem(label: p)],
            selectedIndex: _page,
            pageController: _pager,
            onChanged: (i) {
              setState(() => _page = i);
              if (reduced) {
                _pager.jumpToPage(i);
              } else {
                _pager.animateToPage(i, duration: t.durations.pillPosition, curve: NCurves.emphasized);
              }
            },
          ),
          SizedBox(height: t.space(12)),
          SizedBox(
            height: 140,
            child: PageView(
              controller: _pager,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                for (final p in _pages)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: t.lime.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(t.radiusTile),
                    ),
                    alignment: Alignment.center,
                    child: Text(p, style: t.text.bigNumber(34)),
                  ),
              ],
            ),
          ),
        ]),
      ),
      block(
        'Direction-aware switching',
        'Payroll stepper. Forward: old view leaves left, new enters from the right. Back: reversed. The page-load stagger does not replay.',
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NSlidingPills(
            size: NPillSize.small,
            items: [for (final v in _views) NPillItem(label: v)],
            selectedIndex: _view,
            onChanged: (i) => setState(() => _view = i),
          ),
          SizedBox(height: t.space(12)),
          SizedBox(
            height: 150,
            child: NViewSwitcher(
              index: _view,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(t.radiusTile),
                  gradient: LinearGradient(colors: [t.chartStart.withValues(alpha: 0.22), t.chartEnd.withValues(alpha: 0.22)]),
                ),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Step ${_view + 1} of ${_views.length}', style: t.text.caption()),
                  Text(_views[_view], style: t.text.bigNumber(40)),
                ]),
              ),
            ),
          ),
        ]),
      ),
    ]);

    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NEntrance(
          order: 0,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const NGreeting(lead: 'Motion', bold: 'lab'),
            const SizedBox(height: 6),
            Text('Phase 1 check for the sliding pill and direction-aware transitions.', style: t.text.body(color: t.muted)),
          ]),
        ),
        SizedBox(height: t.space(18)),
        NEntrance(order: 1, child: controls),
        SizedBox(height: t.gap),
        NEntrance(
          order: 2,
          // Local overrides so RTL and text scale can be tested without changing the whole app.
          child: Directionality(
            textDirection: _rtl ? TextDirection.rtl : TextDirection.ltr,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(14) / 14 * _textScale),
              ),
              child: demos,
            ),
          ),
        ),
      ]),
    );
  }
}
