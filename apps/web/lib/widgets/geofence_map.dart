import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../platform/bridge.dart';

/// Interactive Geofence Radar & Map visualizer.
/// Shows office boundary circle, live user GPS position pin, distance vector,
/// radar sonar sweep, and interactive zoom/refresh controls.
class GeofenceRadarMap extends StatefulWidget {
  const GeofenceRadarMap({
    super.key,
    required this.officeLat,
    required this.officeLng,
    required this.officeRadiusMeters,
    this.officeName = 'Office',
    this.officeAddress,
    this.userLat,
    this.userLng,
    this.accuracyMeters,
    this.isInside,
    this.isRefreshing = false,
    this.onRefresh,
    this.height = 240,
  });

  final double officeLat;
  final double officeLng;
  final double officeRadiusMeters;
  final String officeName;
  final String? officeAddress;

  final double? userLat;
  final double? userLng;
  final double? accuracyMeters;
  final bool? isInside;

  final bool isRefreshing;
  final VoidCallback? onRefresh;
  final double height;

  @override
  State<GeofenceRadarMap> createState() => _GeofenceRadarMapState();
}

class _GeofenceRadarMapState extends State<GeofenceRadarMap> with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  double _zoomMultiplier = 1.0;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  double _calculateDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * (math.pi / 180.0);
    final dLon = (lon2 - lon1) * (math.pi / 180.0);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * (math.pi / 180.0)) *
            math.cos(lat2 * (math.pi / 180.0)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  @override
  Widget build(BuildContext context) {
    final t = NTokens.of(context);
    final hasUserFix = widget.userLat != null && widget.userLng != null;

    final distanceMeters = hasUserFix
        ? _calculateDistanceMeters(
            widget.officeLat,
            widget.officeLng,
            widget.userLat!,
            widget.userLng!,
          )
        : null;

    final isInside = widget.isInside ?? (distanceMeters != null ? distanceMeters <= widget.officeRadiusMeters : null);

    return Container(
      height: widget.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(
          color: (isInside == true ? t.green : (isInside == false ? t.amber : t.cardBorder)).withValues(alpha: 0.5),
          width: 1.5,
        ),
      ),
      child: Stack(
        children: [
          // 1. Radar & Vector CustomPainter Canvas
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _animCtrl,
              builder: (context, _) {
                return CustomPaint(
                  painter: _RadarMapPainter(
                    officeRadiusMeters: widget.officeRadiusMeters,
                    userDistanceMeters: distanceMeters,
                    officeLat: widget.officeLat,
                    officeLng: widget.officeLng,
                    userLat: widget.userLat,
                    userLng: widget.userLng,
                    isInside: isInside,
                    animationValue: _animCtrl.value,
                    zoomMultiplier: _zoomMultiplier,
                    isDark: t.isDark,
                    accentColor: t.accent,
                    greenColor: t.green,
                    amberColor: t.amber,
                  ),
                );
              },
            ),
          ),

          // 2. Top-Left: Geofence Status Badge
          Positioned(
            top: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (isInside == true ? t.green : (isInside == false ? t.amber : t.card)).withValues(alpha: t.isDark ? 0.35 : 0.9),
                borderRadius: BorderRadius.circular(NTokens.radiusPill),
                border: Border.all(
                  color: isInside == true ? t.green : (isInside == false ? t.amber : t.cardBorder),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isInside == true ? Icons.check_circle_rounded : (isInside == false ? Icons.warning_rounded : Icons.radar_rounded),
                    size: 13,
                    color: isInside == true ? (t.isDark ? Colors.greenAccent : t.green) : (isInside == false ? (t.isDark ? Colors.orangeAccent : t.amber) : t.ink),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    isInside == true
                        ? 'Inside Geofence (${distanceMeters?.round() ?? 0}m)'
                        : (isInside == false
                            ? 'Outside Geofence (${distanceMeters?.round() ?? 0}m)'
                            : 'Radar Geofence (${widget.officeRadiusMeters.round()}m)'),
                    style: t.text.caption(weight: FontWeight.w700).copyWith(
                          fontSize: 10.5,
                          color: isInside == true ? (t.isDark ? Colors.greenAccent : t.green) : (isInside == false ? (t.isDark ? Colors.orangeAccent : t.amber) : t.ink),
                        ),
                  ),
                ],
              ),
            ),
          ),

          // 3. Top-Right: Zoom & Compass Controls
          Positioned(
            top: 10,
            right: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Compass Rose
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: t.card.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                    border: Border.all(color: t.divider),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('N', style: t.text.caption(weight: FontWeight.w800).copyWith(fontSize: 10, color: t.accent)),
                      const Icon(Icons.navigation_rounded, size: 12, color: Colors.redAccent),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // Zoom Out
                InkWell(
                  onTap: () {
                    if (_zoomMultiplier > 0.5) {
                      setState(() => _zoomMultiplier = (_zoomMultiplier / 1.4).clamp(0.4, 3.0));
                    }
                  },
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: t.card.withValues(alpha: 0.85),
                      shape: BoxShape.circle,
                      border: Border.all(color: t.divider),
                    ),
                    child: const Icon(Icons.remove, size: 13),
                  ),
                ),
                const SizedBox(width: 4),
                // Zoom In
                InkWell(
                  onTap: () {
                    if (_zoomMultiplier < 2.8) {
                      setState(() => _zoomMultiplier = (_zoomMultiplier * 1.4).clamp(0.4, 3.0));
                    }
                  },
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: t.card.withValues(alpha: 0.85),
                      shape: BoxShape.circle,
                      border: Border.all(color: t.divider),
                    ),
                    child: const Icon(Icons.add, size: 13),
                  ),
                ),
              ],
            ),
          ),

          // 4. Bottom-Left: Office and Accuracy details
          Positioned(
            bottom: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: t.card.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(t.radiusTile),
                border: Border.all(color: t.divider),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.business_rounded, size: 13, color: t.accent),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.officeName} (Radius: ${widget.officeRadiusMeters.round()}m)',
                    style: t.text.caption(weight: FontWeight.w600).copyWith(fontSize: 10, color: t.ink),
                  ),
                  if (widget.accuracyMeters != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '· ±${widget.accuracyMeters!.round()}m GPS',
                      style: t.text.caption().copyWith(fontSize: 10, color: t.muted),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // 5. Bottom-Right: Map External Link & Refresh
          Positioned(
            bottom: 10,
            right: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onRefresh != null)
                  InkWell(
                    onTap: widget.isRefreshing ? null : widget.onRefresh,
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                      decoration: BoxDecoration(
                        color: t.card.withValues(alpha: 0.88),
                        borderRadius: BorderRadius.circular(NTokens.radiusPill),
                        border: Border.all(color: t.divider),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.isRefreshing)
                            SizedBox(
                              width: 11,
                              height: 11,
                              child: CircularProgressIndicator(strokeWidth: 1.8, color: t.accent),
                            )
                          else
                            Icon(Icons.refresh_rounded, size: 12, color: t.accent),
                          const SizedBox(width: 4),
                          Text(
                            widget.isRefreshing ? 'Locating...' : 'Refresh GPS',
                            style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.accent, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () {
                    final lat = widget.userLat ?? widget.officeLat;
                    final lng = widget.userLng ?? widget.officeLng;
                    bridge.openUrl('https://www.google.com/maps?q=$lat,$lng');
                  },
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.card.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      border: Border.all(color: t.divider),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.map_outlined, size: 12, color: t.accent),
                        const SizedBox(width: 3),
                        Text(
                          'Google Maps',
                          style: t.text.caption(weight: FontWeight.w700).copyWith(color: t.accent, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarMapPainter extends CustomPainter {
  _RadarMapPainter({
    required this.officeRadiusMeters,
    required this.userDistanceMeters,
    required this.officeLat,
    required this.officeLng,
    this.userLat,
    this.userLng,
    this.isInside,
    required this.animationValue,
    required this.zoomMultiplier,
    required this.isDark,
    required this.accentColor,
    required this.greenColor,
    required this.amberColor,
  });

  final double officeRadiusMeters;
  final double? userDistanceMeters;
  final double officeLat;
  final double officeLng;
  final double? userLat;
  final double? userLng;
  final bool? isInside;
  final double animationValue;
  final double zoomMultiplier;

  final bool isDark;
  final Color accentColor;
  final Color greenColor;
  final Color amberColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // Calculate meter-to-pixel ratio
    // Target: office geofence circle covers roughly 35% of the height at zoom 1.0
    final targetRadiusPx = (size.height * 0.35) * zoomMultiplier;
    final scale = targetRadiusPx / officeRadiusMeters;

    final gridLineColor = isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06);
    final gridPaint = Paint()
      ..color = gridLineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // 1. Concentric Distance Grid Rings
    final ringSteps = [
      officeRadiusMeters * 0.5,
      officeRadiusMeters,
      officeRadiusMeters * 1.5,
      officeRadiusMeters * 2.0,
    ];

    for (final rMeters in ringSteps) {
      final rPx = rMeters * scale;
      canvas.drawCircle(center, rPx, gridPaint);
    }

    // 2. Crosshair Grid Lines
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), gridPaint);
    canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), gridPaint);

    // 3. Radar Sonar Sweep Wave (Animated)
    final sweepRadius = (animationValue * officeRadiusMeters * 2.2) * scale;
    final sweepPaint = Paint()
      ..color = accentColor.withValues(alpha: (1.0 - animationValue) * 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, sweepRadius, sweepPaint);

    // 4. Geofence Boundary Circle (Office Zone)
    final geofencePx = officeRadiusMeters * scale;
    final geofenceFill = Paint()
      ..color = greenColor.withValues(alpha: isDark ? 0.15 : 0.10)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, geofencePx, geofenceFill);

    final geofenceBorder = Paint()
      ..color = greenColor.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawCircle(center, geofencePx, geofenceBorder);

    // 5. Office Center Pin
    final officeFill = Paint()..color = accentColor;
    canvas.drawCircle(center, 7, officeFill);
    final officeWhite = Paint()..color = Colors.white;
    canvas.drawCircle(center, 3, officeWhite);

    // Label for Office Center
    final officeTextPainter = TextPainter(
      text: TextSpan(
        text: '🏢 HQ',
        style: TextStyle(
          color: isDark ? Colors.white70 : Colors.black87,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    officeTextPainter.paint(canvas, Offset(center.dx - (officeTextPainter.width / 2), center.dy + 9));

    // 6. User Location Marker and Distance Vector
    if (userLat != null && userLng != null) {
      // Coordinate delta in meters (Mercator local approximation)
      final dLatM = (userLat! - officeLat) * 111320.0;
      final dLngM = (userLng! - officeLng) * (111320.0 * math.cos(officeLat * math.pi / 180.0));

      // Screen offsets (Y is inverted on screen: North is negative Y)
      final userOffset = Offset(center.dx + (dLngM * scale), center.dy - (dLatM * scale));

      final activeColor = isInside == true ? greenColor : amberColor;

      // Draw Distance Vector Line between Office and User
      final vectorPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;

      canvas.drawLine(center, userOffset, vectorPaint);

      // Distance Text Pill in middle of vector line
      final midPoint = Offset((center.dx + userOffset.dx) / 2, (center.dy + userOffset.dy) / 2);
      final distLabel = '${userDistanceMeters?.round() ?? 0}m';
      final distTextPainter = TextPainter(
        text: TextSpan(
          text: distLabel,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 8.5,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: midPoint, width: distTextPainter.width + 10, height: 14),
        const Radius.circular(7),
      );
      final pillPaint = Paint()..color = activeColor.withValues(alpha: 0.9);
      canvas.drawRRect(pillRect, pillPaint);
      distTextPainter.paint(canvas, Offset(midPoint.dx - (distTextPainter.width / 2), midPoint.dy - 6));

      // Pulsating ring around User
      final pulseRadius = 9 + (math.sin(animationValue * 2 * math.pi) * 3);
      final pulsePaint = Paint()
        ..color = activeColor.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(userOffset, pulseRadius, pulsePaint);

      // User Pin Core
      final userPinPaint = Paint()..color = activeColor;
      canvas.drawCircle(userOffset, 6.5, userPinPaint);
      final userPinWhite = Paint()..color = Colors.white;
      canvas.drawCircle(userOffset, 2.5, userPinWhite);

      // User Label
      final userTextPainter = TextPainter(
        text: TextSpan(
          text: isInside == true ? '👤 You (In)' : '👤 You (Out)',
          style: TextStyle(
            color: activeColor,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      userTextPainter.paint(canvas, Offset(userOffset.dx - (userTextPainter.width / 2), userOffset.dy - 17));
    }
  }

  @override
  bool shouldRepaint(covariant _RadarMapPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.userLat != userLat ||
        oldDelegate.userLng != userLng ||
        oldDelegate.zoomMultiplier != zoomMultiplier ||
        oldDelegate.isInside != isInside;
  }
}
