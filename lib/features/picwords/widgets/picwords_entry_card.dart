import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/eink_scope.dart';
import '../../../shared/widgets/option_card.dart';
import '../../settings/providers/settings_provider.dart';
import '../models/picwords_state.dart';
import '../providers/picwords_provider.dart';

/// Review 落地页上的第二个入口：Web 端插件 lute-picwords（看图背单词）。
///
/// 三态：
///  * 服务器**确实**没装插件（404）→ 整卡不显示（确定的「没有」，露出一个
///    永远点不动的卡只是噪声）；
///  * 探测中 / 问不到（断网、会话过期、5xx）→ 禁用卡 + 原因 + Retry，
///    因为这些都能自愈，藏掉会让人以为功能消失了；
///  * 可用 → 可点，交给 [onOpen]。
class PicWordsEntryCard extends ConsumerStatefulWidget {
  final VoidCallback onOpen;

  const PicWordsEntryCard({super.key, required this.onOpen});

  @override
  ConsumerState<PicWordsEntryCard> createState() => _PicWordsEntryCardState();
}

class _PicWordsEntryCardState extends ConsumerState<PicWordsEntryCard> {
  @override
  void initState() {
    super.initState();
    // 必须在 postFrame 里改 provider：在 build/initState 期间写 provider 会被
    // Riverpod 判成「during widget tree build」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(picWordsProvider.notifier)
            .ensureProbed(serverUrl: ref.read(settingsProvider).serverUrl),
      );
    });
  }

  void _retry() {
    unawaited(
      ref
          .read(picWordsProvider.notifier)
          .probe(serverUrl: ref.read(settingsProvider).serverUrl),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(picWordsProvider);
    if (state.isNotInstalled) return const SizedBox.shrink();

    final eInk = context.eInk;
    final checking = state.isChecking;
    final available = state.isAvailable;

    return OptionCard(
      icon: Icons.photo_library_outlined,
      title: 'Picture Words',
      subtitle: switch (state.availability) {
        PicWordsAvailability.available => 'Learn words from pictures · 看图背单词',
        PicWordsAvailability.unknown ||
        PicWordsAvailability.checking => 'Checking the server \u2026',
        _ => state.message ?? 'Could not check the server.',
      },
      trailing: checking
          ? (eInk
                ? null
                : const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ))
          : available
          ? const Icon(Icons.chevron_right)
          : TextButton(onPressed: _retry, child: const Text('Retry')),
      // 探测结果不是「可用」时整卡禁用：半成品页面比一个明确的 Retry 更糟。
      onTap: available ? widget.onOpen : null,
    );
  }
}
