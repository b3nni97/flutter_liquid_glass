// resolution_aware_animated_sampler.dart

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A callback for the [BackgroundChildSampler] widget.
typedef SamplerBuilder = void Function(
  ui.Image image,
  Size size,
  ui.Canvas canvas,
);

class LiquidGlassBackgroundChild extends StatelessWidget {
  const LiquidGlassBackgroundChild({
    this.scale = const Offset(1, 1),
    required this.child,
    super.key,
  });

  final Widget child;
  final Offset scale;

  @override
  Widget build(BuildContext context) {
    return child;
  }
}

/// Eine angepasste Version von AnimatedSampler (basierend auf dem Flutter Original),
/// die einen [resolutionScale] akzeptiert, um den Viewport (die Bildgröße) zu erweitern,
/// ohne den Inhalt zu zoomen.
class BackgroundChildSampler extends StatelessWidget {
  /// Create a new [BackgroundChildSampler].
  const BackgroundChildSampler(
    this.builder, {
    required this.child,
    super.key,
    this.enabled = true,
  });

  /// A callback used by this widget to provide the children captured in
  /// a texture.
  final SamplerBuilder builder;

  /// Whether the children should be captured in a texture or displayed as
  /// normal.
  final bool enabled;

  /// The child widget.
  final LiquidGlassBackgroundChild child;

  @override
  Widget build(BuildContext context) {
    return _ShaderSamplerBuilder(
      builder,
      enabled: enabled,
      child: child,
    );
  }
}

class _ShaderSamplerBuilder extends SingleChildRenderObjectWidget {
  const _ShaderSamplerBuilder(
    this.builder, {
    required this.child,
    required this.enabled,
  }) : super(child: child);

  final SamplerBuilder builder;
  final LiquidGlassBackgroundChild child;
  final bool enabled;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderShaderSamplerBuilderWidget(
      devicePixelRatio: MediaQuery.of(context).devicePixelRatio,
      builder: builder,
      enabled: enabled,
      scale: child.scale,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderShaderSamplerBuilderWidget)
      ..devicePixelRatio = MediaQuery.of(context).devicePixelRatio
      ..builder = builder
      ..enabled = enabled
      ..scale = child.scale;
  }
}

// A render object that conditionally converts its child into a [ui.Image]
// and then paints it in place of the child.
class _RenderShaderSamplerBuilderWidget extends RenderProxyBox {
  // Create a new [_RenderShaderSamplerBuilderWidget].
  _RenderShaderSamplerBuilderWidget({
    required double devicePixelRatio,
    required SamplerBuilder builder,
    required bool enabled,
    required Offset scale,
  })  : _devicePixelRatio = devicePixelRatio,
        _builder = builder,
        _enabled = enabled,
        _scale = scale;

  @override
  OffsetLayer updateCompositedLayer(
      {required covariant _ShaderSamplerBuilderLayer? oldLayer}) {
    final _ShaderSamplerBuilderLayer layer =
        oldLayer ?? _ShaderSamplerBuilderLayer(builder);
    layer
      ..callback = builder
      ..size = size
      ..devicePixelRatio = devicePixelRatio
      ..scale = scale; // Skalierung an Layer übergeben
    return layer;
  }

  /// The device pixel ratio used to create the child image.
  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == devicePixelRatio) {
      return;
    }
    _devicePixelRatio = value;
    markNeedsCompositedLayerUpdate();
  }

  Offset get scale => _scale;
  Offset _scale;
  set scale(Offset value) {
    if (value == scale) {
      return;
    }
    _scale = value;
    markNeedsCompositedLayerUpdate();
  }

  /// The painter used to paint the child snapshot or child widgets.
  SamplerBuilder get builder => _builder;
  SamplerBuilder _builder;
  set builder(SamplerBuilder value) {
    if (value == builder) {
      return;
    }
    _builder = value;
    markNeedsCompositedLayerUpdate();
  }

  bool get enabled => _enabled;
  bool _enabled;
  set enabled(bool value) {
    if (value == enabled) {
      return;
    }
    _enabled = value;
    markNeedsPaint();
    markNeedsCompositingBitsUpdate();
  }

  @override
  bool get isRepaintBoundary => alwaysNeedsCompositing;

  @override
  bool get alwaysNeedsCompositing => enabled;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      return;
    }
    assert(!_enabled || offset == Offset.zero);
    return super.paint(context, offset);
  }
}

/// A [Layer] that uses an [SamplerBuilder] to create a [ui.Picture]
/// every time it is added to a scene.
class _ShaderSamplerBuilderLayer extends OffsetLayer {
  _ShaderSamplerBuilderLayer(this._callback);

  ui.Picture? _lastPicture;

  Size get size => _size;
  Size _size = Size.zero;
  set size(Size value) {
    if (value == size) {
      return;
    }
    _size = value;
    markNeedsAddToScene();
  }

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio = 1.0;
  set devicePixelRatio(double value) {
    if (value == devicePixelRatio) {
      return;
    }
    _devicePixelRatio = value;
    markNeedsAddToScene();
  }

  Offset get scale => _resolutionScale;
  Offset _resolutionScale = const Offset(1.0, 1.0);
  set scale(Offset value) {
    if (value == scale) {
      return;
    }
    _resolutionScale = value;
    markNeedsAddToScene();
  }

  SamplerBuilder get callback => _callback;
  SamplerBuilder _callback;
  set callback(SamplerBuilder value) {
    if (value == callback) {
      return;
    }
    _callback = value;
    markNeedsAddToScene();
  }

  ui.Image _buildChildScene(
      Rect bounds, double pixelRatio, Offset scaleFactor) {
    final ui.SceneBuilder builder = ui.SceneBuilder();

    // 1. Inhalt-Skalierung: NUR native DPR (1:1 Inhalt, kein Zoom)
    final Matrix4 transform =
        Matrix4.diagonal3Values(pixelRatio, pixelRatio, 1);
    builder.pushTransform(transform.storage);
    addChildrenToScene(builder);
    builder.pop();

    // 2. Bild-Größe: DPR * ScaleFactor (Größeres Bild / Viewport Expansion)
    return builder.build().toImageSync(
          (pixelRatio * scaleFactor.dx * bounds.width).ceil(),
          (pixelRatio * scaleFactor.dy * bounds.height).ceil(),
        );
  }

  @override
  void dispose() {
    _lastPicture?.dispose();
    super.dispose();
  }

  @override
  void addToScene(ui.SceneBuilder builder) {
    if (size.isEmpty) return;
    final bounds = offset & Size(size.width, size.height);
    // Übergabe von resolutionScale an den Build-Prozess
    final ui.Image image = _buildChildScene(
      bounds,
      devicePixelRatio,
      scale,
    );

    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    try {
      // Callback erhält die physische Größe des neuen (größeren) Bildes
      callback(
        image,
        Size(
            (devicePixelRatio * scale.dx * bounds.width)
                .floorToDouble(), //  image.width.toDouble(),
            (devicePixelRatio * scale.dy * bounds.height)
                .floorToDouble() //  image.height.toDouble(),
            ),
        canvas,
      );
    } finally {
      image.dispose();
    }
    final ui.Picture picture = pictureRecorder.endRecording();
    _lastPicture?.dispose();
    _lastPicture = picture;
    builder.addPicture(offset, picture);
  }
}
