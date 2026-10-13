/// Permission model mirrored from the backend (structure section 2.7).
///
/// The UI only *reads* this set to decide what to show. It is never a security control: every
/// protected API call is authorized again on the server. Filled from `GET /v1/auth/me`.
enum PermissionAction { view, create, edit, delete, approve, reject, assign, export, manage, configure }

/// Ordered from narrowest to broadest; "records" is a specific list and ranks just above "own".
enum PermissionScope { own, records, team, department, organization }

class Grant {
  const Grant(this.resource, this.action, this.scope);
  final String resource; // e.g. "attendance", "leave", "payroll"
  final PermissionAction action;
  final PermissionScope scope;

  /// Parses "resource:action:scope". Unknown parts return null (ignored, never granted).
  static Grant? parse(String s) {
    final p = s.split(':');
    if (p.length != 3) return null;
    final a = PermissionAction.values.where((v) => v.name == p[1]);
    final sc = PermissionScope.values.where((v) => v.name == p[2]);
    if (a.isEmpty || sc.isEmpty) return null;
    return Grant(p[0], a.first, sc.first);
  }
}

class PermissionSet {
  const PermissionSet(this.grants, {this.role = 'user'});

  factory PermissionSet.fromStrings(Iterable<String> raw, {String role = 'user'}) =>
      PermissionSet([for (final s in raw) if (Grant.parse(s) case final g?) g], role: role);

  /// Not signed in: nothing is granted.
  static const empty = PermissionSet([]);

  final List<Grant> grants;
  final String role;

  bool get isSuperAdmin => role == 'super_admin';

  /// Broadest scope held for resource + action, or null.
  PermissionScope? scope(String resource, PermissionAction action) {
    PermissionScope? best;
    for (final g in grants) {
      if (g.resource == resource && g.action == action && (best == null || g.scope.index > best.index)) best = g.scope;
    }
    return best;
  }

  bool allows(String resource, PermissionAction action, [PermissionScope atLeast = PermissionScope.own]) {
    final s = scope(resource, action);
    return s != null && s.index >= atLeast.index;
  }

  /// Shorthand: can(resource, 'view', 'team').
  bool can(String resource, String action, [String atLeast = 'own']) => allows(
        resource,
        PermissionAction.values.firstWhere((a) => a.name == action, orElse: () => PermissionAction.view),
        PermissionScope.values.firstWhere((s) => s.name == atLeast, orElse: () => PermissionScope.own),
      );

  String get signature => ([for (final g in grants) '${g.resource}:${g.action.name}:${g.scope.name}']..sort()).join('|');
}
