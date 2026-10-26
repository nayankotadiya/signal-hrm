import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../data/api.dart';
import '../platform/bridge.dart';
import 'async_view.dart';
import 'format.dart';

/// Monthly Attendance Heatmap, Punctuality Score & CSV Export Dashboard Widget.
class AttendanceHeatmapDashboard extends StatefulWidget {
  const AttendanceHeatmapDashboard({
    super.key,
    required this.calendarData,
    required this.selectedMonth,
    required this.onMonthChanged,
    this.onRequestCorrection,
  });

  final Json calendarData;
  final DateTime selectedMonth;
  final ValueChanged<DateTime> onMonthChanged;
  final VoidCallback? onRequestCorrection;

  @override
  State<AttendanceHeatmapDashboard> createState() => _AttendanceHeatmapDashboardState();
}

class _AttendanceHeatmapDashboardState extends State<AttendanceHeatmapDashboard> {
  String? _hoveredDay;

  Color _statusColor(String status, NTokens t) {
    switch (status) {
      case 'present':
        return t.green;
      case 'late':
        return t.amber;
      case 'half_day':
        return t.accent;
      case 'absent':
        return t.red;
      case 'on_leave':
        return const Color(0xFF8B5CF6);
      case 'holiday':
        return t.teal;
      case 'weekly_off':
        return t.muted.withValues(alpha: 0.25);
      case 'incomplete':
      case 'pending_correction':
        return t.amber;
      default:
        return t.isDark ? Colors.white10 : Colors.black12;
    }
  }

  void _exportCsv(List<Json> days, String monthKey) {
    final buffer = StringBuffer();
    buffer.writeln('Date,Day,Status,Day Count,Worked Time,Overtime,Notes');

    for (final d in days) {
      final dayStr = '${d['day'] ?? ''}';
      final status = '${d['status'] ?? 'none'}';
      final workedM = (d['workedMinutes'] as num?)?.toInt() ?? 0;
      final otM = (d['overtimeMinutes'] as num?)?.toInt() ?? 0;
      final holiday = d['holiday'] as String? ?? '';
      final dayCount = status == 'present' ? '1.0' : (status == 'half_day' ? '0.5' : '0.0');

      buffer.writeln(
        '$dayStr,'
        '${Fmt.date(dayStr)},'
        '${Fmt.label(status)},'
        '$dayCount,'
        '${workedM > 0 ? Fmt.minutes(workedM) : "-"},'
        '${otM > 0 ? Fmt.minutes(otM) : "-"},'
        '"$holiday"',
      );
    }

    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    final filename = 'attendance_timesheet_$monthKey.csv';
    bridge.downloadBytes(bytes, filename, 'text/csv');
    NToast.of(context).show('Time report exported: $filename');
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final days = jsonList(widget.calendarData['days']);
    final summary = jsonMap(widget.calendarData['summary']);
    final monthStr = '${widget.selectedMonth.year}-${widget.selectedMonth.month.toString().padLeft(2, '0')}';

    // Metrics calculations
    final presentDays = (summary['present'] as num?)?.toInt() ?? 0;
    final lateDays = (summary['late'] as num?)?.toInt() ?? 0;
    final halfDays = (summary['half_day'] as num?)?.toInt() ?? 0;
    final absentDays = (summary['absent'] as num?)?.toInt() ?? 0;
    final holidays = (summary['holiday'] as num?)?.toInt() ?? 0;
    final leaves = (summary['on_leave'] as num?)?.toInt() ?? 0;

    int totalLoggedMinutes = 0;
    for (final d in days) {
      totalLoggedMinutes += (d['workedMinutes'] as num?)?.toInt() ?? 0;
    }

    final workingDaysEligible = presentDays + lateDays + halfDays + absentDays;
    final punctualityScore = workingDaysEligible == 0
        ? 100
        : (((presentDays * 1.0 + halfDays * 0.5) / workingDaysEligible) * 100).round().clamp(0, 100);

    final scoreColor = punctualityScore >= 95
        ? t.green
        : punctualityScore >= 80
            ? t.teal
            : punctualityScore >= 65
                ? t.amber
                : t.red;

    final scoreLabel = punctualityScore >= 95
        ? 'Excellent Punctuality'
        : punctualityScore >= 80
            ? 'Highly Reliable'
            : punctualityScore >= 65
                ? 'Satisfactory'
                : 'Needs Improvement';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(color: t.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: Month Navigation & Actions
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded),
                    tooltip: 'Previous month',
                    onPressed: () {
                      final prev = DateTime(widget.selectedMonth.year, widget.selectedMonth.month - 1);
                      widget.onMonthChanged(prev);
                    },
                  ),
                  Text(
                    '${_monthName(widget.selectedMonth.month)} ${widget.selectedMonth.year}',
                    style: t.text.title().copyWith(fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded),
                    tooltip: 'Next month',
                    onPressed: () {
                      final next = DateTime(widget.selectedMonth.year, widget.selectedMonth.month + 1);
                      widget.onMonthChanged(next);
                    },
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  NButton(
                    label: 'Export CSV',
                    icon: Icons.file_download_outlined,
                    compact: true,
                    variant: NButtonVariant.secondary,
                    onPressed: () => _exportCsv(days, monthStr),
                  ),
                  if (widget.onRequestCorrection != null)
                    NButton(
                      label: 'Correction',
                      icon: Icons.edit_calendar_outlined,
                      compact: true,
                      variant: NButtonVariant.secondary,
                      onPressed: widget.onRequestCorrection!,
                    ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Top KPI Metrics & AI Punctuality Gauge
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              // Punctuality Score Banner
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: scoreColor.withValues(alpha: t.isDark ? 0.20 : 0.12),
                  borderRadius: BorderRadius.circular(t.radiusTile),
                  border: Border.all(color: scoreColor.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(
                            value: punctualityScore / 100.0,
                            strokeWidth: 4,
                            backgroundColor: scoreColor.withValues(alpha: 0.2),
                            valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
                          ),
                        ),
                        Text(
                          '$punctualityScore%',
                          style: t.text.caption(weight: FontWeight.w800).copyWith(fontSize: 11, color: scoreColor),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('AI Punctuality Score', style: t.text.caption(color: t.muted)),
                        Text(scoreLabel, style: t.text.body(weight: FontWeight.w700).copyWith(color: scoreColor)),
                      ],
                    ),
                  ],
                ),
              ),

              // Total Hours
              _KpiPill(
                icon: Icons.schedule_rounded,
                label: 'Total Logged',
                value: Fmt.minutes(totalLoggedMinutes),
                color: t.accent,
                tokens: t,
              ),

              // Present Days
              _KpiPill(
                icon: Icons.check_circle_outline_rounded,
                label: 'Present',
                value: '$presentDays days',
                color: t.green,
                tokens: t,
              ),

              // Late / Half-Day
              _KpiPill(
                icon: Icons.access_time_rounded,
                label: 'Late / Half-Day',
                value: '${lateDays + halfDays}',
                color: t.amber,
                tokens: t,
              ),

              // Leaves & Holidays
              _KpiPill(
                icon: Icons.beach_access_rounded,
                label: 'Off / Holidays',
                value: '${leaves + holidays}',
                color: t.teal,
                tokens: t,
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Monthly Heatmap Visualizer (Grid of Days)
          Text('Attendance Calendar & Intensity Matrix', style: t.text.caption(weight: FontWeight.w700, color: t.muted)),
          const SizedBox(height: 8),

          LayoutBuilder(builder: (context, constraints) {
            final colCount = constraints.maxWidth < 480 ? 7 : 7;
            final itemWidth = (constraints.maxWidth - (colCount - 1) * 6) / colCount;

            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in days)
                  _DayHeatmapCell(
                    dayData: d,
                    width: itemWidth.clamp(36.0, 72.0),
                    statusColor: _statusColor('${d['status']}', t),
                    tokens: t,
                    isHovered: _hoveredDay == d['day'],
                    onHover: (hover) => setState(() => _hoveredDay = hover ? '${d['day']}' : null),
                    onTap: () {
                      final key = '${d['day']}';
                      final status = '${d['status']}';
                      final worked = (d['workedMinutes'] as num?)?.toInt() ?? 0;
                      final holiday = d['holiday'] as String?;
                      final text = '${Fmt.date(key)}: ${Fmt.label(status)}${worked > 0 ? ' · ${Fmt.minutes(worked)}' : ''}${holiday != null ? ' · $holiday' : ''}';
                      NToast.of(context).show(text);
                    },
                  ),
              ],
            );
          }),

          const SizedBox(height: 16),

          // Legend
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _LegendItem(color: t.green, label: 'Present', tokens: t),
              _LegendItem(color: t.amber, label: 'Late', tokens: t),
              _LegendItem(color: t.accent, label: 'Half Day', tokens: t),
              _LegendItem(color: const Color(0xFF8B5CF6), label: 'Leave', tokens: t),
              _LegendItem(color: t.teal, label: 'Holiday', tokens: t),
              _LegendItem(color: t.red, label: 'Absent', tokens: t),
            ],
          ),
        ],
      ),
    );
  }

  static String _monthName(int m) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return names[(m - 1) % 12];
  }
}

class _KpiPill extends StatelessWidget {
  const _KpiPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.tokens,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final NTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(tokens.radiusTile),
        border: Border.all(color: tokens.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: tokens.text.caption(color: tokens.muted).copyWith(fontSize: 10)),
              Text(value, style: tokens.text.caption(weight: FontWeight.w700).copyWith(color: tokens.ink)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayHeatmapCell extends StatelessWidget {
  const _DayHeatmapCell({
    required this.dayData,
    required this.width,
    required this.statusColor,
    required this.tokens,
    required this.isHovered,
    required this.onHover,
    required this.onTap,
  });

  final Json dayData;
  final double width;
  final Color statusColor;
  final NTokens tokens;
  final bool isHovered;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dayStr = '${dayData['day'] ?? ''}';
    final parts = dayStr.split('-');
    final dayNum = parts.length == 3 ? parts[2] : dayStr;
    final workedM = (dayData['workedMinutes'] as num?)?.toInt() ?? 0;
    final status = '${dayData['status'] ?? 'none'}';
    final isOff = status == 'none' || status == 'weekly_off';

    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: width,
          height: 44,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isOff
                ? (tokens.isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.04))
                : statusColor.withValues(alpha: tokens.isDark ? 0.35 : 0.22),
            borderRadius: BorderRadius.circular(tokens.radiusTile),
            border: Border.all(
              color: isHovered
                  ? statusColor
                  : (isOff ? Colors.transparent : statusColor.withValues(alpha: 0.6)),
              width: isHovered ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                dayNum,
                style: tokens.text.caption(weight: FontWeight.w700).copyWith(
                      fontSize: 11,
                      color: isOff ? tokens.muted : (tokens.isDark ? Colors.white : tokens.ink),
                    ),
              ),
              if (workedM > 0)
                Text(
                  '${(workedM / 60).toStringAsFixed(1)}h',
                  style: tokens.text.caption(weight: FontWeight.w600).copyWith(
                        fontSize: 9,
                        color: statusColor,
                      ),
                )
              else if (dayData['holiday'] != null)
                Text(
                  'Holiday',
                  style: tokens.text.caption(weight: FontWeight.w600).copyWith(
                        fontSize: 8,
                        color: tokens.teal,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label, required this.tokens});
  final Color color;
  final String label;
  final NTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: tokens.text.caption(color: tokens.muted).copyWith(fontSize: 10)),
      ],
    );
  }
}
