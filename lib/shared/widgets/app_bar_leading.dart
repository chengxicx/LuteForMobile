import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app.dart';
import '../../core/network/session_manager.dart';
import '../providers/server_status_provider.dart';
import '../providers/global_loading_provider.dart';
import '../theme/theme_extensions.dart';

/// Help / Settings 这两屏的"返回"按钮。
///
/// 它们是 IndexedStack 切页而不是 Navigator push，底栏在这两屏整体隐藏，
/// 系统返回键又只会退出 App —— 不提供显式返回入口就只能开抽屉找 Reader，
/// 路径太深。点击（或系统返回键，见各屏的 PopScope）回到进入前的主页面。
class BackToMainButton extends ConsumerWidget {
  const BackToMainButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // watch 响应式 provider：按钮随 IndexedStack 在启动时就构建，之后切 tab
    // 不会重建，读普通字段会一直拿到启动时的旧值。
    final target = ref.watch(lastMainRouteProvider);
    final label = switch (target) {
      'books' => 'Books',
      'grammar' => 'Grammar',
      'terms' => 'Terms',
      'stats' => 'Stats',
      _ => 'Reader',
    };
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      tooltip: 'Back to $label',
      onPressed: () {
        HapticFeedback.selectionClick();
        ref.read(navigationProvider).navigateToScreen(target);
      },
    );
  }
}

class AppBarLeading extends ConsumerWidget {
  final GlobalKey<ScaffoldState>? scaffoldKey;

  const AppBarLeading({super.key, this.scaffoldKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoading = ref.watch(globalLoadingProvider);
    final isReachable = ref.watch(serverStatusProvider).isReachable;
    final sessionStatus = ref.watch(sessionProvider).status;

    // 宽屏用常驻 rail，没有抽屉。状态图标仍然要有（点它去 Settings 修配置），
    // 但普通汉堡按钮不该出现 —— 一个点了什么都不发生的按钮比没有更糟。
    if (!_hasDrawer(context)) {
      if (!isReachable) {
        return IconButton(
          icon: const Icon(Icons.warning),
          color: context.appColorScheme.error.error,
          tooltip: 'Server unreachable',
          onPressed: () => _openSettings(ref),
        );
      }
      if (sessionStatus == SessionStatus.loginRequired) {
        return IconButton(
          icon: const Icon(Icons.person_off),
          color: context.appColorScheme.semantic.warning,
          tooltip: 'Session expired',
          onPressed: () => _openSettings(ref),
        );
      }
      return const SizedBox.shrink();
    }

    // Error state takes priority
    if (!isReachable) {
      return IconButton(
        icon: const Icon(Icons.warning),
        color: context.appColorScheme.error.error,
        onPressed: () => _openDrawer(context),
      );
    }

    // Multi-user session expired / not logged in.
    if (sessionStatus == SessionStatus.loginRequired) {
      return IconButton(
        icon: const Icon(Icons.person_off),
        color: context.appColorScheme.semantic.warning,
        onPressed: () => _openDrawer(context),
      );
    }

    // Loading state - spinner overlay on hamburger
    if (isLoading) {
      return Stack(
        alignment: Alignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => _openDrawer(context),
          ),
          const IgnorePointer(child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      );
    }

    // Normal state - hamburger menu
    return IconButton(
      icon: const Icon(Icons.menu),
      onPressed: () => _openDrawer(context),
    );
  }

  bool _hasDrawer(BuildContext context) {
    final state = scaffoldKey?.currentState;
    if (state != null) return state.hasDrawer;
    return Scaffold.maybeOf(context)?.hasDrawer ?? false;
  }

  void _openDrawer(BuildContext context) {
    final state = scaffoldKey?.currentState;
    if (state != null) {
      if (state.hasDrawer) state.openDrawer();
      return;
    }
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.hasDrawer == true) scaffold!.openDrawer();
  }

  /// Where there is no drawer to open, the status icons still need somewhere
  /// useful to go: both conditions are fixed in Settings.
  void _openSettings(WidgetRef ref) {
    ref.read(navigationProvider).navigateToScreen('settings');
  }
}
