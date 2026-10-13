import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

/// The Signal HRM mark: a gradient disc with a live waveform and rings that ripple outward.
/// [animated] false (or reduced motion) shows a still mark.
class SignalMark extends StatefulWidget {
  const SignalMark({super.key, this.size = 64, this.animated = true});
  final double size;
  final bool animated;

  @override
  State<SignalMark> createState() => _SignalMarkState();
}

class _SignalMarkState extends State<SignalMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run = widget.animated && !NMotion.reduced(context);
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final s = widget.size;
    return ExcludeSemantics(
      child: SizedBox(
        width: s,
        height: s,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final v = _c.value;
            return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
              if (_c.isAnimating)
                for (var i = 0; i < 3; i++) _ring((v + i / 3) % 1, i.isEven ? t.chartEnd : t.chartStart),
              Transform.scale(
                scale: _c.isAnimating ? 1 + 0.05 * math.sin(v * 2 * math.pi) : 1,
                child: Container(
                  width: s,
                  height: s,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [t.chartStart, t.chartEnd], begin: Alignment.topLeft, end: Alignment.bottomRight),
                    boxShadow: [BoxShadow(color: t.chartEnd.withValues(alpha: 0.35), blurRadius: s * 0.6, offset: Offset(0, s * 0.15))],
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (var i = 0; i < 5; i++) ...[
                      if (i > 0) SizedBox(width: s * 0.05),
                      _bar(i, v, s),
                    ],
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _ring(double p, Color color) {
    final eased = Curves.easeOutCubic.transform(p);
    return Transform.scale(
      scale: 1 + 1.4 * eased,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color.withValues(alpha: 0.7 * (1 - p)), width: 2)),
      ),
    );
  }

  Widget _bar(int i, double v, double s) {
    const heights = [0.19, 0.34, 0.47, 0.34, 0.19];
    // Each bar breathes on its own phase so the waveform looks alive.
    final wave = _c.isAnimating ? 0.55 + 0.45 * (0.5 + 0.5 * math.cos((v * 2.2 + i * 0.15) * 2 * math.pi)) : 1.0;
    return Container(
      width: s * 0.065,
      height: s * heights[i] * wave,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(s)),
    );
  }
}

/// "Signal HRM" with the gradient on "HRM".
class SignalWordmark extends StatelessWidget {
  const SignalWordmark({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final base = t.text.title(size: size).copyWith(color: t.ink);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('Signal ', style: base.copyWith(fontWeight: FontWeight.w300)),
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => LinearGradient(colors: [t.chartStart, t.chartEnd]).createShader(r),
          child: Text('HRM', style: base.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// Indeterminate progress shimmer under the splash.
class SignalLoadingBar extends StatefulWidget {
  const SignalLoadingBar({super.key, this.width = 160});
  final double width;

  @override
  State<SignalLoadingBar> createState() => _SignalLoadingBarState();
}

class _SignalLoadingBarState extends State<SignalLoadingBar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (NMotion.reduced(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final w = widget.width;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: w,
        height: 4,
        color: t.ink.withValues(alpha: 0.1),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final x = Curves.easeInOut.transform(_c.value) * w * 1.5 - w * 0.45;
            return Stack(children: [
              Positioned(
                left: _c.isAnimating ? x : w * 0.3,
                top: 0,
                bottom: 0,
                width: w * 0.4,
                child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: LinearGradient(colors: [t.chartStart, t.chartEnd]))),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
