import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../platform/bridge.dart';

/// Available visualization modes for the geofence map.
enum GeofenceMapMode {
  /// Real street map tiles (CartoDB Dark Matter in Dark Mode, CartoDB Voyager in Light Mode).
  street,

  /// OpenStreetMap standard imagery.
  satellite,

  /// High-contrast tactical radar canvas.
  radar,
}

/// Interactive Real Map & Geofence Visualizer.
/// Shows real street map tiles (with dark/light theme switching), geofence perimeter ring,
/// live user GPS pin with accuracy halo, distance vector, sonar animation,
/// zoom controls, and a fully responsive non-colliding mobile layout.
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
    this.onSetOfficeLocation,
    this.onOpenPermissions,
    this.height = 240,
    this.initialZoom = 16,
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
  final VoidCallback? onSetOfficeLocation;
  final VoidCallback? onOpenPermissions;
  final double height;
  final int initialZoom;

  @override
  State<GeofenceRadarMap> createState() => _GeofenceRadarMapState();
}

class _GeofenceRadarMapState extends State<GeofenceRadarMap> with SingleTickerProviderStateMixin {
  late final AnimationController _animCtrl;
  late int _zoomLevel;
  GeofenceMapMode _mode = GeofenceMapMode.street;

  @override
  void initState() {
    super.initState();
    _zoomLevel = widget.initialZoom.clamp(14, 18);
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

  // Web Mercator Slippy Map mathematics
  static double _lngToTileX(double lng, int zoom) {
    return (lng + 180.0) / 360.0 * (1 << zoom);
  }

  static double _latToTileY(double lat, int zoom) {
    final latRad = lat * math.pi / 180.0;
    return (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) / 2.0 * (1 << zoom);
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

  String _getTileUrl(int z, int x, int y, bool isDark) {
    final sub = ['a', 'b', 'c', 'd'][(x.abs() + y.abs()) % 4];
    if (_mode == GeofenceMapMode.satellite) {
      return 'https://tile.openstreetmap.org/$z/$x/$y.png';
    }
    if (isDark) {
      return 'https://$sub.basemaps.cartocdn.com/dark_all/$z/$x/$y.png';
    } else {
      return 'https://$sub.basemaps.cartocdn.com/rastertiles/voyager/$z/$x/$y.png';
    }
  }

  void _cycleMapMode() {
    setState(() {
      if (_mode == GeofenceMapMode.street) {
        _mode = GeofenceMapMode.satellite;
      } else if (_mode == GeofenceMapMode.satellite) {
        _mode = GeofenceMapMode.radar;
      } else {
        _mode = GeofenceMapMode.street;
      }
    });
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
        color: t.isDark ? const Color(0xFF0B132B) : const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(t.radiusCard),
        border: Border.all(
          color: (isInside == true ? t.green : (isInside == false ? t.amber : t.cardBorder)).withValues(alpha: 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.isDark ? 0.35 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;

          final cx = width / 2.0;
          final cy = height / 2.0;

          final xFloat = _lngToTileX(widget.officeLng, _zoomLevel);
          final yFloat = _latToTileY(widget.officeLat, _zoomLevel);

          final x0 = xFloat.floor();
          final y0 = yFloat.floor();

          final fx = (xFloat - x0) * 256.0;
          final fy = (yFloat - y0) * 256.0;

          final originX = cx - fx;
          final originY = cy - fy;

          return Stack(
            children: [
              // 1. Real Slippy Map Tile Layer (CartoDB / OSM)
              if (_mode != GeofenceMapMode.radar)
                Positioned.fill(
                  child: Stack(
                    children: [
                      // Dark / Light base backdrop
                      Container(
                        color: t.isDark ? const Color(0xFF111827) : const Color(0xFFF8FAFC),
                      ),
                      // 5x5 dynamic tile grid centered on office coordinates
                      for (var col = -2; col <= 2; col++)
                        for (var row = -2; row <= 2; row++) ...[
                          Builder(builder: (context) {
                            final tileX = x0 + col;
                            final tileY = y0 + row;
                            final left = originX + col * 256.0;
                            final top = originY + row * 256.0;

                            // Viewport culling: only mount tiles that intersect view
                            if (left + 256.0 < 0 || left > width || top + 256.0 < 0 || top > height) {
                              return const SizedBox.shrink();
                            }

                            final tileUrl = _getTileUrl(_zoomLevel, tileX, tileY, t.isDark);

                            return Positioned(
                              left: left,
                              top: top,
                              width: 256,
                              height: 256,
                              child: Image.network(
                                tileUrl,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                                errorBuilder: (ctx, err, stack) => Container(
                                  color: t.isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                                  child: Icon(
                                    Icons.map_outlined,
                                    size: 24,
                                    color: t.divider.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                    ],
                  ),
                ),

              // 2. Geofence Perimeter, Pin, Sonar Pulse & Vector Overlay
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _animCtrl,
                  builder: (context, _) {
                    return CustomPaint(
                      painter: _RealGeofenceMapPainter(
                        officeRadiusMeters: widget.officeRadiusMeters,
                        userDistanceMeters: distanceMeters,
                        officeLat: widget.officeLat,
                        officeLng: widget.officeLng,
                        userLat: widget.userLat,
                        userLng: widget.userLng,
                        accuracyMeters: widget.accuracyMeters,
                        isInside: isInside,
                        animationValue: _animCtrl.value,
                        zoomLevel: _zoomLevel,
                        isDark: t.isDark,
                        isRadarMode: _mode == GeofenceMapMode.radar,
                        accentColor: t.accent,
                        greenColor: t.green,
                        amberColor: t.amber,
                      ),
                    );
                  },
                ),
              ),

              // 3. Top-Left: Status Badge Pill
              Positioned(
                top: 8,
                left: 8,
                child: InkWell(
                  onTap: widget.onOpenPermissions,
                  borderRadius: BorderRadius.circular(NTokens.radiusPill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (t.isDark ? const Color(0xDD0F172A) : const Color(0xF0FFFFFF)),
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                    border: Border.all(
                      color: (isInside == true ? t.green : (isInside == false ? t.amber : t.cardBorder)),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isInside == true
                            ? Icons.check_circle_rounded
                            : (isInside == false ? Icons.warning_rounded : Icons.radar_rounded),
                        size: 13,
                        color: isInside == true
                            ? (t.isDark ? Colors.greenAccent : t.green)
                            : (isInside == false ? (t.isDark ? Colors.orangeAccent : t.amber) : t.accent),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isInside == true
                            ? 'Inside Geofence (${distanceMeters?.round() ?? 0}m)'
                            : (isInside == false
                                ? 'Outside Geofence (${distanceMeters?.round() ?? 0}m)'
                                : 'Geofence (${widget.officeRadiusMeters.round()}m)'),
                        style: t.text.caption(weight: FontWeight.w700).copyWith(
                              fontSize: 10.5,
                              color: isInside == true
                                  ? (t.isDark ? Colors.greenAccent : t.green)
                                  : (isInside == false ? (t.isDark ? Colors.orangeAccent : t.amber) : t.ink),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

              // 4. Top-Right: Map Controls (Layer Toggle, Zoom, Compass)
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Layer Switcher (Street / OSM / Radar)
                    InkWell(
                      onTap: _cycleMapMode,
                      borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: (t.isDark ? const Color(0xDD0F172A) : const Color(0xF0FFFFFF)),
                          borderRadius: BorderRadius.circular(NTokens.radiusPill),
                          border: Border.all(color: t.divider),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _mode == GeofenceMapMode.street
                                  ? Icons.map_rounded
                                  : (_mode == GeofenceMapMode.satellite ? Icons.public_rounded : Icons.radar_rounded),
                              size: 13,
                              color: t.accent,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _mode == GeofenceMapMode.street ? 'Street' : (_mode == GeofenceMapMode.satellite ? 'OSM' : 'Radar'),
                              style: t.text.caption(weight: FontWeight.w800).copyWith(fontSize: 9.5, color: t.accent),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),

                    // Zoom Out Button
                    InkWell(
                      onTap: () {
                        if (_zoomLevel > 14) {
                          setState(() => _zoomLevel--);
                        }
                      },
                      borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: (t.isDark ? const Color(0xDD0F172A) : const Color(0xF0FFFFFF)),
                          shape: BoxShape.circle,
                          border: Border.all(color: t.divider),
                        ),
                        child: Icon(Icons.remove, size: 13, color: _zoomLevel > 14 ? t.ink : t.muted),
                      ),
                    ),
                    const SizedBox(width: 4),

                    // Zoom In Button
                    InkWell(
                      onTap: () {
                        if (_zoomLevel < 18) {
                          setState(() => _zoomLevel++);
                        }
                      },
                      borderRadius: BorderRadius.circular(NTokens.radiusPill),
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: (t.isDark ? const Color(0xDD0F172A) : const Color(0xF0FFFFFF)),
                          shape: BoxShape.circle,
                          border: Border.all(color: t.divider),
                        ),
                        child: Icon(Icons.add, size: 13, color: _zoomLevel < 18 ? t.ink : t.muted),
                      ),
                    ),
                  ],
                ),
              ),

              // 5. Bottom Bar: Single Unified Glassmorphism Bar (Zero Overlap on Mobile)
              Positioned(
                bottom: 8,
                left: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (t.isDark ? const Color(0xEE0F172A) : const Color(0xF4FFFFFF)),
                    borderRadius: BorderRadius.circular(NTokens.radiusPill),
                    border: Border.all(
                      color: (isInside == true ? t.green : (isInside == false ? t.amber : t.cardBorder)).withValues(alpha: 0.6),
                      width: 1.1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: t.isDark ? 0.35 : 0.10),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: LayoutBuilder(
                    builder: (context, barConstraints) {
                      final isCompact = barConstraints.maxWidth < 360;
                      return Row(
                        children: [
                          // Office details (with tap to set office location)
                          Expanded(
                            child: InkWell(
                              onTap: widget.onSetOfficeLocation,
                              borderRadius: BorderRadius.circular(4),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.business_rounded, size: 13, color: t.accent),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        '${widget.officeName} (${widget.officeRadiusMeters.round()}m)',
                                        style: t.text.caption(weight: FontWeight.w700).copyWith(
                                              fontSize: isCompact ? 10 : 11,
                                              color: t.ink,
                                            ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                    if (widget.onSetOfficeLocation != null) ...[
                                      const SizedBox(width: 4),
                                      Tooltip(
                                        message: 'Set Office Location',
                                        child: Icon(Icons.edit_location_alt_outlined, size: 12, color: t.accent),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),

                          if (widget.userLat == null && widget.onOpenPermissions != null) ...[
                            _MapActionButton(
                              icon: Icons.security_rounded,
                              label: isCompact ? null : 'Permissions',
                              tooltip: 'Device GPS & Permissions Setup',
                              onTap: widget.onOpenPermissions,
                              isDark: t.isDark,
                              accentColor: t.amber,
                            ),
                            const SizedBox(width: 4),
                          ],

                          // Refresh GPS button
                          if (widget.onRefresh != null) ...[
                            _MapActionButton(
                              icon: widget.isRefreshing ? null : Icons.refresh_rounded,
                              label: isCompact ? null : (widget.isRefreshing ? 'Locating...' : 'Refresh GPS'),
                              isLoading: widget.isRefreshing,
                              tooltip: 'Refresh GPS',
                              onTap: widget.isRefreshing ? null : widget.onRefresh,
                              isDark: t.isDark,
                              accentColor: t.accent,
                            ),
                            const SizedBox(width: 4),
                          ],

                          // Google Maps external link
                          _MapActionButton(
                            icon: Icons.open_in_new_rounded,
                            label: isCompact ? null : 'Google Maps',
                            tooltip: 'Open in Google Maps',
                            onTap: () {
                              final lat = widget.userLat ?? widget.officeLat;
                              final lng = widget.userLng ?? widget.officeLng;
                              bridge.openUrl('https://www.google.com/maps?q=$lat,$lng');
                            },
                            isDark: t.isDark,
                            accentColor: t.accent,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.onTap,
    this.icon,
    this.label,
    this.tooltip,
    this.isLoading = false,
    required this.isDark,
    required this.accentColor,
  });

  final VoidCallback? onTap;
  final IconData? icon;
  final String? label;
  final String? tooltip;
  final bool isLoading;
  final bool isDark;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    Widget button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NTokens.radiusPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: accentColor.withValues(alpha: isDark ? 0.20 : 0.12),
          borderRadius: BorderRadius.circular(NTokens.radiusPill),
          border: Border.all(color: accentColor.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.8, color: accentColor),
              )
            else if (icon != null)
              Icon(icon, size: 12, color: accentColor),
            if (label != null) ...[
              if (icon != null || isLoading) const SizedBox(width: 3),
              Text(
                label!,
                style: TextStyle(
                  color: accentColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}

/// CustomPainter that renders geofence rings, live user pin, accuracy halo,
/// distance vector line, and animated sonar sweep with mathematical precision.
class _RealGeofenceMapPainter extends CustomPainter {
  _RealGeofenceMapPainter({
    required this.officeRadiusMeters,
    required this.userDistanceMeters,
    required this.officeLat,
    required this.officeLng,
    this.userLat,
    this.userLng,
    this.accuracyMeters,
    this.isInside,
    required this.animationValue,
    required this.zoomLevel,
    required this.isDark,
    required this.isRadarMode,
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
  final double? accuracyMeters;
  final bool? isInside;
  final double animationValue;
  final int zoomLevel;

  final bool isDark;
  final bool isRadarMode;
  final Color accentColor;
  final Color greenColor;
  final Color amberColor;

  static double _lngToTileX(double lng, int zoom) {
    return (lng + 180.0) / 360.0 * (1 << zoom);
  }

  static double _latToTileY(double lat, int zoom) {
    final latRad = lat * math.pi / 180.0;
    return (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) / 2.0 * (1 << zoom);
  }

  static double _metersPerPixel(double lat, int zoom) {
    return (40075016.686 * math.cos(lat * math.pi / 180.0)) / (256.0 * (1 << zoom));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final mpp = _metersPerPixel(officeLat, zoomLevel);
    final geofencePx = officeRadiusMeters / mpp;

    // 1. Radar Grid (Only drawn in Radar mode or subtle crosshairs in Real Map mode)
    if (isRadarMode) {
      final gridLineColor = isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06);
      final gridPaint = Paint()
        ..color = gridLineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;

      for (final factor in [0.5, 1.0, 1.5, 2.0]) {
        canvas.drawCircle(center, geofencePx * factor, gridPaint);
      }
      canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), gridPaint);
      canvas.drawLine(Offset(center.dx, 0), Offset(center.dx, size.height), gridPaint);
    }

    // 2. Geofence Boundary Zone
    final geofenceFill = Paint()
      ..color = greenColor.withValues(alpha: isDark ? 0.16 : 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, geofencePx, geofenceFill);

    final geofenceBorder = Paint()
      ..color = greenColor.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, geofencePx, geofenceBorder);

    // 3. Sonar Sweep Wave (Animated pulse along geofence perimeter)
    final pulseScale = 1.0 + (animationValue * 0.35);
    final pulsePaint = Paint()
      ..color = greenColor.withValues(alpha: (1.0 - animationValue) * 0.30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawCircle(center, geofencePx * pulseScale, pulsePaint);

    // 4. Office Center Pin
    final pinShadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(center.translate(0, 1.5), 7.5, pinShadow);

    final officeFill = Paint()..color = accentColor;
    canvas.drawCircle(center, 7.5, officeFill);
    final officeWhite = Paint()..color = Colors.white;
    canvas.drawCircle(center, 3.2, officeWhite);

    // Label for Office Center
    final officeTextPainter = TextPainter(
      text: TextSpan(
        text: '🏢 HQ',
        style: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          shadows: [
            Shadow(
              color: isDark ? Colors.black : Colors.white,
              blurRadius: 3,
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    officeTextPainter.paint(canvas, Offset(center.dx - (officeTextPainter.width / 2), center.dy + 10));

    // 5. User GPS Pin, Accuracy Halo & Distance Vector
    if (userLat != null && userLng != null) {
      final officeXFloat = _lngToTileX(officeLng, zoomLevel);
      final officeYFloat = _latToTileY(officeLat, zoomLevel);

      final userXFloat = _lngToTileX(userLng!, zoomLevel);
      final userYFloat = _latToTileY(userLat!, zoomLevel);

      final userOffset = Offset(
        center.dx + (userXFloat - officeXFloat) * 256.0,
        center.dy + (userYFloat - officeYFloat) * 256.0,
      );

      final activeColor = isInside == true ? greenColor : amberColor;

      // Distance Vector Line
      final vectorPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      canvas.drawLine(center, userOffset, vectorPaint);

      // Distance Pill in middle of vector line
      final midPoint = Offset((center.dx + userOffset.dx) / 2, (center.dy + userOffset.dy) / 2);
      final distLabel = '${userDistanceMeters?.round() ?? 0}m';
      final distTextPainter = TextPainter(
        text: TextSpan(
          text: distLabel,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: midPoint, width: distTextPainter.width + 10, height: 15),
        const Radius.circular(7.5),
      );
      final pillPaint = Paint()..color = activeColor.withValues(alpha: 0.95);
      canvas.drawRRect(pillRect, pillPaint);
      distTextPainter.paint(canvas, Offset(midPoint.dx - (distTextPainter.width / 2), midPoint.dy - 6));

      // Accuracy Halo Circle
      if (accuracyMeters != null && accuracyMeters! > 0) {
        final accuracyPx = (accuracyMeters! / mpp).clamp(8.0, 150.0);
        final accuracyFill = Paint()
          ..color = (isInside == true ? Colors.blueAccent : amberColor).withValues(alpha: 0.12)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(userOffset, accuracyPx, accuracyFill);

        final accuracyBorder = Paint()
          ..color = (isInside == true ? Colors.blueAccent : amberColor).withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawCircle(userOffset, accuracyPx, accuracyBorder);
      }

      // Pulsating ring around User
      final userPulseRadius = 10 + (math.sin(animationValue * 2 * math.pi) * 3);
      final userPulsePaint = Paint()
        ..color = activeColor.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(userOffset, userPulseRadius, userPulsePaint);

      // User Pin Core
      final userPinShadow = Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(userOffset.translate(0, 1.5), 7, userPinShadow);

      final userPinPaint = Paint()..color = activeColor;
      canvas.drawCircle(userOffset, 7, userPinPaint);
      final userPinWhite = Paint()..color = Colors.white;
      canvas.drawCircle(userOffset, 2.8, userPinWhite);

      // User Label
      final userTextPainter = TextPainter(
        text: TextSpan(
          text: isInside == true ? '👤 You (In)' : '👤 You (Out)',
          style: TextStyle(
            color: activeColor,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            shadows: [
              Shadow(
                color: isDark ? Colors.black : Colors.white,
                blurRadius: 3,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      userTextPainter.paint(canvas, Offset(userOffset.dx - (userTextPainter.width / 2), userOffset.dy - 18));
    }
  }

  @override
  bool shouldRepaint(covariant _RealGeofenceMapPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.userLat != userLat ||
        oldDelegate.userLng != userLng ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.isRadarMode != isRadarMode ||
        oldDelegate.isInside != isInside;
  }
}
