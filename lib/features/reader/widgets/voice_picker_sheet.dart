import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/tts_provider.dart';
import '../../../core/network/tts_service.dart';
import '../../../features/settings/models/tts_settings.dart';
import '../../../features/settings/providers/tts_settings_provider.dart';
import '../../../features/settings/widgets/edge_voice_picker.dart';
import '../../../shared/utils/tts_language_mapper.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/tts_player_provider.dart';

/// 播放条齿轮键弹出的音色选择面板。
///
/// 与设置页共用 [EdgeVoicePicker]（同一份 curated 表、同一个 config 字段）；
/// 点选写回 edge config → 服务整体重建 → [restartAfterServiceChange] 让正在
/// 朗读的当前句立刻用新音色重读。试听用当前 Edge 服务读一句该语种的例句。
Future<void> showVoicePickerSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (_) => const _VoicePickerSheet(),
  );
}

class _VoicePickerSheet extends ConsumerStatefulWidget {
  const _VoicePickerSheet();

  @override
  ConsumerState<_VoicePickerSheet> createState() => _VoicePickerSheetState();
}

class _VoicePickerSheetState extends ConsumerState<_VoicePickerSheet> {
  bool _previewing = false;

  /// 面板关心的两样东西：当前引擎是不是 Edge TTS，以及它的配置。引擎不是
  /// Edge 时齿轮键根本不会出现，这里再防一手只是兜底。
  TTSSettingsConfig? _edgeConfig(TTSSettings settings) =>
      settings.providerConfigs[TTSProvider.edgeTTS];

  Future<void> _onVoiceChanged(String? voice) async {
    final settings = ref.read(ttsSettingsProvider);
    final config =
        _edgeConfig(settings) ?? const TTSSettingsConfig();
    await ref
        .read(ttsSettingsProvider.notifier)
        .updateEdgeTTSConfig(config.copyWith(voice: voice ?? ''));
    if (!mounted) return;
    Navigator.of(context).pop();
    // 服务重建完成后重读当前句；不播放就不响，与“改设置页”的行为一致。
    unawaited(ref.read(ttsPlayerProvider.notifier).restartAfterServiceChange());
  }

  Future<void> _preview() async {
    if (_previewing) return;
    setState(() => _previewing = true);
    try {
      final service = ref.read(ttsServiceProvider);
      if (service is! EdgeTTSService) return;
      final sample = ttsSampleSentenceFor(service.languageCode);
      final bytes = await service.getAudioBytes(sample);
      await service.speakBytes(bytes);
    } catch (_) {
      // 试听失败不打断选音色：选中的值已经写回，正式朗读会如实报错。
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(ttsSettingsProvider);
    final playerState = ref.watch(
      ttsPlayerProvider.select((s) => (tag: s.languageTag)),
    );
    final config = _edgeConfig(settings);
    final scheme = context.appColorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Voice · ${playerState.tag ?? 'default'}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: scheme.text.headline,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Pick takes effect on the current sentence when playing.',
              style: TextStyle(
                fontSize: 12,
                color: scheme.text.secondary,
              ),
            ),
            const SizedBox(height: 16),
            EdgeVoicePicker(
              languageTag: playerState.tag ?? config?.languageCode,
              currentVoice: config?.voice,
              onVoiceChanged: _onVoiceChanged,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _previewing ? null : _preview,
              icon: _previewing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.volume_up, size: 18),
              label: const Text('Preview'),
            ),
          ],
        ),
      ),
    );
  }
}
