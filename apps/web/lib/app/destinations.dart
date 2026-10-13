import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_section.dart';
import '../features/appearance/appearance_page.dart';
import '../features/approvals/approvals_page.dart';
import '../features/documents/documents_page.dart';
import '../features/gallery/gallery_page.dart';
import '../features/home/dashboard_page.dart';
import '../features/money/money_section.dart';
import '../features/motion/motion_lab_page.dart';
import '../features/people/people_section.dart';
import '../features/reports/reports_page.dart';
import '../features/system/system_section.dart';
import '../features/time/time_section.dart';
import '../features/work/work_section.dart';
import '../l10n/gen/app_localizations.dart';
import 'config.dart';
import 'session.dart';

/// One primary navigation destination. The shell, router and command palette are all built from
/// this list, filtered by the permissions and enabled modules returned by `GET /v1/auth/me`.
class AppDestination {
  const AppDestination({
    required this.id,
    required this.path,
    required this.icon,
    required this.label,
    required this.builder,
    this.visible,
    this.designTool = false,
    this.children = const [],
    this.tabbed = false,
  });

  final String id;
  final String path;
  final IconData icon;
  final String Function(AppLocalizations l) label;

  /// Receives the `:tab` path parameter for tabbed sections.
  final Widget Function(BuildContext context, GoRouterState state) builder;
  final bool Function(Me me)? visible;

  /// Dev and staging only.
  final bool designTool;

  /// Extra routes under this destination (detail pages).
  final List<RouteBase> children;

  /// Adds a `/:tab` child route that renders the same builder.
  final bool tabbed;
}

bool _any(Me me, List<(String, String)> pairs) => pairs.any((p) => me.can(p.$1, p.$2));

final List<AppDestination> allDestinations = [
  AppDestination(id: 'home', path: '/', icon: Icons.space_dashboard_rounded, label: (l) => l.navHome, builder: (_, __) => const DashboardPage()),
  AppDestination(
    id: 'time',
    path: '/time',
    icon: Icons.schedule_rounded,
    label: (l) => l.navTime,
    tabbed: true,
    visible: (me) => (me.feature('attendance') && me.can('attendance', 'view')) || (me.feature('leave') && me.can('leave', 'view')),
    builder: (_, s) => TimeSection(tab: s.pathParameters['tab']),
  ),
  AppDestination(
    id: 'work',
    path: '/work',
    icon: Icons.view_kanban_rounded,
    label: (l) => l.navWork,
    tabbed: true,
    visible: (me) => (me.feature('tasks') && me.can('tasks', 'view')) || (me.feature('crm') && me.can('crm', 'view')) || (me.feature('meetings') && me.can('meetings', 'view')) || (me.feature('travel') && me.can('travel', 'view')),
    builder: (_, s) => WorkSection(tab: s.pathParameters['tab']),
    children: [GoRoute(path: 'leads/:id', builder: (_, s) => LeadDetailPage(id: s.pathParameters['id']!))],
  ),
  AppDestination(
    id: 'people',
    path: '/people',
    icon: Icons.groups_rounded,
    label: (l) => l.navPeople,
    tabbed: true,
    visible: (me) => me.can('employees', 'view', 'team') || me.can('departments', 'view'),
    builder: (_, s) => PeopleSection(tab: s.pathParameters['tab']),
    children: [GoRoute(path: 'employee/:id', builder: (_, s) => EmployeePage(id: s.pathParameters['id']!))],
  ),
  AppDestination(
    id: 'money',
    path: '/money',
    icon: Icons.account_balance_wallet_rounded,
    label: (l) => l.navMoney,
    tabbed: true,
    visible: (me) => (me.feature('expenses') && me.can('expenses', 'view')) || (me.feature('payroll') && (me.can('payslips', 'view') || me.can('payroll', 'view'))),
    builder: (_, s) => MoneySection(tab: s.pathParameters['tab']),
    children: [GoRoute(path: 'payroll/:id', builder: (_, s) => PayrollRunPage(id: s.pathParameters['id']!))],
  ),
  AppDestination(
    id: 'approvals',
    path: '/approvals',
    icon: Icons.fact_check_rounded,
    label: (l) => l.navApprovals,
    visible: (me) => me.can('approvals', 'view'),
    builder: (_, __) => const ApprovalsPage(),
  ),
  AppDestination(
    id: 'documents',
    path: '/documents',
    icon: Icons.folder_copy_rounded,
    label: (l) => l.navDocuments,
    visible: (me) => me.feature('documents') && me.can('documents', 'view'),
    builder: (_, __) => const DocumentsPage(),
  ),
  AppDestination(
    id: 'reports',
    path: '/reports',
    icon: Icons.insights_rounded,
    label: (l) => l.navReports,
    visible: (me) => me.can('reports', 'view'),
    builder: (_, __) => const ReportsPage(),
    children: [GoRoute(path: 'run/:key', builder: (_, s) => ReportRunPage(reportKey: s.pathParameters['key']!))],
  ),
  AppDestination(
    id: 'admin',
    path: '/admin',
    icon: Icons.admin_panel_settings_rounded,
    label: (l) => l.navAdmin,
    tabbed: true,
    visible: (me) => _any(me, [('organization', 'configure'), ('roles', 'view'), ('users', 'view'), ('locations', 'manage'), ('approvals', 'configure'), ('integrations', 'view'), ('features', 'configure')]),
    builder: (_, s) => AdminSection(tab: s.pathParameters['tab']),
  ),
  AppDestination(
    id: 'system',
    path: '/system',
    icon: Icons.monitor_heart_rounded,
    label: (l) => l.navSystem,
    tabbed: true,
    visible: (me) => _any(me, [('system', 'view'), ('backups', 'view'), ('security', 'view'), ('audit', 'view'), ('moderation', 'view')]),
    builder: (_, s) => SystemSection(tab: s.pathParameters['tab']),
  ),
  AppDestination(
    id: 'gallery',
    path: '/gallery',
    icon: Icons.widgets_rounded,
    label: (l) => l.navGallery,
    builder: (_, __) => const GalleryPage(),
    designTool: true,
  ),
  AppDestination(
    id: 'motion',
    path: '/motion',
    icon: Icons.animation_rounded,
    label: (l) => l.navMotion,
    builder: (_, __) => const MotionLabPage(),
    designTool: true,
  ),
];

/// Appearance lives under Account, but keeps its own route for deep links from Phase 1.
final appearanceRoute = GoRoute(path: '/appearance', builder: (_, __) => const AppearancePage());

List<AppDestination> visibleDestinations(Me? me) => [
      for (final d in allDestinations)
        if ((!d.designTool || (AppConfig.showDesignTools && (me?.can('nui_defaults', 'configure') ?? false))) && (d.visible == null || (me != null && d.visible!(me)))) d,
    ];
