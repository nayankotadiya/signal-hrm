import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:n_ui/n_ui.dart';

import '../../app/preferences.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../shell/app_shell.dart';

/// N UI personalization with a live preview. Every control writes NPreferences, which feed
/// NTokens at once. Changing appearance never changes data or permissions.
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  final _hex = TextEditingController();
  String? _hexError;

  static const _accents = [NAccent.purple, NAccent.blue, NAccent.green, NAccent.orange, NAccent.pink, NAccent.teal];

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _applyHex(PreferencesController prefs, AppLocalizations l) {
    final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch(_hex.text.trim());
    if (m == null) {
      setState(() => _hexError = l.appearanceCustomInvalid);
      return;
    }
    setState(() => _hexError = null);
    final color = Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
    prefs.update((p) => p.copyWith(accent: NAccent.custom, customAccent: color));
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final l = AppLocalizations.of(context);
    final bp = NBreakpoint.of(context);
    final prefs = PreferencesScope.of(context);
    final p = prefs.value;

    Widget section(String title, Widget child) => Padding(
          padding: EdgeInsets.only(bottom: t.space(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.text.caption(weight: FontWeight.w600)),
            SizedBox(height: t.space(8)),
            child,
          ]),
        );

    Widget slider(String label, double value, double min, double max, ValueChanged<double> onChanged, {String Function(double)? fmt}) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: t.text.body())),
          Text(fmt?.call(value) ?? '${(value * 100).round()}%', style: t.text.caption()),
        ]),
        Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged, label: label),
      ]);
    }

    final clamped = p.accent == NAccent.custom && p.customAccent != null && t.accent != p.customAccent;

    final controls = NGlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        section(
          l.appearanceTheme,
          NSlidingPills(
            items: [NPillItem(label: l.appearanceIos), NPillItem(label: l.appearanceClassic)],
            selectedIndex: p.themeStyle.index,
            onChanged: (i) => prefs.update((p) => p.copyWith(themeStyle: NThemeStyle.values[i])),
          ),
        ),
        section(
          l.appearanceMode,
          NSlidingPills(
            items: [
              NPillItem(label: l.appearanceLight, icon: Icons.light_mode_rounded),
              NPillItem(label: l.appearanceDark, icon: Icons.dark_mode_rounded),
              NPillItem(label: l.appearanceSystem, icon: Icons.contrast_rounded),
            ],
            selectedIndex: p.appearance.index,
            onChanged: (i) => prefs.update((p) => p.copyWith(appearance: NAppearance.values[i])),
          ),
        ),
        section(
          l.appearanceAccent,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final a in _accents)
                _Swatch(
                  color: NTokens.resolve(p.copyWith(accent: a), t.brightness).accent,
                  selected: p.accent == a,
                  label: a.name,
                  onTap: () => prefs.update((p) => p.copyWith(accent: a)),
                ),
            ]),
            SizedBox(height: t.space(10)),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _hex,
                  decoration: InputDecoration(
                    labelText: l.appearanceCustom,
                    hintText: l.appearanceCustomHint,
                    errorText: _hexError,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(t.radiusTile)),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _applyHex(prefs, l),
                ),
              ),
              const SizedBox(width: 8),
              NButton(label: l.appearanceCustom, variant: NButtonVariant.secondary, onPressed: () => _applyHex(prefs, l)),
            ]),
            if (clamped)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(l.appearanceCustomClamped(_hexOf(t.accent)), style: t.text.caption()),
              ),
          ]),
        ),
        section(
          l.appearanceDensity,
          NSlidingPills(
            items: [NPillItem(label: l.appearanceCompact), NPillItem(label: l.appearanceComfortable), NPillItem(label: l.appearanceSpacious)],
            selectedIndex: p.density.index,
            onChanged: (i) => prefs.update((p) => p.copyWith(density: NDensity.values[i])),
          ),
        ),
        slider(l.appearanceTextScale, p.textScale, 0.85, 2.0, (v) => prefs.update((p) => p.copyWith(textScale: v))),
        slider(l.appearanceRadius, p.radiusScale, 0.5, 1.25, (v) => prefs.update((p) => p.copyWith(radiusScale: v))),
        slider(l.appearanceShadow, p.shadowIntensity, 0, 1.5, (v) => prefs.update((p) => p.copyWith(shadowIntensity: v))),
        slider(l.appearanceBlur, p.blur, 0, 1, (v) => prefs.update((p) => p.copyWith(blur: v))),
        slider(l.appearanceTransparency, p.transparency, 0, 1, (v) => prefs.update((p) => p.copyWith(transparency: v))),
        SizedBox(height: t.space(10)),
        Text(l.appearanceAccessibility, style: t.text.caption(weight: FontWeight.w600)),
        NSwitch(
          label: l.appearanceReducedMotion,
          description: l.appearanceReducedMotionHelp,
          value: p.reducedMotion,
          onChanged: (v) => prefs.update((p) => p.copyWith(reducedMotion: v)),
        ),
        NSwitch(
          label: l.appearanceReducedTransparency,
          description: l.appearanceReducedTransparencyHelp,
          value: p.reducedTransparency,
          onChanged: (v) => prefs.update((p) => p.copyWith(reducedTransparency: v)),
        ),
        NSwitch(
          label: l.appearanceHighContrast,
          description: l.appearanceHighContrastHelp,
          value: p.highContrast,
          onChanged: (v) => prefs.update((p) => p.copyWith(highContrast: v)),
        ),
        NSwitch(
          label: l.appearanceLargerText,
          description: l.appearanceLargerTextHelp,
          value: p.largerText,
          onChanged: (v) => prefs.update((p) => p.copyWith(largerText: v)),
        ),
        SizedBox(height: t.space(12)),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          NButton(
            label: l.appearanceReset,
            variant: NButtonVariant.secondary,
            onPressed: () {
              prefs.reset();
              _hex.clear();
              NToast.of(context).show(l.appearanceResetDone);
            },
          ),
          Text(l.appearanceSessionOnly, style: t.text.caption()),
        ]),
      ]),
    );

    final preview = NGlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.appearancePreview, style: t.text.caption(weight: FontWeight.w600)),
        SizedBox(height: t.space(12)),
        const NGreeting(lead: 'Welcome in,', bold: 'Priya', size: 26),
        SizedBox(height: t.space(12)),
        const NMeterRow(meters: [
          NMeter(label: 'Present', valueText: '42', fraction: 0.7, highlighted: true),
          NMeter(label: 'Leave', valueText: '3', fraction: 0.2),
        ]),
        SizedBox(height: t.space(12)),
        NSlidingPills(
          size: NPillSize.small,
          items: const [NPillItem(label: 'Today'), NPillItem(label: 'Week'), NPillItem(label: 'Month')],
          selectedIndex: 0,
          onChanged: (_) {},
        ),
        SizedBox(height: t.space(12)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          NButton(label: 'Check in', variant: NButtonVariant.accent, onPressed: () {}),
          const NStatusChip.status(label: 'Approved', tone: NTone.positive),
          const NStatusChip.health(NHealth.degraded),
        ]),
        SizedBox(height: t.space(18)),
        NDarkActionCard.check(
          title: 'My tasks',
          items: const [
            NActionItem(id: 'a', title: 'Upload PAN card', done: true),
            NActionItem(id: 'b', title: 'Read leave policy'),
          ],
          onToggle: (_, __) {},
        ),
      ]),
    );

    return PageFrame(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NEntrance(
          order: 0,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back',
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/account');
                  }
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  NGreeting(lead: l.appearanceLead, bold: l.appearanceBold),
                  const SizedBox(height: 6),
                  Text(l.appearanceSubtitle, style: t.text.body(color: t.muted)),
                ]),
              ),
            ],
          ),
        ),
        SizedBox(height: t.space(20)),
        if (bp.isWide || bp.isTablet)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: NEntrance(order: 1, child: controls)),
            SizedBox(width: t.gap),
            // The preview stays in view while the controls scroll on wide screens.
            Expanded(flex: 2, child: NEntrance(order: 2, child: preview)),
          ])
        else ...[
          NEntrance(order: 1, child: preview),
          SizedBox(height: t.gap),
          NEntrance(order: 2, child: controls),
        ],
      ]),
    );
  }

  static String _hexOf(Color c) {
    String two(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${two(c.r)}${two(c.g)}${two(c.b)}'.toUpperCase();
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.label, required this.onTap});
  final Color color;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: NMotion.durations(context).pillLabel,
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? t.ink : const Color(0x00000000), width: 2),
            ),
            child: DecoratedBox(decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
        ),
      ),
    );
  }
}
