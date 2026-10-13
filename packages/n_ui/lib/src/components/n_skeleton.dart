import 'package:flutter/widgets.dart';

import '../tokens/n_tokens.dart';

/// Loading placeholder. Static on purpose: the live dot is the only looping decoration in N UI.
/// Lists show skeletons, never spinners.
class NSkeleton extends StatelessWidget {
  const NSkeleton({super.key, this.width, this.height = 14, this.radius});
  final double? width;
  final double height;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return ExcludeSemantics(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: t.ink.withValues(alpha: t.isDark ? 0.10 : 0.07),
          borderRadius: BorderRadius.circular(radius ?? NTokens.radiusPill),
        ),
      ),
    );
  }
}

/// A few skeleton lines shaped like a list row. Announces "Loading" once for screen readers.
class NSkeletonList extends StatelessWidget {
  const NSkeletonList({super.key, this.rows = 4, this.semanticLabel = 'Loading'});
  final int rows;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Semantics(
      label: semanticLabel,
      liveRegion: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < rows; i++) ...[
          if (i > 0) SizedBox(height: t.space(14)),
          Row(children: [
            const NSkeleton(width: 28, height: 28),
            SizedBox(width: t.space(12)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FractionallySizedBox(widthFactor: i.isEven ? 0.7 : 0.55, child: const NSkeleton()),
                const SizedBox(height: 6),
                const FractionallySizedBox(widthFactor: 0.35, child: NSkeleton(height: 10)),
              ]),
            ),
          ]),
        ],
      ]),
    );
  }
}
