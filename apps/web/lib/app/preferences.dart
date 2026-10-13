import 'package:flutter/widgets.dart';
import 'package:n_ui/n_ui.dart';

/// Holds the signed-in user's N UI preferences and feeds NTokens live.
///
/// Phase 1: in memory for the session. Phase 2 loads organization defaults + `user_preferences`
/// after sign-in and syncs changes back through the API (NPreferences.fromJson never throws, so a
/// malformed stored value falls back to safe defaults).
class PreferencesController extends ValueNotifier<NPreferences> {
  PreferencesController([super.value = const NPreferences()]);

  void update(NPreferences Function(NPreferences current) change) => value = change(value);

  void reset() => value = const NPreferences();
}

class PreferencesScope extends InheritedNotifier<PreferencesController> {
  const PreferencesScope({super.key, required PreferencesController controller, required super.child})
      : super(notifier: controller);

  static PreferencesController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PreferencesScope>();
    assert(scope != null, 'No PreferencesScope above this context');
    return scope!.notifier!;
  }
}
