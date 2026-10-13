import 'package:flutter/material.dart';

import '../layout/n_breakpoint.dart';
import '../tokens/n_tokens.dart';

/// Initials avatar (photos are served through the API's permission-checked file endpoint and can be
/// passed as [image]).
class NAvatar extends StatelessWidget {
  const NAvatar({super.key, required this.name, this.size = 36, this.image});
  final String name;
  final double size;
  final ImageProvider? image;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final palette = [t.lime, t.yellow, t.teal, t.accent.withValues(alpha: 0.35), t.amber.withValues(alpha: 0.5)];
    final bg = palette[name.codeUnits.fold<int>(0, (a, b) => a + b) % palette.length];
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          image: image == null ? null : DecorationImage(image: image!, fit: BoxFit.cover),
        ),
        alignment: Alignment.center,
        child: image == null ? Text(initials(name), style: t.text.caption(color: const Color(0xFF1A1A1E), weight: FontWeight.w600, size: size * 0.34)) : null,
      ),
    );
  }
}

/// A list row: leading, title, subtitle, trailing. 44px+ hit target, keyboard-focusable when tappable.
class NListRow extends StatefulWidget {
  const NListRow({super.key, required this.title, this.subtitle, this.leading, this.trailing, this.onTap, this.dense = false, this.semanticLabel});
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool dense;
  final String? semanticLabel;

  @override
  State<NListRow> createState() => _NListRowState();
}

class _NListRowState extends State<NListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final row = AnimatedContainer(
      duration: t.durations.hover,
      constraints: BoxConstraints(minHeight: widget.dense ? 44 : 56),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: widget.dense ? 6 : 10),
      decoration: BoxDecoration(
        color: _hover && widget.onTap != null ? t.pillTrack : Colors.transparent,
        borderRadius: BorderRadius.circular(t.radiusTile),
      ),
      child: LayoutBuilder(builder: (context, box) => Row(children: [
        if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.text.body(weight: FontWeight.w500)),
            if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(widget.subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.text.caption())),
          ]),
        ),
        if (widget.trailing != null) ...[
          const SizedBox(width: 10),
          // Capped so large text or a narrow screen can't push the trailing widget off the row.
          ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth.isFinite ? box.maxWidth * 0.45 : double.infinity), child: widget.trailing!),
        ],
      ])),
    );
    if (widget.onTap == null) return Semantics(label: widget.semanticLabel, child: row);
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radiusTile),
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hover = h),
        focusColor: t.focusRing.withValues(alpha: 0.15),
        child: row,
      ),
    );
  }
}

class NColumn {
  const NColumn(this.label, {this.flex = 2, this.numeric = false, this.hideOnTablet = false});
  final String label;
  final int flex;
  final bool numeric;
  final bool hideOnTablet;
}

/// Responsive table. Laptop/desktop: header + aligned columns. Tablet: hides low-priority columns.
/// Mobile: each row becomes a card of label/value pairs (the first cell is the card title).
class NDataTable extends StatelessWidget {
  const NDataTable({super.key, required this.columns, required this.rows, this.onTapRow, this.semanticLabel});
  final List<NColumn> columns;
  final List<List<Widget>> rows;
  final ValueChanged<int>? onTapRow;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final bp = NBreakpoint.of(context);
    if (bp.isMobile) {
      return Semantics(
        label: semanticLabel,
        container: true,
        child: Column(children: [
          for (var r = 0; r < rows.length; r++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.card,
                borderRadius: BorderRadius.circular(t.radiusTile),
                child: InkWell(
                  borderRadius: BorderRadius.circular(t.radiusTile),
                  onTap: onTapRow == null ? null : () => onTapRow!(r),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      DefaultTextStyle.merge(style: t.text.body(weight: FontWeight.w600), child: rows[r][0]),
                      for (var c = 1; c < columns.length && c < rows[r].length; c++)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(width: 110, child: Text(columns[c].label, style: t.text.caption())),
                            Expanded(child: DefaultTextStyle.merge(style: t.text.body(), child: rows[r][c])),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
    }
    final visible = [for (var i = 0; i < columns.length; i++) if (!(bp.isTablet && columns[i].hideOnTablet)) i];
    Widget cell(int c, Widget w) => Expanded(
          flex: columns[c].flex,
          child: Align(alignment: columns[c].numeric ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart, child: w),
        );
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(children: [
            for (final c in visible) cell(c, Text(columns[c].label, style: t.text.caption(weight: FontWeight.w500))),
          ]),
        ),
        Divider(height: 1, color: t.divider),
        for (var r = 0; r < rows.length; r++)
          InkWell(
            onTap: onTapRow == null ? null : () => onTapRow!(r),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.divider))),
              child: DefaultTextStyle.merge(
                style: t.text.body(),
                child: Row(children: [
                  for (final c in visible)
                    if (c < rows[r].length) cell(c, Padding(padding: const EdgeInsets.only(right: 8), child: rows[r][c])),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Small horizontal progress meter with label (leave balances, completion).
class NProgressBar extends StatelessWidget {
  const NProgressBar({super.key, required this.fraction, this.color, this.height = 8, this.semanticLabel});
  final double fraction;
  final Color? color;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final f = fraction.isNaN ? 0.0 : fraction.clamp(0.0, 1.0);
    return Semantics(
      label: semanticLabel,
      value: '${(f * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: t.pillTrack)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: f),
              duration: t.durations.meterFill,
              curve: NCurves.emphasized,
              builder: (context, v, _) => FractionallySizedBox(widthFactor: v, child: ColoredBox(color: color ?? t.ink)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Simple vertical timeline (approval history, employee history, activity).
class NTimelineEntry {
  const NTimelineEntry({required this.title, this.subtitle, this.time, this.color, this.icon});
  final String title;
  final String? subtitle;
  final String? time;
  final Color? color;
  final IconData? icon;
}

class NTimeline extends StatelessWidget {
  const NTimeline({super.key, required this.entries});
  final List<NTimelineEntry> entries;

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < entries.length; i++)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 28,
              child: Column(children: [
                Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: (entries[i].color ?? t.muted).withValues(alpha: 0.18)),
                  alignment: Alignment.center,
                  child: Icon(entries[i].icon ?? Icons.circle, size: entries[i].icon == null ? 8 : 13, color: entries[i].color ?? t.muted),
                ),
                if (i < entries.length - 1) Expanded(child: Container(width: 1.5, color: t.divider)),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(entries[i].title, style: t.text.body(weight: FontWeight.w500)),
                  if (entries[i].subtitle != null) Text(entries[i].subtitle!, style: t.text.body(color: t.muted)),
                  if (entries[i].time != null) Text(entries[i].time!, style: t.text.caption()),
                ]),
              ),
            ),
          ]),
        ),
    ]);
  }
}
