import 'package:flutter/widgets.dart';

import '../tokens/n_tokens.dart';
import 'n_breakpoint.dart';

/// A widget placed in an [NBentoGrid] with per-breakpoint column spans.
@immutable
class NBentoItem {
  const NBentoItem({required this.child, this.span = 1, this.tabletSpan = 1, this.smallTile = false});

  final Widget child;

  /// Columns on laptop and desktop (1 to 4).
  final int span;

  /// Columns on tablet (1 or 2).
  final int tabletSpan;

  /// Small KPI tiles pair up two per row on mobile.
  final bool smallTile;
}

/// Bento grid: 4 columns (1fr 1fr 1fr 1.12fr) on laptop and desktop, 2 on tablet, 1 on mobile
/// (small tiles in 2). Gap 14 (density-scaled). Items flow row by row; a row that cannot fit the
/// next item's span is closed and the item starts a new row.
///
/// Row spans (a widget covering two rows) are handled by the screen layout, which places the dark
/// action card in its own right-hand column on laptop and desktop.
class NBentoGrid extends StatelessWidget {
  const NBentoGrid({super.key, required this.items, this.wideColumns = 4});
  final List<NBentoItem> items;

  /// Columns on laptop and desktop. Use 3 when the screen's dark action card takes the 4th column.
  final int wideColumns;

  static const _wideWeights = [1.0, 1.0, 1.0, 1.12];

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final bp = NBreakpoint.of(context);
    final gap = t.gap;

    final rows = <List<(NBentoItem, int)>>[];
    final columns = bp.isWide ? wideColumns.clamp(1, 4) : bp.bentoColumns;
    var current = <(NBentoItem, int)>[];
    var used = 0;
    for (final item in items) {
      final span = switch (bp) {
        NBreakpoint.mobile => item.smallTile ? 1 : 2,
        NBreakpoint.tablet => item.tabletSpan.clamp(1, 2),
        _ => item.span.clamp(1, columns),
      };
      final cap = bp.isMobile ? 2 : columns; // mobile uses 2 half-columns so small tiles can pair
      if (used + span > cap && current.isNotEmpty) {
        rows.add(current);
        current = [];
        used = 0;
      }
      current.add((item, span));
      used += span;
    }
    if (current.isNotEmpty) rows.add(current);

    double weightFor(int start, int span) {
      if (!bp.isWide) return span.toDouble();
      var w = 0.0;
      for (var c = start; c < start + span && c < columns; c++) {
        // The 1.12fr column only exists in the full 4-column layout.
        w += columns == 4 ? _wideWeights[c] : 1.0;
      }
      return w;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) SizedBox(height: gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: () {
              final out = <Widget>[];
              var col = 0;
              for (var i = 0; i < rows[r].length; i++) {
                final (item, span) = rows[r][i];
                if (i > 0) out.add(SizedBox(width: gap));
                out.add(Expanded(flex: (weightFor(col, span) * 100).round(), child: item.child));
                col += span;
              }
              final cap = bp.isMobile ? 2 : columns;
              if (col < cap) {
                // Keep column widths stable when a row is not full.
                out.add(SizedBox(width: gap));
                out.add(Spacer(flex: (weightFor(col, cap - col) * 100).round()));
              }
              return out;
            }(),
          ),
        ],
      ],
    );
  }
}
