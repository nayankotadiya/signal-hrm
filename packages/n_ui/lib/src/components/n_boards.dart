import 'package:flutter/material.dart';

import '../layout/n_breakpoint.dart';
import '../tokens/n_tokens.dart';
import 'n_sliding_pills.dart';

class NKanbanColumn<T> {
  const NKanbanColumn({required this.id, required this.title, required this.items, this.color});
  final String id;
  final String title;
  final List<T> items;
  final Color? color;
}

/// Kanban board. Drag a card to another column (pointer) or use the card's "Move to" menu
/// (keyboard and screen readers). On mobile, columns become a pill switcher with one column visible.
class NKanban<T extends Object> extends StatefulWidget {
  const NKanban({
    super.key,
    required this.columns,
    required this.itemId,
    required this.itemBuilder,
    required this.onMove,
    this.emptyText = 'Nothing here',
  });

  final List<NKanbanColumn<T>> columns;
  final String Function(T item) itemId;

  /// Builds a card. [moveMenu] is a ready-made "Move to" button to place in the card.
  final Widget Function(BuildContext context, T item, Widget moveMenu) itemBuilder;
  final void Function(T item, String toColumnId) onMove;
  final String emptyText;

  @override
  State<NKanban<T>> createState() => _NKanbanState<T>();
}

class _NKanbanState<T extends Object> extends State<NKanban<T>> {
  int _mobileColumn = 0;
  String? _hoverColumn;

  Widget _moveMenu(T item, String fromId) {
    return PopupMenuButton<String>(
      tooltip: 'Move to',
      icon: const Icon(Icons.more_horiz_rounded, size: 18),
      onSelected: (to) => widget.onMove(item, to),
      itemBuilder: (_) => [
        for (final c in widget.columns)
          if (c.id != fromId) PopupMenuItem(value: c.id, child: Text('Move to ${c.title}')),
      ],
    );
  }

  Widget _column(BuildContext context, NKanbanColumn<T> col, {required bool scrollable}) {
    final t = NTokens.of(context);
    final hovering = _hoverColumn == col.id;
    final list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final item in col.items)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: LongPressDraggable<T>(
            data: item,
            delay: const Duration(milliseconds: 150),
            feedback: Material(
              color: Colors.transparent,
              child: SizedBox(width: 260, child: Opacity(opacity: 0.9, child: widget.itemBuilder(context, item, const SizedBox.shrink()))),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: widget.itemBuilder(context, item, const SizedBox.shrink())),
            child: widget.itemBuilder(context, item, _moveMenu(item, col.id)),
          ),
        ),
      if (col.items.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 18), child: Text(widget.emptyText, textAlign: TextAlign.center, style: t.text.caption())),
    ]);
    return DragTarget<T>(
      onWillAcceptWithDetails: (d) {
        final from = widget.columns.firstWhere((c) => c.items.any((i) => widget.itemId(i) == widget.itemId(d.data)), orElse: () => col);
        if (from.id == col.id) return false;
        setState(() => _hoverColumn = col.id);
        return true;
      },
      onLeave: (_) => setState(() => _hoverColumn = null),
      onAcceptWithDetails: (d) {
        setState(() => _hoverColumn = null);
        widget.onMove(d.data, col.id);
      },
      builder: (context, _, __) => AnimatedContainer(
        duration: t.durations.hover,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: hovering ? t.accent.withValues(alpha: 0.10) : (t.isDark ? const Color(0xFF1B202D) : t.pillTrack),
          borderRadius: BorderRadius.circular(t.radiusCard),
          border: Border.all(color: hovering ? t.accent : (t.isDark ? const Color(0xFF2C3345) : Colors.transparent), width: 1.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(children: [
              if (col.color != null) ...[Container(width: 8, height: 8, decoration: BoxDecoration(color: col.color, shape: BoxShape.circle)), const SizedBox(width: 6)],
              Expanded(child: Semantics(header: true, child: Text(col.title, style: t.text.body(weight: FontWeight.w600)))),
              Text('${col.items.length}', style: t.text.caption()),
            ]),
          ),
          if (scrollable) Flexible(child: SingleChildScrollView(child: list)) else list,
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bp = NBreakpoint.of(context);
    if (bp.isMobile) {
      final i = _mobileColumn.clamp(0, widget.columns.length - 1);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        NSlidingPills(
          items: [for (final c in widget.columns) NPillItem(label: c.title, badgeCount: c.items.length)],
          selectedIndex: i,
          onChanged: (v) => setState(() => _mobileColumn = v),
          semanticLabel: 'Board columns',
        ),
        const SizedBox(height: 10),
        _column(context, widget.columns[i], scrollable: false),
      ]);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final c in widget.columns)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SizedBox(width: bp == NBreakpoint.desktop ? 300 : 270, child: _column(context, c, scrollable: false)),
          ),
      ]),
    );
  }
}

/// A coloured marker shown on a calendar day.
class NCalendarMark {
  const NCalendarMark({required this.color, this.label});
  final Color color;
  final String? label;
}

/// Month grid. [marks] is keyed by YYYY-MM-DD. Week starts on [weekStart] (1 = Monday, 7 = Sunday).
class NMonthCalendar extends StatelessWidget {
  const NMonthCalendar({
    super.key,
    required this.month,
    required this.onMonthChanged,
    this.marks = const {},
    this.onDayTap,
    this.weekStart = 1,
    this.selectedDay,
  });

  final DateTime month;
  final ValueChanged<DateTime> onMonthChanged;
  final Map<String, List<NCalendarMark>> marks;
  final ValueChanged<DateTime>? onDayTap;
  final int weekStart;
  final DateTime? selectedDay;

  static const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final first = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final lead = (first.weekday - weekStart + 7) % 7;
    final today = DateTime.now();
    String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final cells = <Widget>[
      for (var i = 0; i < 7; i++)
        Center(child: Text(_wd[(weekStart - 1 + i) % 7], style: t.text.caption(weight: FontWeight.w500))),
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var d = 1; d <= daysInMonth; d++)
        Builder(builder: (context) {
          final date = DateTime(month.year, month.month, d);
          final m = marks[key(date)] ?? const [];
          final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
          final selected = selectedDay != null && key(selectedDay!) == key(date);
          return Semantics(
            button: onDayTap != null,
            label: '$d ${_months[month.month - 1]}${m.isEmpty ? '' : ', ${m.map((x) => x.label ?? '').where((s) => s.isNotEmpty).join(', ')}'}',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onDayTap == null ? null : () => onDayTap!(date),
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: selected ? t.pillActive : (isToday ? t.accent.withValues(alpha: 0.14) : Colors.transparent),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('$d', style: t.text.body(color: selected ? t.pillActiveText : t.ink, weight: isToday ? FontWeight.w600 : FontWeight.w400)),
                  const SizedBox(height: 3),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (final mk in m.take(3))
                      Container(width: 5, height: 5, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(color: mk.color, shape: BoxShape.circle)),
                  ]),
                ]),
              ),
            ),
          );
        }),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        IconButton(tooltip: 'Previous month', icon: const Icon(Icons.chevron_left_rounded), onPressed: () => onMonthChanged(DateTime(month.year, month.month - 1))),
        Expanded(child: Center(child: Text('${_months[month.month - 1]} ${month.year}', style: t.text.title(size: 15)))),
        IconButton(tooltip: 'Next month', icon: const Icon(Icons.chevron_right_rounded), onPressed: () => onMonthChanged(DateTime(month.year, month.month + 1))),
      ]),
      const SizedBox(height: 6),
      GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.05,
        children: cells,
      ),
    ]);
  }
}
