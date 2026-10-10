import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/edge_tts_voices.dart';

/// Edge TTS 音色选择器：**默认** + 按语言过滤的常用音色 chips + 自定义输入。
///
/// 设置页与播放条的音色面板共用这一份：两处看到、写进的是同一个 config
/// 字段（edge config 的 `voice`），选中即回调，不在这里做持久化。
/// 「默认」用空串表达（`copyWith` 语义下清不掉字段，空串由服务层归一化为
/// 不带 `?voice=`，与服务端默认音色等价）。
class EdgeVoicePicker extends StatefulWidget {
  /// 过滤 curated 列表用的 BCP-47 标签（如 `ja-JP`）。只取主子标签。
  final String? languageTag;

  /// 当前生效的音色名；null/空 = 服务端默认。
  final String? currentVoice;

  final ValueChanged<String?> onVoiceChanged;

  const EdgeVoicePicker({
    super.key,
    required this.languageTag,
    required this.currentVoice,
    required this.onVoiceChanged,
  });

  @override
  State<EdgeVoicePicker> createState() => _EdgeVoicePickerState();
}

class _EdgeVoicePickerState extends State<EdgeVoicePicker> {
  late final TextEditingController _customController;

  String get _effectiveVoice => widget.currentVoice?.trim() ?? '';

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController(text: _effectiveVoice);
  }

  @override
  void didUpdateWidget(EdgeVoicePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部状态变了（例如面板外又改了一次），文本框跟着走；用户正在输入时
    // 不打扰 —— 只有文字确实与生效值脱节才重置。
    if (widget.currentVoice?.trim() != _customController.text.trim() &&
        _customController.text.trim() != _effectiveVoice) {
      _customController.text = _effectiveVoice;
    }
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final voices = edgeVoicesForLanguage(widget.languageTag);
    final current = _effectiveVoice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _voiceChip(
              label: 'Default',
              selected: current.isEmpty,
              onTap: () => widget.onVoiceChanged(null),
            ),
            for (final v in voices)
              _voiceChip(
                label: v.label,
                selected: current == v.name,
                onTap: () => widget.onVoiceChanged(v.name),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _customController,
          decoration: InputDecoration(
            labelText: 'Custom voice',
            hintText: 'e.g., ja-JP-KeitaNeural',
            border: const OutlineInputBorder(),
            helperText: voices.isEmpty
                ? 'No curated voices for this language; enter a full '
                    'edge-tts voice name'
                : 'Anything outside the list above',
          ),
          onSubmitted: (value) {
            final trimmed = value.trim();
            widget.onVoiceChanged(trimmed.isEmpty ? null : trimmed);
          },
        ),
      ],
    );
  }

  Widget _voiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = context.appColorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.material3.primaryContainer : null,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? scheme.material3.primary
                : scheme.border.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected
                ? scheme.text.onPrimaryContainer
                : scheme.text.primary,
          ),
        ),
      ),
    );
  }
}

/// 自定义音色在 curated 表里找不到时的展示名。
String edgeVoiceDisplayLabel(String? voice) {
  final trimmed = voice?.trim() ?? '';
  if (trimmed.isEmpty) return 'Default';
  // 音色名首段就是语言主子标签（"ja-JP-KeitaNeural" -> "ja"）。
  final voices = edgeVoicesForLanguage(
    trimmed.split('-').first,
  );
  for (final v in voices) {
    if (v.name == trimmed) return v.label;
  }
  return edgeVoiceShortLabel(trimmed);
}
