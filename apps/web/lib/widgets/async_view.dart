import 'package:flutter/material.dart';
import 'package:n_ui/n_ui.dart';

import '../data/api.dart';

String describeError(Object e) {
  if (e is ApiException) return e.message;
  return 'Something went wrong. Try again.';
}

/// Shows an error to the user: toast with the message (and reference for server errors).
void showError(BuildContext context, Object e) {
  final ref = e is ApiException && e.correlationId != null && e.status >= 500 ? ' (ref ${e.correlationId})' : '';
  NToast.of(context).show('${describeError(e)}$ref');
}

/// Loads data once (and again on [reloadKey] change or [AsyncViewState.reload]). Loading shows a
/// skeleton, failures show the error with retry, and the builder only ever sees real data.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({super.key, required this.load, required this.builder, this.reloadKey, this.skeletonRows = 4, this.compact = false, this.initialData});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;
  final Object? reloadKey;
  final int skeletonRows;
  final bool compact;
  final T? initialData;

  @override
  State<AsyncView<T>> createState() => AsyncViewState<T>();
}

class AsyncViewState<T> extends State<AsyncView<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _data = widget.initialData;
    _loading = _data == null;
    reload(showSkeleton: false);
  }

  @override
  void didUpdateWidget(AsyncView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadKey != widget.reloadKey) reload(showSkeleton: true);
  }

  Future<void> reload({bool showSkeleton = false}) async {
    final seq = ++_seq;
    if (showSkeleton || _data == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final d = await widget.load();
      if (!mounted || seq != _seq) return;
      setState(() {
        _data = d;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) return NSkeletonList(rows: widget.skeletonRows);
    if (_error != null && _data == null) {
      final e = _error!;
      return NErrorState(
        message: describeError(e),
        correlationId: e is ApiException ? e.correlationId : null,
        onRetry: () => reload(showSkeleton: true),
        compact: widget.compact,
        title: e is ApiException && e.isForbidden ? "You don't have access to this" : "Couldn't load this",
      );
    }
    return widget.builder(context, _data as T, reload);
  }
}

/// A page of results from a list endpoint: `{items, page, limit, total, hasMore}`.
class PageResult<T> {
  const PageResult(this.items, {this.total = 0, this.hasMore = false, this.page = 1});
  factory PageResult.from(dynamic j, T Function(Json) map) {
    if (j is List) return PageResult([for (final e in j) map((e as Map).cast<String, dynamic>())], total: j.length);
    final m = (j as Map).cast<String, dynamic>();
    return PageResult(
      [for (final e in (m['items'] as List? ?? const [])) map((e as Map).cast<String, dynamic>())],
      total: (m['total'] as num?)?.toInt() ?? 0,
      hasMore: m['hasMore'] == true,
      page: (m['page'] as num?)?.toInt() ?? 1,
    );
  }
  final List<T> items;
  final int total;
  final bool hasMore;
  final int page;
}

List<Json> jsonList(dynamic j) {
  if (j is List) return [for (final e in j) (e as Map).cast<String, dynamic>()];
  if (j is Map && j['items'] is List) return [for (final e in j['items'] as List) (e as Map).cast<String, dynamic>()];
  return const [];
}

Json jsonMap(dynamic j) => j is Map ? j.cast<String, dynamic>() : <String, dynamic>{};

/// Paged list with "Load more". Pass a new [reloadKey] when filters change.
class PagedList extends StatefulWidget {
  const PagedList({
    super.key,
    required this.path,
    required this.itemBuilder,
    this.query = const {},
    this.reloadKey,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage,
    this.emptyIcon = Icons.inbox_rounded,
    this.limit = 25,
    this.wrap,
  });

  final String path;
  final Map<String, Object?> query;
  final Object? reloadKey;
  final Widget Function(BuildContext context, Json item, VoidCallback reload) itemBuilder;
  final String emptyTitle;
  final String? emptyMessage;
  final IconData emptyIcon;
  final int limit;

  /// Optional wrapper for the list of item widgets (e.g. a table).
  final Widget Function(BuildContext context, List<Json> items, VoidCallback reload)? wrap;

  @override
  State<PagedList> createState() => _PagedListState();
}

class _PagedListState extends State<PagedList> {
  final List<Json> _items = [];
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  int _page = 1;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void didUpdateWidget(PagedList old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey || old.path != widget.path) _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    final seq = ++_seq;
    setState(() {
      if (reset) {
        _loading = true;
        _page = 1;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final j = await ApiScope.of(context).get(widget.path, query: {...widget.query, 'page': reset ? 1 : _page + 1, 'limit': widget.limit});
      if (!mounted || seq != _seq) return;
      final p = PageResult<Json>.from(j, (m) => m);
      setState(() {
        if (reset) _items.clear();
        _items.addAll(p.items);
        _hasMore = p.hasMore;
        _page = reset ? 1 : _page + 1;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const NSkeletonList(rows: 5);
    if (_error != null && _items.isEmpty) {
      final e = _error!;
      return NErrorState(message: describeError(e), correlationId: e is ApiException ? e.correlationId : null, onRetry: () => _load(reset: true));
    }
    if (_items.isEmpty) return NEmptyState(title: widget.emptyTitle, message: widget.emptyMessage, icon: widget.emptyIcon);
    void reload() => _load(reset: true);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.wrap != null) widget.wrap!(context, _items, reload) else for (final i in _items) widget.itemBuilder(context, i, reload),
      if (_hasMore)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Center(child: NButton(label: 'Load more', variant: NButtonVariant.secondary, compact: true, busy: _loadingMore, onPressed: () => _load())),
        ),
    ]);
  }
}

/// Gives widgets below access to the API client without importing services everywhere.
class ApiScope extends InheritedWidget {
  const ApiScope({super.key, required this.api, required super.child});
  final ApiClient api;

  static ApiClient of(BuildContext context) => context.getInheritedWidgetOfExactType<ApiScope>()!.api;

  @override
  bool updateShouldNotify(ApiScope old) => api != old.api;
}
