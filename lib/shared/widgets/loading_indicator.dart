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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (eInk)
            Text(
              message ?? 'Loading...',
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
