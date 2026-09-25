import 'package:flutter/material.dart';
import 'hardware_key_navigator.dart';

/// 墨水屏设备的翻页键在第三方 app 里到底发什么键，每台机器、每种系统按键
/// 设置都可能不一样（音量键 or PageUp/PageDown，有没有 down 事件）。
///
/// 这个对话框把收到的原始 KeyEvent 摊开，用来确认
/// [HardwareKeyNavigator] 该接哪些 logicalKey。
class KeyDiagnosticsDialog extends StatefulWidget {
  const KeyDiagnosticsDialog({super.key});

  @override
  State<KeyDiagnosticsDialog> createState() => _KeyDiagnosticsDialogState();
}

class _KeyDiagnosticsDialogState extends State<KeyDiagnosticsDialog> {
  final List<String> _events = [];

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        final action = HardwareKeyNavigator.actionForKeyEvent(event);
        setState(() {
          _events.insert(
            0,
            '${event.runtimeType}  '
            '${event.logicalKey.debugName ?? event.logicalKey.keyLabel}  '
            '=> ${action?.name ?? 'ignored'}',
          );
        });
        // 只吞翻页相关的键；其他键（包括返回键）放行，否则对话框会
        // 把系统返回也拦下来，用户只能用 Close 按钮退出。
        return action != null ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: AlertDialog(
        title: const Text('Hardware keys'),
        content: SizedBox(
          width: double.maxFinite,
          child: _events.isEmpty
              ? const Text('Press a physical key (page-turn or volume)...')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _events
                      .take(8)
                      .map((e) => Text(e, style: const TextStyle(fontSize: 12)))
                      .toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
