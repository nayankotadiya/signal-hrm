import 'package:intl/intl.dart';

/// Display formatting. Timestamps from the API are UTC ISO strings; they are shown in the
/// browser's local time zone. Day strings (YYYY-MM-DD) are calendar dates and never shifted.
abstract final class Fmt {
  static DateTime? parse(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

  static String date(Object? v) {
    if (v == null || '$v'.isEmpty) return '—';
    final s = '$v';
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) {
      final d = DateTime.parse('${s}T00:00:00');
      return DateFormat('d MMM yyyy').format(d);
    }
    final d = parse(s);
    return d == null ? '—' : DateFormat('d MMM yyyy').format(d);
  }

  static String shortDate(Object? v) {
    if (v == null) return '—';
    final s = '$v';
    final d = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) ? DateTime.parse('${s}T00:00:00') : parse(s);
    return d == null ? '—' : DateFormat('d MMM').format(d);
  }

  static String weekday(Object? v) {
    final s = '$v';
    final d = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) ? DateTime.parse('${s}T00:00:00') : parse(s);
    return d == null ? '' : DateFormat('EEE').format(d);
  }

  static String time(Object? v) {
    final d = parse(v);
    return d == null ? '—' : DateFormat('h:mm a').format(d);
  }

  static String dateTime(Object? v) {
    final d = parse(v);
    return d == null ? '—' : DateFormat('d MMM yyyy, h:mm a').format(d);
  }

  static String relative(Object? v) {
    final d = parse(v);
    if (d == null) return '—';
    final diff = DateTime.now().difference(d);
    if (diff.isNegative) {
      final f = -diff.inMinutes;
      if (f < 60) return 'in $f min';
      if (f < 1440) return 'in ${(f / 60).round()} h';
      return 'on ${date(v)}';
    }
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return date(v);
  }

  static String money(Object? v, [String currency = 'INR']) {
    if (v == null) return '—';
    final n = v is num ? v : num.tryParse('$v');
    if (n == null) return '—';
    final f = NumberFormat.currency(locale: currency == 'INR' ? 'en_IN' : 'en', name: currency, symbol: currency == 'INR' ? '₹' : '$currency ', decimalDigits: n % 1 == 0 ? 0 : 2);
    return f.format(n);
  }

  static String number(Object? v) {
    if (v == null) return '—';
    final n = v is num ? v : num.tryParse('$v');
    return n == null ? '—' : NumberFormat.decimalPattern('en_IN').format(n);
  }

  static String minutes(Object? v) {
    final m = (v is num ? v : num.tryParse('$v') ?? 0).round();
    if (m <= 0) return '0m';
    final h = m ~/ 60;
    final r = m % 60;
    return h == 0 ? '${r}m' : (r == 0 ? '${h}h' : '${h}h ${r}m');
  }

  static String bytes(Object? v) {
    final n = (v is num ? v : num.tryParse('$v') ?? 0).toDouble();
    if (n < 1024) return '${n.round()} B';
    if (n < 1048576) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1073741824) return '${(n / 1048576).toStringAsFixed(1)} MB';
    return '${(n / 1073741824).toStringAsFixed(2)} GB';
  }

  /// "pending_approval" -> "Pending approval"
  static String label(Object? v) {
    final s = '${v ?? ''}'.replaceAll('_', ' ').trim();
    return s.isEmpty ? '—' : s[0].toUpperCase() + s.substring(1);
  }

  static String day(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
}
