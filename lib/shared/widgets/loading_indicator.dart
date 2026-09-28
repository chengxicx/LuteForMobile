import 'package:flutter/material.dart';
import 'package:song_mobile/shared/theme/eink.dart';

class LoadingIndicator extends StatelessWidget {
  final String? message;

  const LoadingIndicator({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    // 旋转的进度圈在墨水屏上等于"每帧全屏刷新" —— 屏幕上看到的就是一直在抖。
    // 墨水屏模式下一律换静态文案。
    final eInk = context.eInk;

    // 主视觉只算一次：墨水屏拿文案顶替进度圈（没有 message 时退回
    // 'Loading...'），其余平台照旧画圈。
    final Widget primary = eInk
        ? Text(
            message ?? 'Loading...',
            style: Theme.of(context).textTheme.bodyMedium,
          )
        : const CircularProgressIndicator();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          primary,
          // 副文案只在非墨水屏追加。墨水屏的 primary 本身就是那句文案，
          // 以前这里不区分平台，于是墨水屏上同一句话画了两遍。
          if (!eInk && message != null) ...[
            const SizedBox(height: 16),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
