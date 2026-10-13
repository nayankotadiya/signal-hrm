import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import '../layout/n_breakpoint.dart';
import '../motion/n_motion.dart';
import '../tokens/n_tokens.dart';

/// Fixed page gradient with the soft outer frame (frame hidden on mobile to save space).
class NPageBackground extends StatelessWidget {
  const NPageBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final mobile = NBreakpoint.of(context).isMobile;
    return DecoratedBox(
      decoration: BoxDecoration(gradient: t.pageGradient),
      child: mobile
          ? child
          : Padding(
              padding: const EdgeInsets.all(10),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(color: t.frameColor, width: t.frameWidth),
                  borderRadius: BorderRadius.circular(t.radiusFrame),
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(t.radiusFrame), child: child),
              ),
            ),
    );
  }
}

/// The pastel panel that holds a screen's content.
class NPanel extends StatelessWidget {
  const NPanel({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final mobile = NBreakpoint.of(context).isMobile;
    return Container(
      padding: padding ?? EdgeInsets.all(t.panelPadding(mobile: mobile)),
      decoration: BoxDecoration(gradient: t.panelGradient, borderRadius: BorderRadius.circular(t.radiusPanel)),
      child: child,
    );
  }
}

/// Glass card: translucent white (or dark) surface, radius 22, soft shadow, optional blur.
/// Set [blur] false inside long scrolling lists. [onTap] adds the hover lift (pointer devices only).
class NGlassCard extends StatefulWidget {
  const NGlassCard({
    super.key,
    required this.child,
    this.padding,
    this.blur = true,
    this.onTap,
    this.semanticLabel,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final bool blur;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// Override the surface (e.g. an accent-tinted tile). Defaults to the token card color.
  final Color? color;

  @override
  State<NGlassCard> createState() => _NGlassCardState();
}

class _NGlassCardState extends State<NGlassCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final radius = BorderRadius.circular(t.radiusCard);
    final interactive = widget.onTap != null;
    final lift = interactive && _hover && !NMotion.reduced(context);

    Widget surface = Container(
      padding: widget.padding ?? EdgeInsets.all(t.cardPadding),
      decoration: BoxDecoration(
        color: widget.color ?? t.card,
        borderRadius: radius,
        border: t.cardBorder.a == 0 ? null : Border.all(color: t.cardBorder),
      ),
      child: widget.child,
    );

    if (widget.blur && t.blurSigma > 0) {
      surface = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: t.blurSigma, sigmaY: t.blurSigma), child: surface),
      );
    }

    Widget card = AnimatedContainer(
      duration: t.durations.hover,
      curve: NCurves.emphasized,
      transform: Matrix4.translationValues(0, lift ? -3 : 0, 0),
      decoration: BoxDecoration(borderRadius: radius, boxShadow: t.cardShadow),
      child: surface,
    );

    if (interactive) {
      card = MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(onTap: widget.onTap, behavior: HitTestBehavior.opaque, child: card),
      );
    }

    return Semantics(
      container: true,
      button: interactive,
      label: widget.semanticLabel,
      child: card,
    );
  }
}

/// The only looping decorative animation in N UI: a soft pulsing "live" dot. Static under reduced motion.
class NLiveDot extends StatefulWidget {
  const NLiveDot({super.key, this.color, this.size = 8});
  final Color? color;
  final double size;

  @override
  State<NLiveDot> createState() => _NLiveDotState();
}

class _NLiveDotState extends State<NLiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (NMotion.reduced(context)) {
      _c.stop();
      _c.value = 0;
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
    final color = widget.color ?? NTokens.of(context).green;
    final s = widget.size;
    return SizedBox(
      width: s * 2.2,
      height: s * 2.2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final v = Curves.easeOut.transform(_c.value);
          return Stack(alignment: Alignment.center, children: [
            Container(
              width: s * (1 + 1.2 * v),
              height: s * (1 + 1.2 * v),
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.35 * (1 - v))),
            ),
            Container(width: s, height: s, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          ]);
        },
      ),
    );
  }
}
