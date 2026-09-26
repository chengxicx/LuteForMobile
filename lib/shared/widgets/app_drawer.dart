import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:song_mobile/features/settings/providers/settings_provider.dart';
import '../theme/theme_extensions.dart';

/// Every top-level destination, in the order it is offered.
///
/// Shared by the drawer, the bottom navigation bar and the wide-screen rail so
/// the three cannot drift apart.
const List<({String route, IconData icon, String label})> kNavDestinations =
    <({String route, IconData icon, String label})>[
      (route: 'reader', icon: Icons.book, label: 'Reader'),
      (route: 'books', icon: Icons.collections_bookmark, label: 'Books'),
      (route: 'grammar', icon: Icons.spellcheck, label: 'Grammar'),
      (route: 'review', icon: Icons.style, label: 'Review'),
      (route: 'stats', icon: Icons.bar_chart, label: 'Stats'),
      (route: 'terms', icon: Icons.translate, label: 'Terms'),
      (route: 'help', icon: Icons.help_outline, label: 'Help'),
      (route: 'settings', icon: Icons.settings, label: 'Settings'),
    ];

/// Destinations that live on the primary navigation (the bottom bar on
/// narrow screens, the rail on wide ones).
///
/// Terms is drawer-only now -- it saw too little use for a main-page slot,
/// and its place went to Review, which the web version also carries in its
/// main menu.  The drawer is the only way to reach it.
const List<String> kPrimaryNavRoutes = <String>[
  'reader',
  'books',
  'grammar',
  'review',
  'stats',
  'help',
  'settings',
];

/// The context panel for the current screen, plus the destinations the bottom
/// navigation bar does *not* already offer.
///
/// It used to repeat the bar: an 80px rail holding the same five destinations
/// the bottom bar had, which both duplicated them and took a quarter of the
/// drawer's width off the settings panel -- the reason the text formatting
/// controls had to be crammed into a collapsed ExpansionTile.  The caller now
/// passes only the routes the bar cannot reach, so nothing is offered twice.
class AppDrawer extends ConsumerWidget {
  final String currentRoute;
  final Function(String) onNavigate;

  /// Routes to offer as chips at the bottom of the drawer.
  final List<String> routes;

  const AppDrawer({
    super.key,
    required this.currentRoute,
    required this.onNavigate,
    required this.routes,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsContent = ref.watch(currentViewDrawerSettingsProvider);

    return SizedBox(
      width: 320,
      child: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, settingsContent != null),
              const Divider(height: 1),
              if (settingsContent != null)
                Expanded(child: settingsContent)
              else
                const Spacer(),
              const Divider(height: 1),
              _buildNavigation(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 抽屉顶部标题。
  ///
  /// 面板是"当前屏幕的快捷设置"，名字必须带上屏幕前缀，否则会和底部
  /// 跳到全局设置页的 Settings chip 撞名（阅读页抽屉里曾上下各一个
  /// "Settings"）。Books 面板内部已有 "Book Settings" 小标题，这里只叫
  /// "Books" 避免再重复一层。
  String get _panelTitle => switch (currentRoute) {
    'reader' || 'sentence-reader' => 'Reader Settings',
    'books' => 'Books',
    _ => 'Settings',
  };

  Widget _buildHeader(BuildContext context, bool hasPanel) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Icon(
            hasPanel ? Icons.tune : Icons.menu,
            size: 18,
            color: context.appColorScheme.text.secondary,
          ),
          const SizedBox(width: 8),
          Text(
            hasPanel ? _panelTitle : 'Menu',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigation(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final route in routes) _buildNavChip(context, route),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return Text(
                  snapshot.data!.version,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    color: context.appColorScheme.text.primary.withValues(
                      alpha: 0.6,
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNavChip(BuildContext context, String route) {
    final index = kNavDestinations.indexWhere((d) => d.route == route);
    final destination = index == -1
        ? (route: route, icon: Icons.circle, label: route)
        : kNavDestinations[index];

    final isSelected = currentRoute == route;
    final color = isSelected
        ? context.m3Primary
        : context.appColorScheme.text.primary;

    return ActionChip(
      avatar: Icon(destination.icon, size: 16, color: color),
      label: Text(
        destination.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          color: color,
        ),
      ),
      backgroundColor: isSelected
          ? context.m3Primary.withValues(alpha: 0.12)
          : null,
      side: BorderSide(color: context.appColorScheme.border.dividerColor),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      onPressed: () {
        HapticFeedback.selectionClick();
        onNavigate(route);
        Navigator.of(context).pop();
      },
    );
  }
}
