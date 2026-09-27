import 'package:flutter/material.dart';

/// The horizontal-flick page-turn state machine shared by MangaPageView
/// and PdfPageView.
///
/// At 1x a deliberate horizontal flick turns the page.  Zoomed in, a
/// flick pans -- unless the view already sat at the horizontal pan
/// boundary in the swipe direction when the finger went down, where
/// there is nothing left to pan and the flick means "turn the page" (the
/// Tachiyomi rule).  The InteractiveViewer clamps the translation so the
/// child's edges never come inside the viewport: 0 is the left boundary,
/// viewportWidth - childWidth * scale the right one.
///
/// A [Listener] sees raw pointer events without entering the gesture
/// arena, so it coexists with the InteractiveViewer's pan and the words'
/// tap recognizers inside [child].  Tap zones (which third of the page
/// was tapped) are the child's business -- they need the child's own
/// geometry -- while flicks are handled here.
class PageTurnFlickListener extends StatefulWidget {
  final Widget child;
  final TransformationController transformation;
  final void Function(bool forward)? onTurnPage;

  const PageTurnFlickListener({
    super.key,
    required this.child,
    required this.transformation,
    this.onTurnPage,
  });

  @override
  State<PageTurnFlickListener> createState() => _PageTurnFlickListenerState();
}

class _PageTurnFlickListenerState extends State<PageTurnFlickListener> {
  /// Viewport width of the listener (its own LayoutBuilder constraints),
  /// for the zoomed-in swipe boundary math in [_onPointerUp].
  double _viewportWidth = 0;

  /// Active pointer count and whether more than one pointer joined the
  /// current gesture.  A pinch must never read as a horizontal flick:
  /// its fingers travel far more than the flick threshold, and at 1x
  /// the release would otherwise turn the page mid-zoom.
  int _activePointers = 0;
  bool _gestureIsMultiPointer = false;

  /// Pan offset at the moment the first finger went down.  The zoomed-in
  /// turn decision uses this, not the release-time value: the flick
  /// itself pans the view, so by pointer-up it may have carried the view
  /// to the boundary.  Only a flick that STARTS at the boundary turns.
  double _txAtDown = 0;

  /// Where the active pointer went down, for the horizontal page-turn
  /// flick.
  Offset? _swipeStart;

  void _onPointerDown(PointerDownEvent event) {
    _activePointers++;
    if (_activePointers > 1) {
      _gestureIsMultiPointer = true;
    } else {
      _gestureIsMultiPointer = false;
      _swipeStart = event.position;
      _txAtDown = widget.transformation.value.storage[12];
    }
  }

  /// Drop the current gesture without a flick decision (pointer
  /// cancelled by the system, e.g. when another app gesture claims it).
  void _discardGesture() {
    _activePointers = (_activePointers - 1).clamp(0, 2);
    if (_activePointers == 0) _swipeStart = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers = (_activePointers - 1).clamp(0, 2);
    if (_activePointers > 0) return; // a pinch finger lifted first
    final start = _swipeStart;
    _swipeStart = null;
    if (_gestureIsMultiPointer) return; // pinch, not a flick
    if (start == null || widget.onTurnPage == null) return;
    final dx = event.position.dx - start.dx;
    final dy = event.position.dy - start.dy;
    // A deliberate horizontal flick, not a scroll or a tap.
    if (dx.abs() < 70 || dx.abs() < dy.abs() * 1.5) return;
    final scale = widget.transformation.value.getMaxScaleOnAxis();
    if (scale <= 1.01) {
      widget.onTurnPage!(dx < 0);
      return;
    }
    const tolerance = 4.0;
    if (dx < 0) {
      if (_txAtDown <= _viewportWidth - _viewportWidth * scale + tolerance) {
        widget.onTurnPage!(true);
      }
    } else {
      if (_txAtDown >= -tolerance) {
        widget.onTurnPage!(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerUp: _onPointerUp,
          onPointerCancel: (_) => _discardGesture(),
          child: widget.child,
        );
      },
    );
  }
}
