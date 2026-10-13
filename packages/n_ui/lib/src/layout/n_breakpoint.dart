import 'package:flutter/widgets.dart';

/// Device classes. Desktop, tablet and mobile are separate designs, not one stretched layout.
/// Widgets read the breakpoint from [NBreakpointScope]; nothing checks raw screen widths.
enum NBreakpoint {
  /// up to 759
  mobile,

  /// 760 to 999
  tablet,

  /// 1000 to 1439
  laptop,

  /// 1440 and up
  desktop;

  static NBreakpoint fromWidth(double width) {
    if (width < 760) return NBreakpoint.mobile;
    if (width < 1000) return NBreakpoint.tablet;
    if (width < 1440) return NBreakpoint.laptop;
    return NBreakpoint.desktop;
  }

  bool get isMobile => this == NBreakpoint.mobile;
  bool get isTablet => this == NBreakpoint.tablet;
  bool get isWide => index >= NBreakpoint.laptop.index;
  bool atLeast(NBreakpoint other) => index >= other.index;

  /// Bento columns: 1 on mobile (below 620 the shell also stacks small tiles in 2), 2 on tablet, 4 wider.
  int get bentoColumns => switch (this) {
        NBreakpoint.mobile => 1,
        NBreakpoint.tablet => 2,
        NBreakpoint.laptop || NBreakpoint.desktop => 4,
      };

  /// Side drawer widths per the responsive table.
  double get drawerWidth => switch (this) {
        NBreakpoint.mobile => double.infinity,
        NBreakpoint.tablet => 420,
        NBreakpoint.laptop || NBreakpoint.desktop => 480,
      };

  /// The widest the content column grows to.
  double get maxContentWidth => this == NBreakpoint.desktop ? 1440 : double.infinity;

  /// Read the nearest breakpoint. Defaults to mobile (the safest layout) when no scope exists.
  static NBreakpoint of(BuildContext context) => NBreakpointScope.maybeOf(context)?.breakpoint ?? NBreakpoint.mobile;

  /// Available width of the nearest scope (the shell's content width, not the screen).
  static double widthOf(BuildContext context) => NBreakpointScope.maybeOf(context)?.width ?? 360;
}

/// Publishes the breakpoint for its subtree. Placed by [NBreakpointBuilder]; the component gallery
/// also places it inside device frames so a 390px preview behaves like a phone on a wide screen.
class NBreakpointScope extends InheritedWidget {
  const NBreakpointScope({super.key, required this.breakpoint, required this.width, required super.child});

  final NBreakpoint breakpoint;
  final double width;

  static NBreakpointScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NBreakpointScope>();

  @override
  bool updateShouldNotify(NBreakpointScope oldWidget) =>
      breakpoint != oldWidget.breakpoint || (width - oldWidget.width).abs() >= 1;
}

/// Measures the available width with a [LayoutBuilder] and publishes an [NBreakpointScope].
class NBreakpointBuilder extends StatelessWidget {
  const NBreakpointBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, NBreakpoint breakpoint) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.hasBoundedWidth ? constraints.maxWidth : 1280.0;
      final bp = NBreakpoint.fromWidth(width);
      return NBreakpointScope(
        breakpoint: bp,
        width: width,
        child: Builder(builder: (context) => builder(context, bp)),
      );
    });
  }
}
