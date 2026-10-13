import 'package:flutter/widgets.dart';

import '../tokens/n_tokens.dart';

/// Motion helpers. "Reduced" is true when either the app setting or the platform asks for it;
/// reduced motion shows final values instantly, with no slides.
abstract final class NMotion {
  static bool reduced(BuildContext context) {
    final platform = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return platform || NTokens.of(context).reducedMotion;
  }

  /// Token durations, or zero durations when motion is reduced.
  static NDurations durations(BuildContext context) =>
      reduced(context) ? NDurations.zero : NTokens.of(context).durations;
}
