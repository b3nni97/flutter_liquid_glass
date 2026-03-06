import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_shaders/flutter_shaders.dart';

import 'package:liquid_glass_renderer/src/background_child_sampler.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/internal/transform_tracking_repaint_boundary_mixin.dart';
import 'package:liquid_glass_renderer/src/liquid_glass.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/raw_shapes.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';

/// An inherited widget that exposes the [GlassLink] to the subtree.
///
/// This widget allows descendant [LiquidGlass] widgets to register themselves
/// with the shared coordination state, enabling the [LiquidGlassLayer] to
/// aggregate shape data for the shader effect. It acts as the bridge between
/// the rendering layer and the individual glass items distributed in the tree.
class GlassScope extends InheritedWidget {
  /// Creates a [GlassScope] that provides a [GlassLink] to its descendants.
  const GlassScope({
    super.key,
    required this.link,
    required super.child,
  });

  /// The synchronization object used to coordinate glass shapes and effects.
  final GlassLink link;

  /// Retrieves the [GlassLink] from the nearest [GlassScope] ancestor.
  ///
  /// Returns null if no [GlassScope] is found in the provided context.
  static GlassLink? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<GlassScope>()?.link;
  }

  /// Retrieves the [GlassLink] from the nearest [GlassScope] ancestor.
  ///
  /// Throws a [FlutterError] if no [GlassScope] is found.
  static GlassLink of(BuildContext context) {
    final GlassLink? result = maybeOf(context);
    assert(result != null, 'No GlassScope found in context');
    return result!;
  }

  @override
  bool updateShouldNotify(GlassScope oldWidget) => link != oldWidget.link;
}

/// A configuration object representing a touch interaction point on the glass.
///
/// Defines the physical properties of a touch that interacts with the glass
/// surface. These values are uploaded to the fragment shader to distort normals
/// and calculate glow intensity based on distance fields.
@immutable
class TouchPoint {
  /// Creates a [TouchPoint] configuration.
  const TouchPoint(
    this.position, {
    this.radiusPx = 60.0,
    this.fadePx = 40.0,
    this.glowStrength = 1.0,
  });

  /// The center position of the touch in the local coordinate system.
  final Offset position;

  /// The radius of the touch effect in logical pixels.
  final double radiusPx;

  /// The distance over which the effect fades out in logical pixels.
  final double fadePx;

  /// The intensity of the glow effect at this touch point.
  final double glowStrength;
}

/// A compositing layer that renders multiple [LiquidGlass] shapes with optical effects.
///
/// This widget manages the shader pipeline required to render liquid glass,
/// including refraction, blur, lighting, and touch interactions. It acts as
/// the rendering root for all descendant [LiquidGlass] widgets.
class LiquidGlassLayer extends StatefulWidget {
  /// Creates a [LiquidGlassLayer].
  const LiquidGlassLayer({
    super.key,
    this.settings = const LiquidGlassSettings(),
    this.restrictThickness = true,
    this.backgroundChildBuilder,
    required this.child,
  });

  /// Global settings applied to the liquid glass effect.
  final LiquidGlassSettings settings;

  /// Whether to clamp the thickness of the glass to the smallest dimension of the shapes.
  ///
  /// Prevents visual artifacts when thickness exceeds the physical size of a shape.
  final bool restrictThickness;

  /// An optional builder for rendering a custom background texture.
  ///
  /// This texture is sampled by the shader and composited over the backdrop.
  /// Unlike the standard backdrop, this content is:
  /// - Affected by refraction (creating the "object in glass" effect).
  /// - NOT affected by blur or scaling settings.
  /// - Blended onto the backdrop using custom shader logic.
  final LiquidGlassBackgroundChildBuilder? backgroundChildBuilder;

  /// The widget tree that contains the [LiquidGlass] shapes to be rendered.
  final Widget child;

  @override
  State<LiquidGlassLayer> createState() => _LiquidGlassLayerState();
}

class _LiquidGlassLayerState extends State<LiquidGlassLayer> {
  final _ImageHolder _reflectionImageHolder = _ImageHolder();
  final GlassLink _glassLink = GlassLink();

  static final ui.Image _emptySamplerImage =
      createTransparentFallbackImageSync();

  static ui.Image createTransparentFallbackImageSync() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // 1x1 transparent
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0x00000000),
    );

    final picture = recorder.endRecording();
    try {
      return picture.toImageSync(1, 1);
    } finally {
      picture.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ui.ImageFilter.isShaderFilterSupported) {
      return widget.child;
    }

    final Size viewportSize = MediaQuery.sizeOf(context);

    // Load both shaders efficiently using nested builders.
    Widget layerContent = ShaderBuilder(
      assetKey: liquidGlassShader,
      (BuildContext context, FragmentShader glassShader, Widget? child) {
        return ShaderBuilder(
          assetKey: gaussian1dBlurShader,
          (BuildContext context, FragmentShader blurH, Widget? _) {
            return _LiquidGlassRenderObjectWidget(
              shader: glassShader,
              blurH: blurH,
              settings: widget.settings,
              restrictThickness: widget.restrictThickness,
              imageHolder: _reflectionImageHolder,
              viewportSize: viewportSize,
              link: _glassLink,
              emptySamplerImage: _emptySamplerImage,
              child: widget.child,
            );
          },
          child: child,
        );
      },
      child: widget.child,
    );

    if (widget.backgroundChildBuilder != null) {
      layerContent = Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          BackgroundChildSampler(
            _reflectionImageHolder.update,
            builder: widget.backgroundChildBuilder!,
          ),
          layerContent,
        ],
      );
    }

    return GlassScope(
      link: _glassLink,
      child: layerContent,
    );
  }

  @override
  void dispose() {
    _reflectionImageHolder.dispose();
    _glassLink.dispose();
    super.dispose();
  }
}

/// A helper class to manage the lifecycle of the background image and its key color.
///
/// Encapsulates the logic for updating, holding, and disposing the [ui.Image]
/// used for refraction, ensuring resource safety.
class _ImageHolder {
  ui.Image? _image;
  Color _keyColor = const Color(0xFFFFFFFF);

  /// The current background image used for refraction/reflection.
  ui.Image? get image => _image;

  /// The key color extracted from the background image.
  Color get keyColor => _keyColor;

  /// Updates the held image and key color, disposing of the previous image.
  void update(ui.Image newImage, Color newKeyColor) {
    _image?.dispose();
    _image = newImage.clone();
    _keyColor = newKeyColor;
  }

  /// Disposes of the held image resource.
  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

class _LiquidGlassRenderObjectWidget extends SingleChildRenderObjectWidget {
  const _LiquidGlassRenderObjectWidget({
    required this.shader,
    required this.blurH,
    required this.settings,
    required this.restrictThickness,
    required this.imageHolder,
    required this.viewportSize,
    required this.link,
    required this.emptySamplerImage,
    required super.child,
  });

  final FragmentShader shader;
  final FragmentShader blurH;
  final LiquidGlassSettings settings;
  final bool restrictThickness;
  final _ImageHolder imageHolder;
  final Size viewportSize;
  final GlassLink link;
  final ui.Image emptySamplerImage;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlassLayer(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      shader: shader,
      blurH: blurH,
      settings: settings,
      restrictThickness: restrictThickness,
      imageHolder: imageHolder,
      viewportSize: viewportSize,
      link: link,
      emptySamplerImage: emptySamplerImage,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiquidGlassLayer renderObject,
  ) {
    renderObject
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context)
      ..settings = settings
      ..restrictThickness = restrictThickness
      ..imageHolder = imageHolder
      ..viewportSize = viewportSize
      ..link = link
      ..emptySamplerImage = emptySamplerImage
      ..setShaders(shader, blurH);
  }
}

/// A mutable class definition for an active glass shape.
///
/// Contains the render object, raw geometry, touch points, and layout information
/// required for processing a shape in the shader pipeline. Used to cache
/// transformation results between layout and paint phases.
class _ActiveShape {
  RenderLiquidGlass? renderObject;
  RawShape shape = RawShape.none;
  List<TouchPoint> touches = const <TouchPoint>[];
  Matrix4 transform = Matrix4.identity();
  Rect rect = Rect.zero;
}

/// The core [RenderObject] that performs the custom painting and shader management.
///
/// This class handles aggregating shape data from descendants, calculating blur
/// kernels, managing GPU uniforms, and applying the multi-pass shader effect.
class RenderLiquidGlassLayer extends RenderProxyBox
    with TransformTrackingRenderObjectMixin {
  /// Creates a [RenderLiquidGlassLayer].
  RenderLiquidGlassLayer({
    required double devicePixelRatio,
    required FragmentShader shader,
    required FragmentShader blurH,
    required LiquidGlassSettings settings,
    required bool restrictThickness,
    required _ImageHolder imageHolder,
    required Size viewportSize,
    required GlassLink link,
    required ui.Image emptySamplerImage,
  })  : _devicePixelRatio = devicePixelRatio,
        _shader = shader,
        _blurH = blurH,
        _settings = settings,
        _restrictThickness = restrictThickness,
        _imageHolder = imageHolder,
        _viewportSize = viewportSize,
        _glassLink = link,
        _emptySamplerImage = emptySamplerImage {
    _glassLink.addListener(_onGlassLinkChanged);
    _initHBlurInvariants();
  }

  static const int _idxGlassColor = 2;
  static const int _idxOpticalProps = 6;
  static const int _idxLightConfig = 10;
  static const int _idxColorAdjust = 14;
  static const int _idxLightDir = 16;
  static const int _idxTransform = 18;
  static const int _idxRimParams = 34;
  static const int _idxShapeData = 36;
  static const int _shapeStride = 7;
  static const int _idxBlurBase = 92;
  static const int _idxBlurSamples = 96;
  static const int _idxTouchCount = 192;
  static const int _idxTouches = 193;
  static const int _idxTouchOwners = 209;
  static const int _idxGlobalBlurSigma = 213;
  static const int _idxTouchGlowStrengths = 214;
  static const int _idxShapeGlowData = 218;
  static const int _idxBgScale = 346;
  static const int _idxNormalParams = 348;
  static const int _idxChildProjection = 350;
  static const int _idxChildSize = 354;
  static const int _idxKeyColor = 356;
  static const int _blurIdxOpticalProps = 2;
  static const int _blurIdxColorAdjust = 6;
  static const int _blurIdxShapeData = 8;
  static const int _blurIdxHeader = 64;
  static const int _blurIdxSamples = 68;
  static const int _maxShapesPerLayer = 8;
  static const int _maxTouchesPerLayer = 4;
  static const double _epsilon = 0.01;

  final LayerHandle<BackdropFilterLayer> _backdropHandle =
      LayerHandle<BackdropFilterLayer>();

  // Reuse instances of _ActiveShape to prevent GC pressure
  final List<_ActiveShape> _reusableShapeList = <_ActiveShape>[];

  final List<_OwnedTouch> _reusableTouchList = <_OwnedTouch>[];
  final List<_OwnedTouch> _lastUploadedTouches = <_OwnedTouch>[];

  double _devicePixelRatio;
  FragmentShader _shader;
  FragmentShader _blurH;
  LiquidGlassSettings _settings;
  bool _restrictThickness;
  _ImageHolder _imageHolder;
  Size _viewportSize;
  GlassLink _glassLink;
  ui.Image _emptySamplerImage;

  List<RawShape>? _lastShapes;
  LiquidGlassSettings? _lastSettings;
  int _lastShapeCount = -1;
  Rect? _lastClipBounds;
  Offset? _lastPaintOffset;
  Size? _lastViewportSize;
  int _lastTextureWidth = -1;
  int _lastTextureHeight = -1;
  double _lastDPR = -1;
  Matrix4? _lastToGlobal;
  Color? _lastUploadedKeyColor;
  List<_PackedSample>? _cachedKernel;
  int _cachedSigmaBucketKernel = -1;
  int _lastKernelCountH = -1;
  int _lastKernelCountV = -1;
  bool _hInvariantsInitialized = false;

  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  set settings(LiquidGlassSettings value) {
    if (identical(_settings, value)) return;
    _settings = value;
    markNeedsPaint();
  }

  set restrictThickness(bool value) {
    if (_restrictThickness == value) return;
    _restrictThickness = value;
    markNeedsPaint();
  }

  set imageHolder(_ImageHolder value) {
    if (identical(_imageHolder, value)) return;
    _imageHolder = value;
    markNeedsPaint();
  }

  set viewportSize(Size value) {
    if (_viewportSize == value) return;
    _viewportSize = value;
    markNeedsPaint();
  }

  set link(GlassLink value) {
    if (identical(_glassLink, value)) return;
    _glassLink.removeListener(_onGlassLinkChanged);
    _glassLink = value;
    _glassLink.addListener(_onGlassLinkChanged);
    markNeedsPaint();
  }

  set emptySamplerImage(ui.Image value) {
    if (identical(_emptySamplerImage, value)) return;
    _emptySamplerImage = value;
    markNeedsPaint();
  }

  /// Updates the shader instances used for rendering.
  ///
  /// This triggers a repaint if either shader reference has changed.
  void setShaders(FragmentShader glass, FragmentShader blurH) {
    if (!identical(_shader, glass)) {
      _shader = glass;
      _lastKernelCountV = -1;
      _lastShapeCount = -1;
      markNeedsPaint();
    }
    if (!identical(_blurH, blurH)) {
      _blurH = blurH;
      _lastKernelCountH = -1;
      _hInvariantsInitialized = false;
      _initHBlurInvariants();
      markNeedsPaint();
    }
  }

  @override
  void onTransformChanged() {
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    setUpLayer(offset);

    // Calculate transforms
    final Matrix4 toGlobal = getTransformTo(null);
    final Matrix4 globalToLocal = Matrix4.inverted(toGlobal);

    _collectShapes(_reusableShapeList);
    final List<_ActiveShape> shapes = _reusableShapeList;

    if (_settings.thickness <= 0.0 || shapes.isEmpty) {
      _lastShapes = null;
      _backdropHandle.layer = null;
      _paintShapeContents(context, offset, shapes, glassContainsChild: true);
      _paintShapeContents(context, offset, shapes, glassContainsChild: false);
      super.paint(context, offset);
      return;
    }

    final int shapeCount = math.min(_maxShapesPerLayer, shapes.length);
    final double sigmaPx = _settings.blur * _devicePixelRatio;

    final List<_PackedSample> kernel = _getKernelAndMark(sigmaPx);
    final int nKernel =
        math.min(_GaussianKernelGenerator.maxKernelSize, kernel.length);

    _combineTouches(shapes, _reusableTouchList, globalToLocal);
    final List<_OwnedTouch> ownedTouches = _reusableTouchList;

    Rect clipBounds = _computeClipRect(shapes);
    final Rect globalViewport = Offset.zero & _viewportSize;
    final Rect viewportInLayer =
        MatrixUtils.transformRect(globalToLocal, globalViewport);

    clipBounds = clipBounds.intersect(viewportInLayer);
    clipBounds = _snapBoundsForBackdrop(clipBounds, offset);
    clipBounds = clipBounds.intersect(viewportInLayer);

    _uploadUniformsIfNeeded(
      shapeCount: shapeCount,
      shapes: shapes,
      nKernel: nKernel,
      kernel: kernel,
      ownedTouches: ownedTouches,
      bounds: clipBounds,
      offset: offset,
      toGlobal: toGlobal,
      globalToLocal: globalToLocal,
    );

    _uploadKeyColorUniform();

    try {
      _shader.setImageSampler(1, _imageHolder.image ?? _emptySamplerImage);
    } catch (e) {
      debugPrint('LiquidGlassLayer: Failed to set image sampler: $e');
    }

    // Paint Pass 1: Shapes that contain their own children within the glass
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    ui.ImageFilter composedFilter;
    if (sigmaPx > 0.01 && nKernel > 0) {
      composedFilter = ui.ImageFilter.compose(
        outer: ui.ImageFilter.shader(_shader),
        inner: ui.ImageFilter.shader(_blurH),
      );
    } else {
      composedFilter = ui.ImageFilter.shader(_shader);
    }

    final BackdropFilterLayer backdropLayer =
        _backdropHandle.layer ?? BackdropFilterLayer();
    backdropLayer.filter = composedFilter;

    // Push the backdrop filter with a hard edge clip
    context.pushClipRect(
      true,
      offset,
      clipBounds,
      (PaintingContext ctxRect, Offset offRect) {
        ctxRect.pushLayer(
          backdropLayer,
          (PaintingContext childCtx, Offset childOff) {
            childCtx.canvas.drawRect(
              clipBounds.shift(-childOff),
              Paint()..color = const Color(0x00000000),
            );
          },
          offRect,
        );
      },
      clipBehavior: Clip.hardEdge,
    );
    _backdropHandle.layer = backdropLayer;

    // Paint Pass 2: Shapes that overlay the glass effect
    _paintShapeContents(context, offset, shapes, glassContainsChild: false);
    super.paint(context, offset);
  }

  @override
  void dispose() {
    _glassLink.removeListener(_onGlassLinkChanged);
    _backdropHandle.layer = null;
    super.dispose();
  }

  void _onGlassLinkChanged() => markNeedsPaint();

  void _initHBlurInvariants() {
    if (_hInvariantsInitialized) return;
    _blurH
      ..setFloat(_blurIdxHeader + 0, 1.0) // dir.x
      ..setFloat(_blurIdxHeader + 1, 0.0) // dir.y
      ..setFloat(_blurIdxHeader + 3, 0.0); // tile_mode
    _hInvariantsInitialized = true;
  }

  Offset _getScaleXY(Matrix4 transform) {
    final Float64List m = transform.storage;
    if (m[1] == 0.0 && m[4] == 0.0) {
      return Offset(m[0].abs(), m[5].abs());
    }
    final double sx = math.sqrt(m[0] * m[0] + m[1] * m[1]);
    final double sy = math.sqrt(m[4] * m[4] + m[5] * m[5]);
    return Offset(sx, sy);
  }

  double _getScaleFromTransform(Matrix4 transform) {
    final Offset s = _getScaleXY(transform);
    return math.sqrt(s.dx * s.dy);
  }

  void _collectShapes(List<_ActiveShape> buffer) {
    // Instead of clearing and re-allocating tuples, we overwrite existing objects.
    final List<ComputedShapeInfo> computed = _glassLink.computedShapes;

    if (computed.length > _maxShapesPerLayer) {
      assert(
        false,
        'Too many shapes. Max $_maxShapesPerLayer, found ${computed.length}',
      );
      return;
    }

    int writeIndex = 0;
    for (final ComputedShapeInfo s in computed) {
      final RenderObject? ro = s.renderObject;
      if (ro is RenderLiquidGlass) {
        final Matrix4 toThis = ro.getTransformTo(this);
        final double scale = _getScaleFromTransform(toThis);

        // Cache transformed bounds in layer space
        final Rect rectLocal = MatrixUtils.transformRect(
          toThis,
          Offset.zero & ro.size,
        );

        // Ensure we have a mutable container
        if (writeIndex >= buffer.length) {
          buffer.add(_ActiveShape());
        }

        final _ActiveShape active = buffer[writeIndex];
        active.renderObject = ro;
        active.shape = RawShape.fromLiquidGlassShape(
          s.shape,
          center: rectLocal.center,
          size: rectLocal.size,
          scale: scale,
        );
        active.touches = ro.localTouches;
        active.transform = toThis;
        active.rect = rectLocal;

        writeIndex++;
      }
    }

    // Truncate the buffer conceptually by adjusting length,
    // effectively removing stale shapes from the iteration list.
    if (buffer.length > writeIndex) {
      buffer.length = writeIndex;
    }
  }

  Rect _computeClipRect(List<_ActiveShape> shapes) {
    Rect? union;
    for (final _ActiveShape shapeData in shapes) {
      final Rect rectLocal = shapeData.rect;
      union = (union == null) ? rectLocal : union.expandToInclude(rectLocal);
    }
    final Rect unionBounds = union ?? Rect.zero;
    final double margin = (_settings.blur * 3.0) + _settings.thickness;
    return unionBounds.inflate(margin);
  }

  Rect _snapBoundsForBackdrop(Rect clipBounds, Offset paintOffset) {
    final double dpr = _devicePixelRatio;
    final double globalIdealLeftPx = (clipBounds.left + paintOffset.dx) * dpr;
    final double globalIdealTopPx = (clipBounds.top + paintOffset.dy) * dpr;

    final double snappedLeftPx = globalIdealLeftPx.roundToDouble();
    final double snappedTopPx = globalIdealTopPx.roundToDouble();
    final double snappedWidthPx = (clipBounds.width * dpr).roundToDouble();
    final double snappedHeightPx = (clipBounds.height * dpr).roundToDouble();

    return Rect.fromLTRB(
      (snappedLeftPx / dpr) - paintOffset.dx,
      (snappedTopPx / dpr) - paintOffset.dy,
      ((snappedLeftPx + snappedWidthPx) / dpr) - paintOffset.dx,
      ((snappedTopPx + snappedHeightPx) / dpr) - paintOffset.dy,
    );
  }

  List<_PackedSample> _getKernelAndMark(double sigmaPx) {
    final int bucket = (sigmaPx * 10).round();
    if (_cachedKernel != null && bucket == _cachedSigmaBucketKernel) {
      return _cachedKernel!;
    }
    final List<_PackedSample> k =
        _GaussianKernelGenerator.computeImpellerKernel(sigmaPx);
    _cachedKernel = k;
    _cachedSigmaBucketKernel = bucket;
    _lastKernelCountH = -1;
    _lastKernelCountV = -1;
    return k;
  }

  void _uploadUniformsIfNeeded({
    required int shapeCount,
    required List<_ActiveShape> shapes,
    required int nKernel,
    required List<_PackedSample> kernel,
    required List<_OwnedTouch> ownedTouches,
    required Rect bounds,
    required Offset offset,
    required Matrix4 toGlobal,
    required Matrix4 globalToLocal,
  }) {
    // 1. Context Changes
    final bool dprChanged = _devicePixelRatio != _lastDPR;
    final bool viewportChanged = _viewportSize != _lastViewportSize;
    final int texW = _imageHolder.image?.width ?? 0;
    final int texH = _imageHolder.image?.height ?? 0;
    final bool textureChanged =
        texW != _lastTextureWidth || texH != _lastTextureHeight;

    // 2. Geometry Changes
    final bool geometryChanged = dprChanged ||
        viewportChanged ||
        textureChanged ||
        bounds != _lastClipBounds ||
        offset != _lastPaintOffset ||
        _lastToGlobal != toGlobal;

    // 3. Content Changes
    final bool settingsChanged = _settings != _lastSettings;
    final bool shapesDirty = _shapesChanged(shapes);

    // 4. Touch Changes
    final bool touchesDirty = _touchesChanged(ownedTouches);

    // --- UPLOADS ---

    // A. Projection & Transform
    if (geometryChanged) {
      _uploadProjectionUniforms(texW, texH, toGlobal);
      _uploadTransformUniforms(globalToLocal);

      _lastClipBounds = bounds;
      _lastPaintOffset = offset;
      _lastViewportSize = _viewportSize;
      _lastTextureWidth = texW;
      _lastTextureHeight = texH;
      _lastDPR = _devicePixelRatio;
      _lastToGlobal = toGlobal.clone();
    }

    // B. Material & Shapes
    if (settingsChanged || shapesDirty || dprChanged) {
      _uploadMaterialUniforms(shapeCount, shapes);
      _lastSettings = _settings;
      _lastShapeCount = shapeCount;
    } else if (shapeCount != _lastShapeCount) {
      _updateShapeCount(shapeCount);
      _lastShapeCount = shapeCount;
    }

    // C. Touches
    if (touchesDirty || dprChanged) {
      _uploadTouchAndGlow(ownedTouches, shapes);
      _updateLastTouches(ownedTouches);
    }
    // D. Blur (Internal optimization handles redundancy)
    _uploadBlurKernels(nKernel, kernel);
  }

  bool _shapesChanged(List<_ActiveShape> shapes) {
    if (_lastShapes == null || _lastShapes!.length != shapes.length) {
      _lastShapes =
          shapes.map((_ActiveShape e) => e.shape).toList(growable: false);
      return true;
    }

    bool changed = false;
    final List<RawShape> last = _lastShapes!;
    const double eps2 = _epsilon * _epsilon;

    for (int i = 0; i < shapes.length; i++) {
      final RawShape a = last[i];
      final RawShape b = shapes[i].shape;

      if (a.type != b.type ||
          (a.center - b.center).distanceSquared > eps2 ||
          (a.size.width - b.size.width).abs() > _epsilon ||
          (a.size.height - b.size.height).abs() > _epsilon ||
          (a.cornerRadius - b.cornerRadius).abs() > _epsilon ||
          (a.cornerSmoothing ?? -1.0) != (b.cornerSmoothing ?? -1.0)) {
        changed = true;
        break;
      }
    }

    if (changed) {
      _lastShapes =
          shapes.map((_ActiveShape e) => e.shape).toList(growable: false);
    }
    return changed;
  }

  bool _touchesChanged(List<_OwnedTouch> current) {
    if (_lastUploadedTouches.length != current.length) return true;

    for (int i = 0; i < current.length; i++) {
      final _OwnedTouch a = _lastUploadedTouches[i];
      final _OwnedTouch b = current[i];

      if (a.ownerIndex != b.ownerIndex ||
          (a.position - b.position).distanceSquared > 0.001 ||
          (a.radiusPx - b.radiusPx).abs() > 0.1 ||
          (a.glowStrength - b.glowStrength).abs() > 0.01) {
        return true;
      }
    }
    return false;
  }

  void _updateLastTouches(List<_OwnedTouch> current) {
    _lastUploadedTouches.clear();
    _lastUploadedTouches.addAll(current);
  }

  void _uploadKeyColorUniform() {
    final Color target = _imageHolder.keyColor;

    if (_lastUploadedKeyColor == target) return;
    _shader
      ..setFloat(_idxKeyColor + 0, target.red / 255.0)
      ..setFloat(_idxKeyColor + 1, target.green / 255.0)
      ..setFloat(_idxKeyColor + 2, target.blue / 255.0);

    _lastUploadedKeyColor = target;
  }

  void _uploadProjectionUniforms(
    int texW,
    int texH,
    Matrix4 toGlobal,
  ) {
    final double dpr = _devicePixelRatio;
    double calculatedOffX = 0.0;
    double calculatedOffY = 0.0;

    if (texW > 0 && texH > 0) {
      final double layerOriginInTexX = (texW - (size.width * dpr)) * 0.5;
      final double layerOriginInTexY = (texH - (size.height * dpr)) * 0.5;

      final double globalOffsetX = toGlobal.storage[12] * dpr;
      final double globalOffsetY = toGlobal.storage[13] * dpr;

      final double startPixelX = layerOriginInTexX - globalOffsetX;
      final double startPixelY = layerOriginInTexY - globalOffsetY;
      calculatedOffX = startPixelX / texW;
      calculatedOffY = startPixelY / texH;
    }

    final double projScaleX = 1.0;
    final double projScaleY = 1.0;

    _shader
      ..setFloat(_idxChildProjection + 0, calculatedOffX)
      ..setFloat(_idxChildProjection + 1, calculatedOffY)
      ..setFloat(_idxChildProjection + 2, projScaleX)
      ..setFloat(_idxChildProjection + 3, projScaleY)
      ..setFloat(_idxChildSize + 0, texW.toDouble())
      ..setFloat(_idxChildSize + 1, texH.toDouble());
  }

  void _uploadMaterialUniforms(int shapeCount, List<_ActiveShape> shapes) {
    double thickness = _settings.thickness;
    if (_restrictThickness && shapes.isNotEmpty) {
      final double smallest = shapes
          .map((_ActiveShape e) => e.shape.size.shortestSide)
          .reduce((double a, double b) => math.min(a, b));
      thickness = math.min(thickness, smallest);
    }

    // 1. Upload MAIN Shader (Full Set)
    _shader
      ..setFloat(_idxGlassColor + 0, _settings.glassColor.red / 255.0)
      ..setFloat(_idxGlassColor + 1, _settings.glassColor.green / 255.0)
      ..setFloat(_idxGlassColor + 2, _settings.glassColor.blue / 255.0)
      ..setFloat(_idxGlassColor + 3, _settings.glassColor.alpha / 255.0)
      ..setFloat(_idxOpticalProps + 0, _settings.refractiveIndex)
      ..setFloat(_idxOpticalProps + 1, _settings.chromaticAberration)
      ..setFloat(_idxOpticalProps + 2, thickness)
      ..setFloat(_idxOpticalProps + 3, _settings.blend * _devicePixelRatio)
      ..setFloat(_idxLightConfig + 0, _settings.lightAngle)
      ..setFloat(_idxLightConfig + 1, _settings.lightIntensity)
      ..setFloat(_idxLightConfig + 2, _settings.ambientStrength)
      ..setFloat(_idxLightConfig + 3, _settings.saturation)
      ..setFloat(_idxColorAdjust + 0, _settings.lightness)
      ..setFloat(_idxColorAdjust + 1, shapeCount.toDouble())
      ..setFloat(_idxLightDir + 0, math.cos(_settings.lightAngle))
      ..setFloat(_idxLightDir + 1, math.sin(_settings.lightAngle))
      ..setFloat(_idxRimParams + 0, _settings.rimWidthPx)
      ..setFloat(_idxRimParams + 1, _settings.rimSharpness)
      ..setFloat(_idxBgScale + 0, _settings.backgroundScale.dx)
      ..setFloat(_idxBgScale + 1, _settings.backgroundScale.dy)
      ..setFloat(_idxNormalParams + 0, _settings.normalPlateauWidth)
      ..setFloat(_idxNormalParams + 1, _settings.normalSoftness);

    // 2. Upload BLUR Shader (Compact Set)
    // Only essential data for SDF
    _blurH
      ..setFloat(_blurIdxOpticalProps + 0, _settings.refractiveIndex)
      ..setFloat(_blurIdxOpticalProps + 1, _settings.chromaticAberration)
      ..setFloat(_blurIdxOpticalProps + 2, thickness)
      ..setFloat(_blurIdxOpticalProps + 3, _settings.blend * _devicePixelRatio)
      ..setFloat(_blurIdxColorAdjust + 0, _settings.lightness)
      ..setFloat(_blurIdxColorAdjust + 1, shapeCount.toDouble());

    // Upload Shapes (Different Indices!)
    _uploadShapeData(_shader, shapeCount, shapes, _idxShapeData);
    _uploadShapeData(_blurH, shapeCount, shapes, _blurIdxShapeData);
  }

  void _uploadShapeData(
    FragmentShader targetShader,
    int count,
    List<_ActiveShape> shapes,
    int baseIndex,
  ) {
    for (int i = 0; i < count; i++) {
      final RawShape shape =
          i < shapes.length ? shapes[i].shape : RawShape.none;
      final int base = baseIndex + (i * _shapeStride);
      targetShader
        ..setFloat(base + 0, shape.type.index.toDouble())
        ..setFloat(base + 1, shape.center.dx * _devicePixelRatio)
        ..setFloat(base + 2, shape.center.dy * _devicePixelRatio)
        ..setFloat(base + 3, shape.size.width * _devicePixelRatio)
        ..setFloat(base + 4, shape.size.height * _devicePixelRatio)
        ..setFloat(base + 5, shape.cornerRadius * _devicePixelRatio)
        ..setFloat(base + 6, shape.cornerSmoothing ?? -1.0);
    }
  }

  void _uploadTransformUniforms(Matrix4 globalToLocal) {
    final double dpr = _devicePixelRatio;

    final Matrix4 physicalGlobalToLocal = Matrix4.identity()
      ..scale(dpr, dpr, 1.0)
      ..multiply(globalToLocal)
      ..scale(1.0 / dpr, 1.0 / dpr, 1.0);

    final Float64List m = physicalGlobalToLocal.storage;

    // Send only to MAIN Shader
    for (int i = 0; i < 16; i++) {
      _shader.setFloat(_idxTransform + i, m[i]);
    }
  }

  void _updateShapeCount(int shapeCount) {
    if (_lastShapeCount != shapeCount) {
      _shader.setFloat(_idxColorAdjust + 1, shapeCount.toDouble());
      _blurH.setFloat(_blurIdxColorAdjust + 1, shapeCount.toDouble());
    }
  }

  void _uploadBlurKernels(int nKernel, List<_PackedSample> kernel) {
    // H-Pass (Compact Layout)
    _blurH.setFloat(_blurIdxHeader + 2, nKernel.toDouble());
    if (nKernel != _lastKernelCountH) {
      int base = _blurIdxSamples;
      for (int i = 0; i < nKernel; i++) {
        final _PackedSample s = kernel[i];
        _blurH
          ..setFloat(base + 0, s.tPx)
          ..setFloat(base + 1, 0.0)
          ..setFloat(base + 2, s.w)
          ..setFloat(base + 3, 0.0);
        base += 4;
      }
      _lastKernelCountH = nKernel;
    }

    // V-Pass (in Main Shader)
    _shader
      ..setFloat(_idxBlurBase + 0, 0.0) // dir x
      ..setFloat(_idxBlurBase + 1, 1.0) // dir y
      ..setFloat(_idxBlurBase + 2, nKernel.toDouble())
      ..setFloat(_idxBlurBase + 3, 0.0);

    if (nKernel != _lastKernelCountV) {
      // Main Shader has distinct blur offset
      int baseV = _idxBlurSamples;

      for (int i = 0; i < nKernel; i++) {
        final _PackedSample s = kernel[i];
        _shader
          ..setFloat(baseV + 0, s.tPx)
          ..setFloat(baseV + 1, 0.0)
          ..setFloat(baseV + 2, s.w)
          ..setFloat(baseV + 3, 0.0);
        baseV += 4;
      }
      _lastKernelCountV = nKernel;
    }
  }

  void _uploadTouchAndGlow(
    List<_OwnedTouch> ownedTouches,
    List<_ActiveShape> shapes,
  ) {
    final int nTouches = ownedTouches.length.clamp(0, _maxTouchesPerLayer);
    _shader.setFloat(_idxTouchCount, nTouches.toDouble());

    for (int i = 0; i < _maxTouchesPerLayer; i++) {
      final int base = _idxTouches + (i * 4);
      if (i < nTouches) {
        final _OwnedTouch tp = ownedTouches[i];
        _shader
          ..setFloat(base + 0, tp.position.dx * _devicePixelRatio)
          ..setFloat(base + 1, tp.position.dy * _devicePixelRatio)
          ..setFloat(base + 2, tp.radiusPx * _devicePixelRatio)
          ..setFloat(base + 3, tp.fadePx * _devicePixelRatio);
      } else {
        _shader
          ..setFloat(base + 0, -99999.0)
          ..setFloat(base + 1, -99999.0)
          ..setFloat(base + 2, 0.0)
          ..setFloat(base + 3, 0.0);
      }
    }

    for (int i = 0; i < _maxTouchesPerLayer; i++) {
      final double owner =
          (i < nTouches) ? ownedTouches[i].ownerIndex.toDouble() : -1.0;
      _shader.setFloat(_idxTouchOwners + i, owner);
      final double s =
          (i < nTouches) ? ownedTouches[i].glowStrength.clamp(0.0, 1.0) : 0.0;
      _shader.setFloat(_idxTouchGlowStrengths + i, s);
    }

    for (int i = 0; i < shapes.length; i++) {
      final GlowStyle activeStyle =
          shapes[i].renderObject?.glow ?? _settings.glowStyle;
      final int baseIdx = _idxShapeGlowData + (i * 16);

      if (!activeStyle.enabled) {
        for (int k = 0; k < 16; k++) {
          _shader.setFloat(baseIdx + k, 0.0);
        }
        continue;
      }

      final Color c = activeStyle.color;
      final double l = activeStyle.lightness ?? -1.0;
      final double s = activeStyle.saturation ?? -1.0;
      final double b = activeStyle.blur != null
          ? (activeStyle.blur! * _devicePixelRatio)
          : -1.0;
      final Color glassOverride =
          activeStyle.glassColor ?? _settings.glassColor;

      _shader
        ..setFloat(baseIdx + 0, c.red / 255.0)
        ..setFloat(baseIdx + 1, c.green / 255.0)
        ..setFloat(baseIdx + 2, c.blue / 255.0)
        ..setFloat(baseIdx + 3, c.alpha / 255.0)
        ..setFloat(baseIdx + 4, activeStyle.power)
        ..setFloat(baseIdx + 5, activeStyle.mix)
        ..setFloat(baseIdx + 6, b)
        ..setFloat(baseIdx + 7, activeStyle.insideOnly ? 1.0 : 0.0)
        ..setFloat(baseIdx + 8, l)
        ..setFloat(baseIdx + 9, s)
        ..setFloat(baseIdx + 10, activeStyle.lightIntensity)
        ..setFloat(baseIdx + 11, activeStyle.strength)
        ..setFloat(baseIdx + 12, glassOverride.red / 255.0)
        ..setFloat(baseIdx + 13, glassOverride.green / 255.0)
        ..setFloat(baseIdx + 14, glassOverride.blue / 255.0)
        ..setFloat(baseIdx + 15, glassOverride.alpha / 255.0);
    }

    _shader.setFloat(_idxGlobalBlurSigma, _settings.blur * _devicePixelRatio);
  }

  void _combineTouches(
    List<_ActiveShape> shapes,
    List<_OwnedTouch> buffer,
    Matrix4 globalToLocal,
  ) {
    buffer.clear();
    for (int i = 0; i < shapes.length; i++) {
      final List<TouchPoint> localTouches = shapes[i].touches;
      if (localTouches.isEmpty) continue;

      for (final TouchPoint lt in localTouches) {
        // Transform the global touch position into the local coordinate space of this layer.
        final Offset pLocal =
            MatrixUtils.transformPoint(globalToLocal, lt.position);

        buffer.add(_OwnedTouch(
          position: pLocal,
          radiusPx: lt.radiusPx,
          fadePx: lt.fadePx,
          glowStrength: lt.glowStrength,
          ownerIndex: i,
        ));
      }
    }
  }

  void _paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<_ActiveShape> shapes, {
    required bool glassContainsChild,
  }) {
    for (final _ActiveShape s in shapes) {
      final RenderLiquidGlass? ro = s.renderObject;
      if (ro != null && ro.glassContainsChild == glassContainsChild) {
        final Matrix4 transform = s.transform;
        context.pushTransform(
          true,
          offset,
          transform,
          ro.paintFromLayer,
        );
      }
    }
  }
}

/// An immutable representation of a touch point with its owner index.
///
/// Used internally to map touches to specific glass shapes during the shader
/// upload process.
class _OwnedTouch {
  const _OwnedTouch({
    required this.position,
    required this.radiusPx,
    required this.fadePx,
    required this.glowStrength,
    required this.ownerIndex,
  });

  final Offset position;
  final double radiusPx;
  final double fadePx;
  final double glowStrength;
  final int ownerIndex;
}

/// A utility for generating packed Gaussian kernels optimized for shaders.
class _GaussianKernelGenerator {
  static const int maxKernelSize = 24;
  static const double _maxSigma = 500.0;
  static const double _sqrt3 = 1.7320508075688772;

  // Scales the sigma value to approximate the visual falloff of a standard
  // Gaussian blur within the shader's specific implementation limits.
  static double _scaleSigma(double s) {
    final double ss = s.clamp(0.0, _maxSigma);
    const double a = 3.4e-06;
    const double b = -3.4e-3;
    const double c = 1.0;
    return ss * (c + b * ss + a * ss * ss);
  }

  // Converts a sigma value to a kernel radius.
  static double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _sqrt3 : 0.0;
  }

  static List<_RawSample> _genRaw(
    double blurSigma,
    int radius, {
    int step = 1,
  }) {
    final List<_RawSample> out = <_RawSample>[];
    int count = ((2 * radius) ~/ step) + 1;
    int xOff = 0;
    if (radius >= 16) {
      count -= 2;
      xOff = 1;
    }
    double sum = 0.0;
    for (int i = 0; i < count; i++) {
      final int x = xOff + (i * step) - radius;
      final double c = math.exp(-0.5 * (x * x) / (blurSigma * blurSigma)) /
          (math.sqrt(2 * math.pi) * blurSigma);
      out.add(_RawSample(x.toDouble(), c));
      sum += c;
    }
    if (sum > 0) {
      for (final _RawSample s in out) {
        s.w /= sum;
      }
    }
    return out;
  }

  static List<_PackedSample> _packSamples(List<_RawSample> raw) {
    final int n = raw.length;
    final int outCount = ((n - 1) ~/ 2) + 1;
    final int mid = outCount ~/ 2;
    final List<_PackedSample> out = <_PackedSample>[];
    int j = 0;
    for (int i = 0; i < outCount; i++) {
      if (i == mid) {
        final _RawSample s = raw[j];
        out.add(_PackedSample(s.x, s.w));
        j++;
      } else {
        final _RawSample a = raw[j];
        final _RawSample b = raw[j + 1];
        final double w = a.w + b.w;
        final double t = (a.x * a.w + b.x * b.w) / w;
        out.add(_PackedSample(t, w));
        j += 2;
      }
      if (out.length >= maxKernelSize) break;
    }
    return out;
  }

  /// Computes the packed Gaussian kernel samples for the given sigma.
  static List<_PackedSample> computeImpellerKernel(double sigmaPx) {
    final double scaled = _scaleSigma(sigmaPx);
    final int r = _sigmaToRadius(scaled).round();
    if (r <= 0) return <_PackedSample>[_PackedSample(0.0, 1.0)];
    return _packSamples(_genRaw(scaled, r));
  }
}

class _RawSample {
  _RawSample(this.x, this.w);
  double x;
  double w;
}

class _PackedSample {
  _PackedSample(this.tPx, this.w);
  final double tPx;
  final double w;
}
