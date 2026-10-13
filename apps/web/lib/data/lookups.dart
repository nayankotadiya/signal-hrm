import 'package:n_ui/n_ui.dart';

import '../widgets/async_view.dart';
import 'api.dart';

String employeeName(Json e) {
  final d = e['displayName'] as String?;
  if (d != null && d.isNotEmpty) return d;
  return '${e['firstName'] ?? ''} ${e['lastName'] ?? ''}'.trim();
}

/// Option loaders for form selects. Results reflect the caller's permissions (the API scopes them).
abstract final class Lookups {
  static Future<List<NOption<String>>> employees(ApiClient api) async {
    final all = <Json>[];
    for (var page = 1; page <= 10; page++) {
      final j = await api.get('/employees', query: {'limit': 100, 'page': page});
      all.addAll(jsonList(j));
      if (!(j is Map && j['hasMore'] == true)) break;
    }
    return [
      for (final e in all)
        if (e['status'] != 'exited' && e['status'] != 'archived') NOption('${e['id']}', employeeName(e), subtitle: '${e['employeeCode'] ?? ''} · ${e['designation'] ?? ''}'),
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }

  /// People who can sign in (meeting participants are user accounts, not employee records).
  static Future<List<NOption<String>>> users(ApiClient api) async {
    final all = <Json>[];
    for (var page = 1; page <= 10; page++) {
      final j = await api.get('/employees', query: {'limit': 100, 'page': page});
      all.addAll(jsonList(j));
      if (!(j is Map && j['hasMore'] == true)) break;
    }
    return [
      for (final e in all)
        if (e['userId'] != null && e['status'] != 'exited') NOption('${e['userId']}', employeeName(e)),
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }

  static Future<List<NOption<String>>> departments(ApiClient api) async => [
        for (final d in jsonList(await api.get('/departments'))) NOption('${d['id']}', '${d['name']}'),
      ];

  static Future<List<NOption<String>>> teams(ApiClient api) async => [
        for (final d in jsonList(await api.get('/teams'))) NOption('${d['id']}', '${d['name']}'),
      ];

  static Future<List<NOption<String>>> locations(ApiClient api) async => [
        for (final d in jsonList(await api.get('/locations'))) NOption('${d['id']}', '${d['name']}'),
      ];

  static Future<List<NOption<String>>> shifts(ApiClient api) async => [
        for (final d in jsonList(await api.get('/shifts'))) NOption('${d['id']}', '${d['name']} (${d['startTime']}–${d['endTime']})'),
      ];

  static Future<List<NOption<String>>> leaveTypes(ApiClient api) async => [
        for (final d in jsonList(await api.get('/leave/types')))
          if (d['active'] != false) NOption('${d['id']}', '${d['name']} (${d['code']})'),
      ];

  static Future<List<NOption<String>>> expenseCategories(ApiClient api) async => [
        for (final d in jsonList(await api.get('/expenses/categories')))
          if (d['active'] != false) NOption('${d['id']}', '${d['name']}'),
      ];

  static Future<List<NOption<String>>> roles(ApiClient api) async => [
        for (final d in jsonList(await api.get('/roles'))) NOption('${d['key']}', '${d['name']}'),
      ];

  static Future<List<NOption<String>>> leadSources(ApiClient api) async => [
        for (final d in jsonList(await api.get('/crm/sources'))) NOption('${d['key']}', '${d['name'] ?? d['key']}'),
      ];
}
