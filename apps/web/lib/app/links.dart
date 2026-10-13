/// Maps deep links produced by the API (notifications, search, needs-attention items) onto app
/// routes. Keeps older link shapes working when routes move.
String resolveLink(String? link) {
  if (link == null || link.isEmpty) return '/';
  final uri = Uri.tryParse(link);
  if (uri == null) return '/';
  final seg = uri.pathSegments;
  final q = uri.query.isEmpty ? '' : '?${uri.query}';
  final id = RegExp(r'^[a-f0-9]{24}$');
  if (seg.isEmpty) return '/';
  String withOpen(String base, String oid) => '$base?open=$oid';
  switch (seg.first) {
    case 'attendance':
      if (seg.length > 1 && seg[1] == 'review') return '/time/review';
      if (uri.queryParameters['view'] == 'history') return '/time';
      return '/time';
    case 'time':
      if (seg.length > 1 && seg[1] == 'attendance') return '/time';
      return link;
    case 'people':
      if (seg.length > 1 && id.hasMatch(seg[1])) return '/people/employee/${seg[1]}';
      if (seg.length > 1 && (seg[1] == 'departments' || seg[1] == 'teams')) return '/people/org';
      if (seg.length > 1 && seg[1] == 'new') return '/people?new=1';
      return link;
    case 'moderation':
      return '/system/moderation';
    case 'security':
      return '/system/security';
    case 'admin':
      if (seg.length > 1 && seg[1] == 'backups') return '/system/backups';
      return link;
    case 'payroll':
      return '/money/payroll';
    case 'settings':
      final s = seg.length > 1 ? seg[1] : '';
      return switch (s) {
        'departments' => '/people/org',
        'shifts' => '/time/shifts',
        'holidays' => '/time/calendar',
        'organization' || '' => '/admin',
        _ => '/admin/$s$q',
      };
    case 'work':
      if (seg.length > 2 && seg[1] == 'crm') return '/work/leads/${seg[2]}';
      if (seg.length > 1 && seg[1] == 'crm') return '/work/leads$q';
      if (seg.length > 2 && seg[1] == 'tasks') return withOpen('/work', seg[2]);
      if (seg.length > 2 && seg[1] == 'meetings') return withOpen('/work/meetings', seg[2]);
      return link;
    case 'documents':
      if (seg.length > 1 && id.hasMatch(seg[1])) return withOpen('/documents', seg[1]);
      return link;
    case 'approvals':
      if (seg.length > 1 && id.hasMatch(seg[1])) return withOpen('/approvals', seg[1]);
      return link;
    case 'announcements':
      return '/people/announcements';
    default:
      return link;
  }
}
