// ignore_for_file: avoid_setters_without_getters

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_layer.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/liquid_shape.dart';
import 'package:meta/meta.dart';

/// A liquid glass shape.
///
/// Kann alleine genutzt werden (eigener Layer) oder als Teil eines
/// gemeinsamen [LiquidGlassLayer] (`LiquidGlass.inLayer`).
class LiquidGlass extends StatelessWidget {
  /// Standalone-Variante: erstellt einen eigenen [LiquidGlassLayer].
  ///
  /// [touches] werden dabei direkt an den Layer weitergereicht, damit
  /// Glow/Hotspots funktionieren. In dieser Variante hat [blend] keine Wirkung
  /// auf andere Shapes, da kein Sharing stattfindet.
  const LiquidGlass({
    required this.child,
    required this.shape,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
    this.restrictThickness = true,
    this.touches = const <TouchPoint>[],
    super.key,
    LiquidGlassSettings settings = const LiquidGlassSettings(),
  }) : _settings = settings;

  /// In-Layer-Variante: erwartet bereits einen übergeordneten [LiquidGlassLayer].
  ///
  /// Die [touches] werden hier NICHT gebraucht – sie gehören auf
  /// den gemeinsamen Layer.
  const LiquidGlass.inLayer({
    required this.child,
    required this.shape,
    super.key,
    this.glassContainsChild = true,
    this.clipBehavior = Clip.hardEdge,
  })  : _settings = null,
        restrictThickness = false,
        touches = const <TouchPoint>[];

  /// The child of this widget.
  final Widget child;

  /// The shape of this glass.
  final LiquidShape shape;

  /// Whether this glass should be rendered inside the glass or on top.
  final bool glassContainsChild;

  /// The clip behavior of this glass.
  final Clip clipBehavior;

  /// {@macro liquid_glass_renderer.restrict_thickness}
  final bool restrictThickness;

  /// Optional touch hotspots (nur in der Standalone-Variante relevant).
  final List<TouchPoint> touches;

  final LiquidGlassSettings? _settings;

  @override
  Widget build(BuildContext context) {
    switch (_settings) {
      case null:
        // In-Layer: nur Rohform registrieren, Layer liefert Settings/Touch usw.
        return _RawLiquidGlass(
          shape: shape,
          glassContainsChild: glassContainsChild,
          child: ClipPath(
            clipper: ShapeBorderClipper(shape: shape),
            clipBehavior: clipBehavior,
            child: child,
          ),
        );

      case final settings:
        // Standalone: eigener Layer + Touches durchreichen
        return LiquidGlassLayer(
          settings: settings,
          restrictThickness: restrictThickness,
          touches: touches,
          child: _RawLiquidGlass(
            shape: shape,
            glassContainsChild: glassContainsChild,
            child: ClipPath(
              clipper: ShapeBorderClipper(shape: shape),
              clipBehavior: clipBehavior,
              child: child,
            ),
          ),
        );
    }
  }
}

class _RawLiquidGlass extends SingleChildRenderObjectWidget {
  const _RawLiquidGlass({
    required super.child,
    required this.shape,
    required this.glassContainsChild,
  });

  final LiquidShape shape;
  final bool glassContainsChild;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlass(
      shape: shape,
      glassContainsChild: glassContainsChild,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiquidGlass renderObject,
  ) {
    renderObject
      ..shape = shape
      ..glassContainsChild = glassContainsChild;
  }
}

@internal
class RenderLiquidGlass extends RenderProxyBox {
  RenderLiquidGlass({
    required LiquidShape shape,
    required bool glassContainsChild,
  })  : _shape = shape,
        _glassContainsChild = glassContainsChild;

  late LiquidShape _shape;
  LiquidShape get shape => _shape;
  set shape(LiquidShape value) {
    if (_shape == value) return;
    _shape = value;
    markNeedsPaint();
    _updateGlassLink();
  }

  bool _glassContainsChild = true;
  bool get glassContainsChild => _glassContainsChild;
  set glassContainsChild(bool value) {
    if (_glassContainsChild == value) return;
    _glassContainsChild = value;
    markNeedsPaint();
    _updateGlassLink();
  }

  GlassLink? _glassLink;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _registerWithParentLayer();
  }

  @override
  void detach() {
    _unregisterFromParentLayer();
    super.detach();
  }

  void _registerWithParentLayer() {
    var ancestor = parent;
    while (ancestor != null) {
      if (ancestor is RenderLiquidGlassLayer) {
        _glassLink = ancestor.glassLink;
        _glassLink?.registerShape(
          this,
          _shape,
          glassContainsChild: _glassContainsChild,
        );
        break;
      }
      ancestor = ancestor.parent;
    }
  }

  void _unregisterFromParentLayer() {
    _glassLink?.unregisterShape(this);
    _glassLink = null;
  }

  void _updateGlassLink() {
    _glassLink?.updateShape(
      this,
      _shape,
      glassContainsChild: _glassContainsChild,
    );
  }

  @override
  void performLayout() {
    super.performLayout();
    _glassLink?.notifyShapeLayoutChanged(this);
  }

  @override
  void paint(PaintingContext context, Offset offset) {}

  void paintFromLayer(PaintingContext context, Offset offset) {
    super.paint(context, offset);
  }

  void paintBlur(PaintingContext context, Offset offset, double blur) {
    if (blur <= 0) return;

    context.pushClipPath(
      true,
      offset,
      offset & size,
      ShapeBorderClipper(shape: shape).getClip(size),
      (context, offset) {
        context.pushLayer(
          BackdropFilterLayer(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          ),
          (context, offset) {},
          offset,
        );
      },
    );
  }
}
