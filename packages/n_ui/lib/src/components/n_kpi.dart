import 'package:flutter/widgets.dart';

import '../layout/n_breakpoint.dart';
import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';

/// Formats a KPI value for display. Default: integers with thin grouping, one decimal otherwise.
typedef NKpiFormatter = String Function(num value);

String _defaultFormat(num v) {
  final isInt = v == v.roundToDouble();
  final s = isInt ? v.round().toString() : v.toStringAsFixed(1);
  // Group thousands: 12500 -> 12,500
  final parts = s.split('.');
  final digits = parts[0].replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  return parts.length > 1 ? '$digits.${parts[1]}' : digits;
}

/// Big light number with a small label that counts up (1.1s, ease-out cubic) from its previous value.
/// Pass `value: null` while loading or when the source is unavailable: it shows a dash, never a fake number.
class NKpi extends StatefulWidget {
  const NKpi({
    super.key,
    required this.label,
    required this.value,
    this.formatter,
    this.suffix,
    this.size = 44,
    this.semanticsValue,
  });

  final String label;
  final num? value;
  final NKpiFormatter? formatter;
  final String? suffix;
  final double size;

  /// Spoken value override, e.g. "12 people".
  final String? semanticsValue;

  @override
  State<NKpi> createState() => _NKpiState();
}

class _NKpiState extends State<NKpi> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  late final CurvedAnimation _curve = CurvedAnimation(parent: _c, curve: NCurves.counter);
  num _from = 0;
  num _to = 0;

  @override
  void initState() {
    super.initState();
    _to = widget.value ?? 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.status == AnimationStatus.dismissed && _c.value == 0) _start(from: 0);
  }

  @override
  void didUpdateWidget(NKpi old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && widget.value != null) {
      _start(from: _displayed);
    }
  }

  num get _displayed => _from + (_to - _from) * _curve.value;

  void _start({required num from}) {
    _from = from;
    _to = widget.value ?? 0;
    final d = NMotion.durations(context).counter;
    if (d == Duration.zero) {
      _c.value = 1;
    } else {
      _c.duration = d;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final fmt = widget.formatter ?? _defaultFormat;
    final finalText = widget.value == null ? '–' : '${fmt(widget.value!)}${widget.suffix ?? ''}';
    final size = NBreakpoint.of(context).isMobile ? widget.size * 0.78 : widget.size;
    return Semantics(
      label: widget.label,
      value: widget.semanticsValue ?? (widget.value == null ? 'not available' : finalText),
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _curve,
            builder: (context, _) {
              String text;
              if (widget.value == null) {
                text = '–';
              } else {
                final v = _displayed;
                // While counting, show whole numbers for integer targets so digits don't flicker.
                final shown = widget.value is int ? v.round() : v;
                text = '${fmt(shown)}${widget.suffix ?? ''}';
              }
              return Text(text, style: t.text.bigNumber(size), maxLines: 1);
            },
          ),
          const SizedBox(height: 4),
          Text(widget.label, style: t.text.caption(), maxLines: 2),
        ],
      ),
    );
  }
}

/// One meter in the hero row: label above, value inside a pill. Exactly one meter per row is
/// [highlighted]; its lime fill grows to [fraction] over 1.4s.
@immutable
class NMeter {
  const NMeter({required this.label, required this.valueText, required this.fraction, this.highlighted = false, this.weight});

  final String label;
  final String valueText;

  /// 0 to 1 share used for the fill (highlighted meter) and default width.
  final double fraction;
  final bool highlighted;

  /// Width weight inside the row. Defaults to [fraction] (proportional meters).
  final double? weight;
}

class NMeterPill extends StatelessWidget {
  const NMeterPill({super.key, required this.meter});
  final NMeter meter;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final d = NMotion.durations(context);
    final fraction = meter.fraction.clamp(0.0, 1.0);
    return Semantics(
      label: meter.label,
      value: meter.valueText,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(meter.label, style: t.text.caption(), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Container(
            // Min height, not fixed: the pill grows with text scale (up to 200%) instead of clipping.
            constraints: const BoxConstraints(minHeight: 34),
            decoration: BoxDecoration(
              color: meter.highlighted ? t.pillTrack : t.ink.withValues(alpha: t.isDark ? 0.14 : 0.85),
              borderRadius: BorderRadius.circular(NTokens.radiusPill),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              if (meter.highlighted)
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: fraction),
                    duration: d.meterFill,
                    curve: NCurves.emphasized,
                    builder: (context, v, _) => FractionallySizedBox(
                      widthFactor: v.clamp(0.0, 1.0),
                      alignment: AlignmentDirectional.centerStart,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: t.lime, borderRadius: BorderRadius.circular(NTokens.radiusPill)),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 14, end: 10, top: 7, bottom: 7),
                child: Text(
                  meter.valueText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.text.body(
                    weight: FontWeight.w600,
                    color: meter.highlighted ? const Color(0xFF0F1115) : (t.isDark ? t.ink : const Color(0xFFFFFFFF)),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Four proportional meters. Mobile wraps them into two columns.
class NMeterRow extends StatelessWidget {
  const NMeterRow({super.key, required this.meters});
  final List<NMeter> meters;

  @override
  Widget build(BuildContext context) {
    assert(meters.length <= 4, 'The hero row shows at most four meters');
    assert(meters.where((m) => m.highlighted).length <= 1, 'Exactly one meter may be highlighted');
    final t = NTokens.of(context);
    if (NBreakpoint.of(context).isMobile) {
      return LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - t.gap) / 2;
        return Wrap(
          spacing: t.gap,
          runSpacing: t.space(12),
          children: [for (final m in meters) SizedBox(width: w, child: NMeterPill(meter: m))],
        );
      });
    }
    return Row(children: [
      for (var i = 0; i < meters.length; i++) ...[
        if (i > 0) SizedBox(width: t.space(10)),
        Expanded(
          flex: (((meters[i].weight ?? meters[i].fraction).clamp(0.12, 1.0)) * 100).round(),
          child: NMeterPill(meter: meters[i]),
        ),
      ],
    ]);
  }
}

/// Greeting text with exactly one bold word: `NGreeting(lead: 'Welcome in,', bold: 'Priya')`.
class NGreeting extends StatelessWidget {
  const NGreeting({super.key, required this.lead, required this.bold, this.trail = '', this.size});
  final String lead;
  final String bold;
  final String trail;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final s = size ?? (NBreakpoint.of(context).isMobile ? 28.0 : 38.0);
    return Semantics(
      header: true,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(text: '$lead ', style: t.text.heading(size: s)),
          TextSpan(text: bold, style: t.text.headingBold(size: s)),
          if (trail.isNotEmpty) TextSpan(text: ' $trail', style: t.text.heading(size: s)),
        ]),
      ),
    );
  }
}

/// Hero row: greeting, four meters and three count-up KPIs.
/// Wide: greeting + meters on the left, KPIs on the right. Mobile: stacked, meters in two columns,
/// KPIs in one row.
class NHeroRow extends StatelessWidget {
  const NHeroRow({super.key, required this.greeting, required this.meters, required this.kpis});

  final Widget greeting;
  final List<NMeter> meters;
  final List<NKpi> kpis;

  @override
  Widget build(BuildContext context) {
    assert(kpis.length <= 3, 'The hero row shows at most three KPIs');
    final t = NTokens.of(context);
    final bp = NBreakpoint.of(context);
    // Wrap, not Row: with long labels, narrow widths or 200% text the KPIs flow onto a second
    // line instead of overflowing.
    final kpiRow = Wrap(
      alignment: bp.isMobile ? WrapAlignment.spaceBetween : WrapAlignment.end,
      spacing: bp.isMobile ? t.space(16) : t.space(28),
      runSpacing: t.space(12),
      children: kpis,
    );
    if (bp.isMobile || bp.isTablet) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        greeting,
        SizedBox(height: t.space(18)),
        NMeterRow(meters: meters),
        SizedBox(height: t.space(18)),
        kpiRow,
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        flex: 3,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          greeting,
          SizedBox(height: t.space(20)),
          NMeterRow(meters: meters),
        ]),
      ),
      SizedBox(width: t.space(32)),
      Flexible(flex: 2, child: kpiRow),
    ]);
  }
}
