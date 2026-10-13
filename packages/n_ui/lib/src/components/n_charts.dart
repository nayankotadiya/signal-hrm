import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/n_tokens.dart';

/// One bar / segment of real data.
class NDatum {
  const NDatum(this.label, this.value, {this.color});
  final String label;
  final num value;
  final Color? color;
}

String _fmt(num v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

/// Vertical bars that grow in with a stagger. Every chart has a text alternative: the
/// semantics label lists each value, and [showValues] prints them.
class NBars extends StatelessWidget {
  const NBars({super.key, required this.data, this.height = 140, this.showValues = true, this.semanticLabel, this.highlightLast = false, this.formatter});
  final List<NDatum> data;
  final double height;
  final bool showValues;
  final bool highlightLast;
  final String? semanticLabel;
  final String Function(num)? formatter;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final f = formatter ?? _fmt;
    final maxV = data.fold<num>(0, (m, d) => math.max(m, d.value));
    final summary = data.map((d) => '${d.label}: ${f(d.value)}').join(', ');
    return Semantics(
      label: '${semanticLabel ?? 'Chart'}. $summary',
      excludeSemantics: true,
      child: SizedBox(
        height: height + 34,
        child: LayoutBuilder(builder: (context, c) {
          final n = math.max(1, data.length);
          final slot = c.maxWidth / n;
          final barW = math.min(34.0, slot * 0.6);
          final labelEvery = slot < 26 ? (26 / slot).ceil() : 1;
          return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < data.length; i++)
              SizedBox(
                width: slot,
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (showValues && slot >= 22) Text(f(data[i].value), style: t.text.caption(size: 10)),
                  const SizedBox(height: 2),
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: maxV == 0 ? 0 : data[i].value / maxV),
                    duration: t.durations.bars + t.durations.barStagger * i,
                    curve: NCurves.emphasized,
                    builder: (context, v, _) => Container(
                      width: barW,
                      height: math.max(2, (height - 16) * v),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(barW / 2.5),
                        color: data[i].color ?? (highlightLast && i == data.length - 1 ? t.accent : (t.isDark ? t.ink.withValues(alpha: 0.75) : t.ink.withValues(alpha: 0.82))),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 14,
                    child: i % labelEvery == 0 ? Text(data[i].label, maxLines: 1, overflow: TextOverflow.clip, style: t.text.caption(size: 10)) : null,
                  ),
                ]),
              ),
          ]);
        }),
      ),
    );
  }
}

/// Donut with legend. Segments with zero total show an empty ring and "No data".
class NDonut extends StatelessWidget {
  const NDonut({super.key, required this.data, this.size = 132, this.centerLabel, this.semanticLabel, this.formatter});
  final List<NDatum> data;
  final double size;
  final String? centerLabel;
  final String? semanticLabel;
  final String Function(num)? formatter;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final f = formatter ?? _fmt;
    final total = data.fold<num>(0, (s, d) => s + d.value);
    final colors = [t.ink, t.accent, t.teal, t.amber, t.lime, t.red, t.muted, t.yellow];
    final segs = [for (var i = 0; i < data.length; i++) (data[i], data[i].color ?? colors[i % colors.length])];
    return Semantics(
      label: '${semanticLabel ?? 'Breakdown'}. ${data.map((d) => '${d.label}: ${f(d.value)}').join(', ')}',
      excludeSemantics: true,
      child: Wrap(spacing: 18, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: size,
          height: size,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: t.durations.donut,
            curve: NCurves.emphasized,
            builder: (context, p, _) => CustomPaint(
              painter: _DonutPainter([for (final s in segs) (total == 0 ? 0.0 : s.$1.value / total, s.$2)], p, t.pillTrack),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(total == 0 ? '—' : f(total), style: t.text.bigNumber(size * 0.2)),
                  if (centerLabel != null) Text(centerLabel!, style: t.text.caption(size: 10)),
                ]),
              ),
            ),
          ),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (total == 0) Text('No data yet', style: t.text.caption()),
          for (final s in segs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: s.$2, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text('${s.$1.label}  ', style: t.text.caption(color: t.ink)),
                Text(f(s.$1.value), style: t.text.caption()),
              ]),
            ),
        ]),
      ]),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.segments, this.progress, this.track);
  final List<(double, Color)> segments;
  final double progress;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.14;
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    var start = -math.pi / 2;
    const gap = 0.03;
    for (final (frac, color) in segments) {
      if (frac <= 0) continue;
      final sweep = frac * math.pi * 2 * progress;
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(rect, start + gap / 2, math.max(0.001, sweep - gap), false, p);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.progress != progress || old.segments != segments || old.track != track;
}

/// Sparkline / small line chart with soft fill.
class NSparkline extends StatelessWidget {
  const NSparkline({super.key, required this.values, this.height = 56, this.color, this.semanticLabel});
  final List<num> values;
  final double height;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      label: '${semanticLabel ?? 'Trend'}: ${values.map(_fmt).join(', ')}',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: t.durations.sparkline,
          curve: NCurves.emphasized,
          builder: (context, p, _) => CustomPaint(painter: _SparkPainter(values, p, color ?? t.accent)),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.progress, this.color);
  final List<num> values;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maxV = values.fold<num>(0, (m, v) => math.max(m, v));
    final minV = values.fold<num>(maxV, (m, v) => math.min(m, v));
    final range = (maxV - minV) == 0 ? 1 : (maxV - minV);
    final pts = [
      for (var i = 0; i < values.length; i++) Offset(size.width * i / (values.length - 1), size.height - 4 - (size.height - 8) * ((values[i] - minV) / range)),
    ];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final mid = Offset((pts[i - 1].dx + pts[i].dx) / 2, (pts[i - 1].dy + pts[i].dy) / 2);
      path.quadraticBezierTo(pts[i - 1].dx, pts[i - 1].dy, mid.dx, mid.dy);
    }
    path.lineTo(pts.last.dx, pts.last.dy);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0)]).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.progress != progress || old.values != values || old.color != color;
}

/// Ring progress (attendance rate, completion). [fraction] null shows a dash.
class NRingProgress extends StatelessWidget {
  const NRingProgress({super.key, required this.fraction, required this.label, this.size = 96, this.color, this.centerText});
  final double? fraction;
  final String label;
  final double size;
  final Color? color;
  final String? centerText;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final f = (fraction ?? 0).clamp(0.0, 1.0);
    final text = centerText ?? (fraction == null ? '—' : '${(f * 100).round()}%');
    return Semantics(
      label: '$label: $text',
      excludeSemantics: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: size,
          height: size,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: f),
            duration: t.durations.ring,
            curve: NCurves.emphasized,
            builder: (context, v, _) => CustomPaint(
              painter: _DonutPainter([(v, color ?? t.accent)], 1, t.pillTrack),
              child: Center(child: Text(text, style: t.text.bigNumber(size * 0.24))),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: t.text.caption(), textAlign: TextAlign.center),
      ]),
    );
  }
}
