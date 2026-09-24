import 'package:flutter/material.dart';
import 'theme_definitions.dart';

/// Dark theme preset - extracted from existing app colors (matches current darkTheme exactly)
final AppThemeColorScheme darkThemePreset = AppThemeColorScheme(
  text: const TextColors(
    primary: Color(0xFFE6E1E5),
    secondary: Color(0xFFCAC4D0),
    disabled: Color(0xFF938F99),
    headline: Color(0xFFE6E1E5),
    onPrimary: Color(0xFFFFFFFF),
    onSecondary: Color(0xFFFFFFFF),
    onPrimaryContainer: Color(0xFFEADDFF),
    onSecondaryContainer: Color(0xFFE8DEF8),
    onTertiary: Color(0xFFFFD8E4),
    onTertiaryContainer: Color(0xFFFFD8E4),
  ),
  background: const BackgroundColors(
    background: Color(0xFF48484a),
    surface: Color(0xFF1E1E1E),
    surfaceVariant: Color(0xFF2A2A2A),
    surfaceContainerHighest: Color(0xFF49454F),
  ),
  semantic: const SemanticColors(
    success: Color(0xFF419252),
    onSuccess: Color(0xFFFFFFFF),
    warning: Color(0xFFBA8050),
    onWarning: Color(0xFFFFFFFF),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    info: Color(0xFF8095FF),
    onInfo: Color(0xFFFFFFFF),
    connected: Color(0xFF419252),
    disconnected: Color(0xFFBA1A1A),
    aiProvider: Color(0xFF6750A4),
    localProvider: Color(0xFF1976D2),
  ),
  status: const StatusColors(
    // 状态色按"色相环分段"选取，不再用 alpha 稀释。
    // 目标：任意两档 CIE76 ΔE >= 25，且每档与其上的文字对比度 >= 4.5。
    // 深色主题背景为 #48484A，因此这里用高亮度色。
    status0: Color(0xFF9E8FE8), // Unknown   —— 紫
    status1: Color(0xFFEE9AAE), // Learning1 —— 玫红
    status2: Color(0xFFF0A96B), // Learning2 —— 赭橙
    status3: Color(0xFFD8CC62), // Learning3 —— 橄榄
    status4: Color(0xFF6FCEB4), // Learning4 —— 松绿
    status5: Color(0xFF8FB6F0), // Learning5 —— 靛蓝
    status98: Color(0xFFB0B0B6), // Ignored   —— 中性灰
    status99: Color(0xFF5FC474), // WellKnown —— 绿
    highlightedText: Color(0xFF1C1B1F), // 亮底配深字
    wordGlowColor: Color(0xFFFFD700),
    multiTermSelectionColor: Color(0xFFEE8B2F),
  ),
  border: const BorderColors(
    outline: Color(0xFF938F99),
    outlineVariant: Color(0xFF49454F),
    dividerColor: Color(0xFF49454F),
  ),
  audio: const AudioColors(
    background: Color(0xFF6750A4),
    icon: Color(0xFFFFFFFF),
    bookmark: Color(0xFFFFA000),
    error: Color(0xFFD32F2F),
    errorBackground: Color(0x33FFCDD2),
  ),
  error: const ErrorColors(
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
  ),
  material3: const Material3ColorScheme(
    primary: Color(0xFF6750A4),
    secondary: Color(0xFF625B71),
    tertiary: Color(0xFF633B48),
    primaryContainer: Color(0xFF4F378B),
    secondaryContainer: Color(0xFF4A4458),
    tertiaryContainer: Color(0xFF8E7266),
  ),
);

/// Light theme preset - matches current lightTheme exactly
final AppThemeColorScheme lightThemePreset = AppThemeColorScheme(
  text: const TextColors(
    primary: Color(0xFF1C1B1F),
    secondary: Color(0xFF49454F),
    disabled: Color(0xFF938F99),
    headline: Color(0xFF1C1B1F),
    onPrimary: Color(0xFFFFFFFF),
    onSecondary: Color(0xFFFFFFFF),
    onPrimaryContainer: Color(0xFF21005D),
    onSecondaryContainer: Color(0xFF1D192B),
    onTertiary: Color(0xFFFFFFFF),
    onTertiaryContainer: Color(0xFF31111D),
  ),
  background: const BackgroundColors(
    background: Color(0xFFFFFBFE),
    surface: Color(0xFFFFFBFE),
    surfaceVariant: Color(0xFFE7E0EC),
    surfaceContainerHighest: Color(0xFFE7E0EC),
  ),
  semantic: const SemanticColors(
    success: Color(0xFF419252),
    onSuccess: Color(0xFFFFFFFF),
    warning: Color(0xFFBA8050),
    onWarning: Color(0xFFFFFFFF),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    info: Color(0xFF8095FF),
    onInfo: Color(0xFFFFFFFF),
    connected: Color(0xFF419252),
    disconnected: Color(0xFFBA1A1A),
    aiProvider: Color(0xFF6750A4),
    localProvider: Color(0xFF1976D2),
  ),
  status: const StatusColors(
    // 与深色主题同一套色相顺序，但压低亮度以便白字可读。
    // 任意两档 CIE76 ΔE >= 25；白字对比度 >= 4.5；色/页面底对比度 >= 3。
    status0: Color(0xFF7B4BA8), // Unknown   —— 紫
    status1: Color(0xFFA8384F), // Learning1 —— 玫红
    status2: Color(0xFFA8541A), // Learning2 —— 赭橙
    status3: Color(0xFF6E5F0E), // Learning3 —— 橄榄
    status4: Color(0xFF26655A), // Learning4 —— 松绿
    status5: Color(0xFF2F5C99), // Learning5 —— 靛蓝
    status98: Color(0xFF6B6B72), // Ignored   —— 中性灰
    status99: Color(0xFF2E7D46), // WellKnown —— 绿
    highlightedText: Color(0xFFFFFFFF), // 深底配白字
    wordGlowColor: Color(0xFFFFA500),
    multiTermSelectionColor: Color(0xFFD87414),
  ),
  border: const BorderColors(
    outline: Color(0xFF79747E),
    outlineVariant: Color(0xFFCAC4D0),
    dividerColor: Color(0xFFCAC4D0),
  ),
  audio: const AudioColors(
    background: Color(0xFF6750A4),
    icon: Color(0xFFFFFFFF),
    bookmark: Color(0xFFFFA000),
    error: Color(0xFFD32F2F),
    errorBackground: Color(0x33FFCDD2),
  ),
  error: const ErrorColors(
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
  ),
  material3: const Material3ColorScheme(
    primary: Color(0xFF6750A4),
    secondary: Color(0xFF625B71),
    tertiary: Color(0xFF7D5260),
    primaryContainer: Color(0xFFEADDFF),
    secondaryContainer: Color(0xFFE8DEF8),
    tertiaryContainer: Color(0xFFFFD8E4),
  ),
);

/// Black and White theme preset - optimized for black and white screens
final AppThemeColorScheme blackAndWhiteThemePreset = AppThemeColorScheme(
  text: const TextColors(
    primary: Color(0xFF000000),
    secondary: Color(0xFF666666),
    disabled: Color(0xFF999999),
    headline: Color(0xFF000000),
    onPrimary: Color(0xFFFFFFFF),
    onSecondary: Color(0xFFFFFFFF),
    onPrimaryContainer: Color(0xFF000000),
    onSecondaryContainer: Color(0xFF000000),
    onTertiary: Color(0xFFFFFFFF),
    onTertiaryContainer: Color(0xFF000000),
  ),
  background: const BackgroundColors(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceVariant: Color(0xFFEEEEEE),
    surfaceContainerHighest: Color(0xFFEEEEEE),
  ),
  semantic: const SemanticColors(
    success: Color(0xFF666666),
    onSuccess: Color(0xFFFFFFFF),
    warning: Color(0xFF666666),
    onWarning: Color(0xFFFFFFFF),
    error: Color(0xFF000000),
    onError: Color(0xFFFFFFFF),
    info: Color(0xFF666666),
    onInfo: Color(0xFFFFFFFF),
    connected: Color(0xFF000000),
    disconnected: Color(0xFF000000),
    aiProvider: Color(0xFF000000),
    localProvider: Color(0xFF000000),
  ),
  status: const StatusColors(
    // 墨水屏只有灰阶，无法靠色相区分，因此改用"明度梯度"。
    // 约束：8 档必须互不相同，且每档上的白字（highlightedText）对比度 >= 4.5。
    // 白字可读要求底色相对亮度 <= 0.175（灰阶约 #707070），故可用区间为
    // L* 0~47；在此区间内取 8 级。
    // 语义沿用"越熟越浅"：Unknown 最深最醒目，WellKnown 最浅最不打扰。
    // 注意：纯灰阶下相邻档 ΔE 约 6，达不到彩色主题的 25，
    // 墨水屏上需配合状态文字标签（term_form 的状态选择器已带标签）。
    status0: Color(0xFF000000), // Unknown   —— 最深
    status1: Color(0xFF1A1A1A), // Learning1
    status2: Color(0xFF282828), // Learning2
    status3: Color(0xFF363636), // Learning3
    status4: Color(0xFF444444), // Learning4
    status5: Color(0xFF525252), // Learning5
    status98: Color(0xFF606060), // Ignored
    status99: Color(0xFF6E6E6E), // WellKnown —— 最浅（白字对比度 5.10，已接近下限）
    highlightedText: Color(0xFFFFFFFF),
    wordGlowColor: Color(0xFF999999),
    multiTermSelectionColor: Color(0xFF2B2B2B),
  ),
  border: const BorderColors(
    outline: Color(0xFF999999),
    outlineVariant: Color(0xFFCCCCCC),
    dividerColor: Color(0xFFCCCCCC),
  ),
  audio: const AudioColors(
    background: Color(0xFF000000),
    icon: Color(0xFFFFFFFF),
    bookmark: Color(0xFF333333),
    error: Color(0xFF000000),
    errorBackground: Color(0x11000000),
  ),
  error: const ErrorColors(
    error: Color(0xFF000000),
    onError: Color(0xFFFFFFFF),
  ),
  material3: const Material3ColorScheme(
    primary: Color(0xFF000000),
    secondary: Color(0xFF666666),
    tertiary: Color(0xFF333333),
    primaryContainer: Color(0xFFEEEEEE),
    secondaryContainer: Color(0xFFEEEEEE),
    tertiaryContainer: Color(0xFFEEEEEE),
  ),
);
