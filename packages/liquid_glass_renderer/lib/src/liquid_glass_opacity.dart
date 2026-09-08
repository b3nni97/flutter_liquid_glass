import 'package:flutter/widgets.dart';

/// An inherited widget that provides an opacity value to descendant
/// [LiquidGlassLayer] widgets.
///
/// This is used internally by [LiquidGlassOpacity] and
/// [LiquidGlassAnimatedOpacity] to communicate the opacity value down the
/// tree without creating a save layer, which would break the
/// [BackdropFilterLayer] used by the glass effect.
class GlassOpacityScope extends InheritedWidget {
  /// Creates a [GlassOpacityScope] with the given [opacity].
  const GlassOpacityScope({
    super.key,
    required this.opacity,
    required super.child,
  }) : assert(opacity >= 0.0 && opacity <= 1.0);

  /// The opacity value (0.0 to 1.0) to apply to descendant glass layers.
  final double opacity;

  /// Retrieves the opacity from the nearest [GlassOpacityScope] ancestor.
  ///
  /// Returns null if no [GlassOpacityScope] is found.
  static double? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<GlassOpacityScope>()
        ?.opacity;
  }

  /// Retrieves the opacity from the nearest [GlassOpacityScope] ancestor.
  ///
  /// Returns 1.0 if no [GlassOpacityScope] is found.
  static double of(BuildContext context) {
    return maybeOf(context) ?? 1.0;
  }

  @override
  bool updateShouldNotify(GlassOpacityScope oldWidget) =>
      opacity != oldWidget.opacity;
}

/// A widget that applies opacity to descendant [LiquidGlassLayer] widgets
/// without creating a save layer.
///
/// Unlike Flutter's built-in [Opacity] widget, this widget does not create an
/// [OpacityLayer], which would break the [BackdropFilterLayer] used by the
/// glass shader. Instead, the opacity value is passed to the shader as a
/// uniform and applied during compositing.
///
/// {@tool snippet}
/// ```dart
/// LiquidGlassOpacity(
///   opacity: 0.5,
///   child: LiquidGlassLayer(
///     settings: const LiquidGlassSettings(),
///     child: LiquidGlass.inLayer(
///       shape: const RoundedRectangleBorder(),
///       child: const SizedBox(width: 100, height: 100),
///     ),
///   ),
/// )
/// ```
/// {@end-tool}
class LiquidGlassOpacity extends StatelessWidget {
  /// Creates a [LiquidGlassOpacity] widget.
  const LiquidGlassOpacity({
    super.key,
    required this.opacity,
    this.alwaysIncludeSemantics = false,
    required this.child,
  }) : assert(opacity >= 0.0 && opacity <= 1.0);

  /// The fraction of the child widget to show (0.0 to 1.0).
  ///
  /// A value of 1.0 means fully visible; 0.0 means fully transparent.
  final double opacity;

  /// Whether to always include the child in the semantics tree.
  ///
  /// When false and [opacity] is 0.0, the child is excluded from the
  /// semantics tree. This mirrors the behavior of [Opacity].
  final bool alwaysIncludeSemantics;

  /// The widget below this widget in the tree.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // ExcludeSemantics stays in the tree permanently and only toggles its
    // flag - swapping it in and out would recreate the child subtree and
    // lose its state whenever the opacity crosses zero.
    return GlassOpacityScope(
      opacity: opacity,
      child: ExcludeSemantics(
        excluding: !alwaysIncludeSemantics && opacity <= 0.0,
        child: child,
      ),
    );
  }
}

/// A widget that animates the opacity of descendant [LiquidGlassLayer] widgets
/// without creating a save layer.
///
/// This is the animated equivalent of [LiquidGlassOpacity], working like
/// Flutter's [AnimatedOpacity] but safe for use with glass effects.
///
/// {@tool snippet}
/// ```dart
/// LiquidGlassAnimatedOpacity(
///   opacity: _isVisible ? 1.0 : 0.0,
///   duration: const Duration(milliseconds: 300),
///   child: LiquidGlassLayer(
///     settings: const LiquidGlassSettings(),
///     child: LiquidGlass.inLayer(
///       shape: const RoundedRectangleBorder(),
///       child: const SizedBox(width: 100, height: 100),
///     ),
///   ),
/// )
/// ```
/// {@end-tool}
class LiquidGlassAnimatedOpacity extends ImplicitlyAnimatedWidget {
  /// Creates a [LiquidGlassAnimatedOpacity] widget.
  const LiquidGlassAnimatedOpacity({
    super.key,
    required this.opacity,
    required super.duration,
    super.curve,
    super.onEnd,
    this.alwaysIncludeSemantics = false,
    required this.child,
  }) : assert(opacity >= 0.0 && opacity <= 1.0);

  /// The target opacity (0.0 to 1.0).
  final double opacity;

  /// Whether to always include the child in the semantics tree.
  final bool alwaysIncludeSemantics;

  /// The widget below this widget in the tree.
  final Widget child;

  @override
  AnimatedWidgetBaseState<LiquidGlassAnimatedOpacity> createState() =>
      _LiquidGlassAnimatedOpacityState();
}

class _LiquidGlassAnimatedOpacityState
    extends AnimatedWidgetBaseState<LiquidGlassAnimatedOpacity> {
  Tween<double>? _opacityTween;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _opacityTween = visitor(
      _opacityTween,
      widget.opacity,
      (dynamic value) => Tween<double>(begin: value as double),
    ) as Tween<double>?;
  }

  @override
  Widget build(BuildContext context) {
    final double currentOpacity =
        _opacityTween?.evaluate(animation) ?? widget.opacity;

    // ExcludeSemantics stays in the tree permanently and only toggles its
    // flag: swapping it in and out would change the element tree and
    // recreate the whole child subtree - losing all its state (scroll
    // positions, selections) every time a fade-out completes.
    return GlassOpacityScope(
      opacity: currentOpacity.clamp(0.0, 1.0),
      child: ExcludeSemantics(
        excluding: !widget.alwaysIncludeSemantics && currentOpacity <= 0.0,
        child: widget.child,
      ),
    );
  }
}
