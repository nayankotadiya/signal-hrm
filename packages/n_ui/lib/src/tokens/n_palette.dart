import 'package:flutter/painting.dart';

/// Raw N UI colors. Widgets never use these directly: they read [NTokens] from the theme.
/// Only the token resolver touches this file.
abstract final class NPalette {
  // Light surfaces
  static const lightPage = [Color(0xFFBCD6F6), Color(0xFFDCD2F4), Color(0xFFCDF2EC), Color(0xFFF4F8C2)];
  static const lightPageStops = [0.0, 0.22, 0.50, 0.85];
  static const lightPanel = [Color(0xFFD3F1F4), Color(0xFFE4F5E1), Color(0xFFF7FAC9)];
  static const lightPanelStops = [0.0, 0.5, 1.0];
  static const lightFrame = Color(0x8CA0A0E8); // rgba(160,160,232,.55)
  static const lightCard = Color(0xB8FFFFFF); // rgba(255,255,255,.72)
  static const lightInk = Color(0xFF0F1115);

  /// Spec value #6E7480 measured 3.95:1 on the light panel (fails AA). Darkened to pass 4.5:1
  /// on every panel and card stop (min 4.93:1). See docs/ARCHITECTURE.md, "Contrast decisions".
  static const lightMuted = Color(0xFF5F6570);
  static const lightPillTrack = Color(0x99FFFFFF); // rgba(255,255,255,.6)

  // Dark surfaces
  static const darkPage = [Color(0xFF141A33), Color(0xFF1B1A3A), Color(0xFF10282B), Color(0xFF232B16)];
  static const darkPageStops = [0.0, 0.30, 0.65, 1.0];
  static const darkPanel = [Color(0xFF16213A), Color(0xFF162B33), Color(0xFF2A301A)];
  static const darkPanelStops = [0.0, 0.55, 1.0];
  static const darkFrame = Color(0x59A0A0E8);
  static const darkCard = Color(0xCC1A1E2C); // rgba(26,30,44,.8)
  static const darkInk = Color(0xFFEDEFF5);
  static const darkMuted = Color(0xFF98A0B6);
  static const darkPillTrack = Color(0x1FFFFFFF);

  static const divider = Color(0x24808080); // rgba(128,128,128,.14)

  // Accents (constant across themes)
  static const lime = Color(0xFFD5F27A);
  static const yellow = Color(0xFFF5C842);
  static const indigo = Color(0xFF6C5CE7);
  static const teal = Color(0xFF14B8A6);
  static const green = Color(0xFF7BC143);
  static const red = Color(0xFFE5484D);
  static const amber = Color(0xFFF5A524);
  static const dangerTint = Color(0x1FE5484D); // rgba(229,72,77,.12)
  static const dangerText = Color(0xFFB4282D);

  // The one dark action card (same in both themes)
  static const actionCard = Color(0xFF1F1F21);
  static const actionCardText = Color(0xFFF3F3F5);
  static const actionCardMuted = Color(0xFFA3A3AD);
  static const actionCardSheet = Color(0xFF8E8E96);

  // Accent presets offered in Appearance settings (structure section 28).
  // Each keeps >= 4.5:1 with white text and >= 3:1 against light and dark cards.
  static const accentBlue = Color(0xFF2F6FED);
  static const accentPurple = indigo; // default primary
  static const accentGreen = Color(0xFF2A7F51);
  static const accentOrange = Color(0xFFBF5414);
  static const accentPink = Color(0xFFC2357A);
  static const accentTeal = Color(0xFF0B7C72);
}
