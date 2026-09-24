import 'package:flutter/material.dart';
import 'theme_definitions.dart';
import 'theme_presets.dart';
import 'app_theme.dart';

extension BuildContextExtension on BuildContext {
  AppThemeColorScheme get appColorScheme {
    final extension = Theme.of(this).extension<AppThemeColorExtension>();
    return extension?.colorScheme ?? darkThemePreset;
  }

  Map<int, StatusMode> get statusModes {
    final extension = Theme.of(this).extension<AppThemeColorExtension>();
    return extension?.statusModes ?? defaultStatusModes();
  }

  Color get audioPlayerBackground => appColorScheme.audio.background;
  Color get audioPlayerIcon => appColorScheme.audio.icon;
  Color get audioBookmark => appColorScheme.audio.bookmark;
  Color get audioError => appColorScheme.audio.error;
  Color get audioErrorBackground => appColorScheme.audio.errorBackground;

  /// Background of the line the player is currently reading, drawn in the
  /// reading text itself so the reader can follow along there and not only in
  /// the player bar.
  ///
  /// A tint of [audioBookmark] composited over the page background rather
  /// than a translucent colour: the block has to be one solid mark (a word's
  /// own status colour is replaced by it), and compositing here is what lets
  /// [playingLineText] be picked against the real thing.  Amber on the colour
  /// themes, grey on the monochrome one.  At 28% the block sits ~27 ΔE from
  /// the light page background, ~33 from the dark one and ~20 from the
  /// monochrome one -- see test/palette_contrast_test.dart.
  Color get playingLineHighlight => Color.alphaBlend(
    audioBookmark.withValues(alpha: 0.28),
    appColorScheme.background.background,
  );

  /// Text colour for words on the playing line.
  ///
  /// The per-word status text colours are chosen against the status swatches,
  /// which the playing block replaces: the dark theme's status text is
  /// near-black and its block is mid-brown, so a status word left alone would
  /// go dark-on-dark.  The page's own text colour is legible on all three
  /// themes' blocks (>= 4.5:1), and the whole line reading in one colour is
  /// what makes the mark read as a single line.
  Color get playingLineText => appColorScheme.text.primary;

  Color get status1 => appColorScheme.status.status1;
  Color get status2 => appColorScheme.status.status2;
  Color get status3 => appColorScheme.status.status3;
  Color get status4 => appColorScheme.status.status4;
  Color get status5 => appColorScheme.status.status5;
  Color get status98 => appColorScheme.status.status98;
  Color get status99 => appColorScheme.status.status99;
  Color get status0 => appColorScheme.status.status0;
  Color get wordGlowColor => appColorScheme.status.wordGlowColor;
  Color get multiTermSelectionColor =>
      appColorScheme.status.multiTermSelectionColor;

  Color get success => appColorScheme.semantic.success;
  Color get warning => appColorScheme.semantic.warning;
  Color get error => appColorScheme.error.error;
  Color get info => appColorScheme.semantic.info;

  Color get connected => appColorScheme.semantic.connected;
  Color get disconnected => appColorScheme.semantic.disconnected;

  Color get aiProvider => appColorScheme.semantic.aiProvider;
  Color get localProvider => appColorScheme.semantic.localProvider;

  Color get m3Primary => appColorScheme.material3.primary;
  Color get m3Secondary => appColorScheme.material3.secondary;
  Color get m3Tertiary => appColorScheme.material3.tertiary;
  Color get m3PrimaryContainer => appColorScheme.material3.primaryContainer;
  Color get m3SecondaryContainer => appColorScheme.material3.secondaryContainer;
  Color get m3TertiaryContainer => appColorScheme.material3.tertiaryContainer;

  Color getStatusTextColor(String status) {
    final statusNum = int.tryParse(status);
    if (statusNum == null) return appColorScheme.text.primary;
    final mode = statusModes[statusNum] ?? StatusMode.background;
    final statusColor = getStatusColor(status);

    if (mode == StatusMode.none) {
      return appColorScheme.text.primary;
    }
    if (mode == StatusMode.text) {
      return statusColor;
    }
    return appColorScheme.status.highlightedText;
  }

  Color? getStatusBackgroundColor(String status) {
    final statusNum = int.tryParse(status) ?? 0;
    final mode = statusModes[statusNum] ?? StatusMode.background;
    if (mode != StatusMode.background) return null;
    return getStatusColor(status);
  }

  Color getStatusColor(String status) {
    switch (status) {
      case '1':
        return appColorScheme.status.status1;
      case '2':
        return appColorScheme.status.status2;
      case '3':
        return appColorScheme.status.status3;
      case '4':
        return appColorScheme.status.status4;
      case '5':
        return appColorScheme.status.status5;
      case '98':
        return appColorScheme.status.status98;
      case '99':
        return appColorScheme.status.status99;
      case '0':
      default:
        return appColorScheme.status.status0;
    }
  }

  Color getStatusColorWithOpacity(String status, {double opacity = 0.1}) {
    return getStatusColor(status).withValues(alpha: opacity);
  }

  /// Always returns a visible status swatch color for charts/legends/stats.
  Color getStatusColorForVisualization(String status) {
    final color = getStatusColor(status);
    return color.a == 0 ? color.withValues(alpha: 1.0) : color;
  }
}

extension AppTextThemeExtension on TextTheme {
  TextStyle get statusBadge {
    return const TextStyle(fontSize: 12, fontWeight: FontWeight.w500);
  }

  TextStyle get providerBadge {
    return const TextStyle(fontSize: 10, fontWeight: FontWeight.w600);
  }
}
