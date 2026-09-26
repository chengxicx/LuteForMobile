import 'package:flutter/material.dart';

import '../../../../shared/theme/player_palette.dart';

/// 播放条的时间轴:两端时间标签 + 圆角滑轨(MP3 条另有书签刻度)。
///
/// 时间不再叠在滑轨上,放不下的信息交给 [centerLabel](TTS 条的句子 n/N)。
/// 几何与配色取自 [PlayerPalette]:墨水屏下轨道加粗(4→6)、滑块加大
/// (7→9)、未播段用实灰而不是 30% 透明(半透明在 16 级灰阶里会整档消失)。
class PlayerTimeline extends StatefulWidget {
  final Duration position;
  final Duration total;

  /// 显示在时间行中间的小标签,如 "3/25"(TTS 条的句子进度)。
  final String? centerLabel;

  /// MP3 书签刻度的时间点;空列表则不画刻度。
  final List<Duration> bookmarks;

  /// 拖动结束时回调(松手才 seek,拖动中只更新本地预览值)。
  final ValueChanged<Duration> onSeekEnd;

  const PlayerTimeline({
    super.key,
    required this.position,
    required this.total,
    required this.onSeekEnd,
    this.centerLabel,
    this.bookmarks = const [],
  });

  @override
  State<PlayerTimeline> createState() => _PlayerTimelineState();
}

class _PlayerTimelineState extends State<PlayerTimeline> {
  bool _isDragging = false;
  double? _dragSeconds;

  /// 滑轨行的固定高度:要装得下滑块(墨水屏 9px 半径)与书签刻度。
  static const double _sliderHeight = 30.0;

  @override
  Widget build(BuildContext context) {
    final palette = context.playerPalette;
    final totalSeconds = widget.total.inMilliseconds / 1000.0;
    final positionSeconds = widget.position.inMilliseconds / 1000.0;
    final maxSeconds = totalSeconds > 0 ? totalSeconds : 1.0;

    double sliderValue = _isDragging
        ? (_dragSeconds ?? positionSeconds)
        : positionSeconds;
    if (sliderValue > maxSeconds) sliderValue = maxSeconds;
    final displayPosition = Duration(milliseconds: (sliderValue * 1000).round());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _timeLabel(context, _formatDuration(displayPosition)),
            if (widget.centerLabel != null)
              Expanded(
                child: Center(
                  child: Text(
                    widget.centerLabel!,
                    style: _labelStyle(context),
                  ),
                ),
              )
            else
              const Spacer(),
            _timeLabel(context, _formatDuration(widget.total)),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            height: _sliderHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: palette.trackHeight,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: palette.thumbRadius,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: palette.overlayRadius,
                    ),
                    activeTrackColor: palette.trackActive,
                    inactiveTrackColor: palette.trackInactive,
                    thumbColor: palette.thumb,
                    overlayColor: palette.overlay,
                  ),
                  child: Slider(
                    value: sliderValue,
                    min: 0.0,
                    max: maxSeconds,
                    onChanged: (value) => setState(() {
                      _isDragging = true;
                      _dragSeconds = value;
                    }),
                    onChangeEnd: (value) => setState(() {
                      _isDragging = false;
                      _dragSeconds = null;
                      widget.onSeekEnd(
                        Duration(milliseconds: (value * 1000).round()),
                      );
                    }),
                  ),
                ),
                if (widget.bookmarks.isNotEmpty)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _BookmarkTickPainter(
                          bookmarks: widget.bookmarks,
                          total: totalSeconds,
                          // 与上面 SliderTheme 的 overlayRadius 同源:Material
                          // 滑轨两侧各内缩一个 overlay 半径,刻度必须用同一
                          // 几何,否则刻度和真实时间对不上。
                          trackInset: palette.overlayRadius,
                          color: palette.bookmark,
                          activeColor: palette.bookmarkOnActive,
                          playedFraction: (sliderValue / maxSeconds).clamp(
                            0.0,
                            1.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _timeLabel(BuildContext context, String text) {
    return Text(text, style: _labelStyle(context));
  }

  TextStyle _labelStyle(BuildContext context) {
    final palette = context.playerPalette;
    return TextStyle(
      color: palette.muted,
      fontSize: palette.labelFontSize,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return hours != '00' ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

/// 沿滑轨画的书签刻度。轨道两端各内缩 [trackInset](overlay 半径),
/// 刻度的 x 与滑块中心用同一公式:x = inset + fraction * (width - 2*inset)。
class _BookmarkTickPainter extends CustomPainter {
  final List<Duration> bookmarks;
  final double total;
  final double trackInset;
  final Color color;

  /// 刻度落在**已播段**上时改用的颜色。彩色模式下与 [color] 相同，
  /// 墨水屏下是反色的白 —— 否则黑刻度压在黑的已播轨上会整条看不见。
  final Color activeColor;

  /// 当前播放进度（0..1），用来判断每条刻度落在哪一段。
  final double playedFraction;

  _BookmarkTickPainter({
    required this.bookmarks,
    required this.total,
    required this.trackInset,
    required this.color,
    required this.activeColor,
    required this.playedFraction,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final paint = Paint();
    final lane = size.width - 2 * trackInset;
    for (final bookmark in bookmarks) {
      final fraction = bookmark.inMilliseconds / 1000.0 / total;
      final clamped = fraction.clamp(0.0, 1.0);
      final x = trackInset + clamped * lane;
      paint.color = clamped <= playedFraction ? activeColor : color;
      final rect = Rect.fromLTWH(x - 1.5, 10, 3, size.height - 20);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BookmarkTickPainter oldDelegate) {
    return oldDelegate.bookmarks != bookmarks ||
        oldDelegate.total != total ||
        oldDelegate.color != color ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.playedFraction != playedFraction;
  }
}
