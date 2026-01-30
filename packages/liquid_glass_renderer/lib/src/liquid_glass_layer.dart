// liquid_glass_layer.dart

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:liquid_glass_renderer/src/background_child_sampler.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/raw_shapes.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';

/// An inherited widget that exposes the [GlassLink] to the subtree.
///
/// This allows child [LiquidGlass] widgets to register themselves with the
/// rendering layer.
class GlassScope extends InheritedWidget {
  const GlassScope({
    required this.link,
    required super.child,
    super.key,
  });

  final GlassLink link;

  static GlassLink? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<GlassScope>()?.link;
  }

  static GlassLink of(BuildContext context) {
    final GlassLink? result = maybeOf(context);
    assert(result != null, 'No GlassScope found in context');
    return result!;
  }

  @override
  bool updateShouldNotify(GlassScope oldWidget) => link != oldWidget.link;
}

/// A configuration object representing a touch interaction on the liquid glass.
///
/// These points affect the local distortion and glow of the glass surface.
/// Dimensions are provided in logical pixels and scaled by the device pixel ratio
/// before being passed to the shader.
@immutable
class TouchPoint {
  /// Creates a touch point configuration.
  const TouchPoint(
    this.position, {
    this.radiusPx = 60.0,
    this.fadePx = 40.0,
    this.glowStrength = 1.0,
  });

  /// The center position of the touch in logical pixels relative to the shape.
  final Offset position;

  /// The radius of the touch effect in logical pixels.
  final double radiusPx;

  /// The falloff distance of the effect in logical pixels.
  final double fadePx;

  /// The intensity multiplier for the glow effect at this point (0.0 to 1.0).
  final double glowStrength;
}

/// A compositing layer that renders multiple [LiquidGlass] shapes.
///
/// This widget coordinates the shader pipeline required to render the liquid
/// glass effect. It manages:
/// 1. A horizontal Gaussian blur pass.
/// 2. A vertical blur and composition pass (the "Glass" shader).
/// 3. Optional background sampling.
///
/// Note: This widget requires a backend that supports runtime shader filters
/// (e.g., Impeller). If [ImageFilter.isShaderFilterSupported] is false,
/// this widget acts as a pass-through.
class LiquidGlassLayer extends StatefulWidget {
  /// Creates a liquid glass compositing layer.
  const LiquidGlassLayer({
    required this.child,
    this.settings = const LiquidGlassSettings(),
    this.restrictThickness = true,
    this.backgroundChildBuilder,
    super.key,
  });

  /// The subtree containing [LiquidGlass] widgets and other content.
  final Widget child;

  /// An optional builder for content that should be reflected/refracted
  /// by the glass.
  ///
  /// If provided, this content is rendered into an offscreen texture and
  /// passed to the shader as Sampler 1.
  final LiquidGlassBackgroundChildBuilder? backgroundChildBuilder;

  /// The visual configuration shared by all glass shapes in this layer.
  final LiquidGlassSettings settings;

  /// Whether to clamp [LiquidGlassSettings.thickness] to the shortest side
  /// of the smallest shape.
  ///
  /// This prevents visual artifacts when the thickness exceeds the physical
  /// dimensions of a shape.
  final bool restrictThickness;

  @override
  State<LiquidGlassLayer> createState() => _LiquidGlassLayerState();
}

class _LiquidGlassLayerState extends State<LiquidGlassLayer> {
  final _ImageHolder _reflectionImageHolder = _ImageHolder();
  final GlassLink _glassLink = GlassLink();

  @override
  void dispose() {
    _reflectionImageHolder.dispose();
    _glassLink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ImageFilter.isShaderFilterSupported) {
      // Fail gracefully on backends without shader support (e.g., Skia on some platforms).
      return widget.child;
    }

    final Size viewportSize = MediaQuery.sizeOf(context);

    // Build the shader pipeline:
    // 1. Load Main Glass Shader.
    // 2. Load Horizontal Blur Shader.
    // 3. Render the Layer.
    Widget layerContent = ShaderBuilder(
      assetKey: liquidGlassShader,
      (BuildContext context, FragmentShader glassShader, Widget? child) {
        return ShaderBuilder(
          assetKey: gaussian1dBlurShader,
          (BuildContext context, FragmentShader blurH, Widget? child) {
            return _LiquidGlassRenderObjectWidget(
              shader: glassShader,
              blurH: blurH,
              settings: widget.settings,
              restrictThickness: widget.restrictThickness,
              imageHolder: _reflectionImageHolder,
              viewportSize: viewportSize,
              link: _glassLink,
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
          // Invisible sampler that updates the texture.
          BackgroundChildSampler(
            (ui.Image image) => _reflectionImageHolder.update(image),
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
}

/// Manages the lifecycle of the background reflection image.
class _ImageHolder {
  ui.Image? _image;

  ui.Image? get image => _image;

  void update(ui.Image newImage) {
    _image?.dispose();
    _image = newImage.clone();
  }

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
    required super.child,
  });

  final FragmentShader shader;
  final FragmentShader blurH;
  final LiquidGlassSettings settings;
  final bool restrictThickness;
  final _ImageHolder imageHolder;
  final Size viewportSize;
  final GlassLink link;

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
      ..setShaders(shader, blurH);
  }
}

// Data tuple to hold shape data during paint collection.
typedef _ActiveShape = (
  RenderLiquidGlass renderObject,
  RawShape rawShape,
  List<TouchPoint> touches
);

/// The core RenderObject that performs the custom painting and shader management.
class RenderLiquidGlassLayer extends RenderProxyBox {
  RenderLiquidGlassLayer({
    required double devicePixelRatio,
    required FragmentShader shader,
    required FragmentShader blurH,
    required LiquidGlassSettings settings,
    required bool restrictThickness,
    required _ImageHolder imageHolder,
    required Size viewportSize,
    required GlassLink link,
  })  : _devicePixelRatio = devicePixelRatio,
        _shader = shader,
        _blurH = blurH,
        _settings = settings,
        _restrictThickness = restrictThickness,
        _imageHolder = imageHolder,
        _viewportSize = viewportSize,
        _glassLink = link {
    _glassLink.addListener(_onGlassLinkChanged);
    _initHBlurInvariants();
  }

  // --- Uniform Index Constants ---
  // These must match the layout in `liquid_glass.frag` and `gauss1d_linear.frag`.

  static const int _idxGlassColor = 2; // vec4
  static const int _idxOpticalProps = 6; // vec4
  static const int _idxLightConfig = 10; // vec4
  static const int _idxColorAdjust = 14; // vec4 (x: lightness, y: numShapes)
  static const int _idxLightDir = 16; // vec2
  static const int _idxTransform = 18; // mat4
  static const int _idxRimParams = 34; // vec2

  static const int _shapeDataBaseFloat = 36; // uShapeData[]
  static const int _shapeStride = 7;

  // Blur Shader Header
  static const int _blurBaseFloat = 148; // uBlurHeader (vec4)
  static const int _blurSamplesFloat = 152; // u_samples[]

  // Touch & Glow
  static const int _idxTouchCount = 352;
  static const int _idxTouches = 353; // 8 * vec4
  static const int _idxTouchOwners = 385; // float[8]

// NEU: Inserted after TouchOwners (393)
  static const int _idxGlobalBlurSigma = 393; // float -> Ends at 394
  static const int _idxTouchGlowStrengths = 394; // float[8] -> Ends at 402
  static const int _idxShapeGlowData =
      402; // vec4 array [MAX_SHAPES * 3] -> Ends at 594

  // Projection & Environment (Shifted by new data)
  static const int _idxBgScale = 658;
  static const int _idxNormalParams = 660;
  static const int _idxChildProjection = 662;
  static const int _idxChildSize = 666;

  static const int _maxShapesPerLayer = 16;
  static const double _epsilon = 0.01;

  final LayerHandle<BackdropFilterLayer> _backdropHandle =
      LayerHandle<BackdropFilterLayer>();

  double _devicePixelRatio;
  FragmentShader _shader;
  FragmentShader _blurH;
  LiquidGlassSettings _settings;
  bool _restrictThickness;
  _ImageHolder _imageHolder;
  Size _viewportSize;
  GlassLink _glassLink;

  // Caching state to minimize uniform uploads
  List<_PackedSample>? _cachedKernel;
  int _cachedSigmaBucketKernel = -1;
  int _lastKernelCountH = -1;
  int _lastKernelCountV = -1;
  int _lastShapeCount = -1;
  LiquidGlassSettings? _lastSettings;
  List<RawShape>? _lastShapes;

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

  void _onGlassLinkChanged() => markNeedsPaint();

  /// Initializes constants for the horizontal blur shader.
  /// This only needs to happen once per shader instance.
  void _initHBlurInvariants() {
    if (_hInvariantsInitialized) return;
    // uBlurHeader: x=u_dir_x, y=u_dir_y, z=u_sample_count, w=u_tile_mode
    _blurH
      ..setFloat(_blurBaseFloat + 0, 1.0) // dir.x (Horizontal)
      ..setFloat(_blurBaseFloat + 1, 0.0) // dir.y
      ..setFloat(_blurBaseFloat + 3, 0.0); // tile_mode = clamp
    _hInvariantsInitialized = true;
  }

  /// Extracts non-uniform scales (sx, sy) from the transform matrix.
  Offset _getScaleXY(Matrix4 transform) {
    final Float64List m = transform.storage;
    // Fast-path: no rotation or skew.
    if (m[1] == 0.0 && m[4] == 0.0) {
      return Offset(m[0].abs(), m[5].abs());
    }
    // General case: Column 0 is X axis, Column 1 is Y axis.
    final double sx = math.sqrt(m[0] * m[0] + m[1] * m[1]);
    final double sy = math.sqrt(m[4] * m[4] + m[5] * m[5]);
    return Offset(sx, sy);
  }

  double _getScaleFromTransform(Matrix4 transform) {
    final Offset s = _getScaleXY(transform);
    return math.sqrt(s.dx * s.dy);
  }

  /// Collects all shapes registered via [GlassLink] that are relevant to this layer.
  List<_ActiveShape> _collectShapes() {
    final List<_ActiveShape> result = <_ActiveShape>[];
    final List<ComputedShapeInfo> computed = _glassLink.computedShapes;

    if (computed.length > _maxShapesPerLayer) {
      // In production, we might log a warning instead of crashing, but for now strict check.
      assert(
        false,
        'LiquidGlassLayer supports max $_maxShapesPerLayer shapes. Found ${computed.length}.',
      );
      return result;
    }

    for (final ComputedShapeInfo s in computed) {
      final RenderObject? ro = s.renderObject;
      if (ro is RenderLiquidGlass) {
        final Matrix4 toThis = ro.getTransformTo(this);
        final double scale = _getScaleFromTransform(toThis);
        result.add((
          ro,
          RawShape.fromLiquidGlassShape(
            s.shape,
            center: s.globalBounds.center,
            size: s.globalBounds.size,
            scale: scale,
          ),
          ro.localTouches,
        ));
      }
    }
    return result;
  }

  /// Determines the union bounds of all shapes and inflates them for the blur effect.
  Rect _computeClipRect(
    List<_ActiveShape> shapes,
  ) {
    Rect? union;
    for (final _ActiveShape shapeData in shapes) {
      final RenderLiquidGlass ro = shapeData.$1;
      final Matrix4 transformToThis = ro.getTransformTo(this);
      final Rect rectLocal = MatrixUtils.transformRect(
        transformToThis,
        Offset.zero & ro.size,
      );
      union = (union == null) ? rectLocal : union.expandToInclude(rectLocal);
    }
    final Rect unionBounds = union ?? Rect.zero;

    // Inflate bounds to accommodate blur and rim thickness.
    final double margin = (_settings.blur * 3.0) + _settings.thickness + 12.0;
    final Rect clipBounds = unionBounds.inflate(margin);

    return clipBounds;
  }

  /// Clamps the layer bounds to the viewport to prevent rendering into void space.
  Rect _clampBoundsToViewport(Rect bounds, Offset layerOffset) {
    final Rect global = bounds.shift(layerOffset);
    final Rect viewport = Offset.zero & _viewportSize;

    final double clampedLeft = global.left.clamp(viewport.left, viewport.right);
    final double clampedTop = global.top.clamp(viewport.top, viewport.bottom);
    final double clampedRight =
        global.right.clamp(viewport.left, viewport.right);
    final double clampedBottom =
        global.bottom.clamp(viewport.top, viewport.bottom);

    if (clampedRight <= clampedLeft || clampedBottom <= clampedTop) {
      return Rect.zero;
    }

    return Rect.fromLTRB(
      clampedLeft,
      clampedTop,
      clampedRight,
      clampedBottom,
    ).shift(-layerOffset);
  }

  /// Aligns the paint bounds to physical pixels to avoid texture sampling artifacts.
  ///
  /// This ensures that the global position of the backdrop filter snaps to integers.
  Rect _snapBoundsForBackdrop(Rect clipBounds, Offset paintOffset) {
    final double dpr = _devicePixelRatio;

    // 1. Compute ideal global physical position
    final double globalIdealLeftPx = (clipBounds.left + paintOffset.dx) * dpr;
    final double globalIdealTopPx = (clipBounds.top + paintOffset.dy) * dpr;

    // 2. Snap to nearest integer pixel
    final double snappedLeftPx = globalIdealLeftPx.roundToDouble();
    final double snappedTopPx = globalIdealTopPx.roundToDouble();

    // 3. Snap size to nearest integer pixel
    final double snappedWidthPx = (clipBounds.width * dpr).roundToDouble();
    final double snappedHeightPx = (clipBounds.height * dpr).roundToDouble();

    // 4. Transform back to local coordinates
    return Rect.fromLTRB(
      (snappedLeftPx / dpr) - paintOffset.dx,
      (snappedTopPx / dpr) - paintOffset.dy,
      ((snappedLeftPx + snappedWidthPx) / dpr) - paintOffset.dx,
      ((snappedTopPx + snappedHeightPx) / dpr) - paintOffset.dy,
    );
  }

  /// Calculates the kernel for the Gaussian blur based on the sigma value.
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
  }) {
    final bool settingsChanged = _lastSettings != _settings;
    final bool shapesChanged = _shapesChanged(shapes);

    // 1. Calculate Projection (Screen Space -> Texture Space)
    _uploadProjectionUniforms(bounds, offset);

    // 2. Update Shape & Material Uniforms
    if (settingsChanged || shapesChanged) {
      _uploadMaterialUniforms(shapeCount, shapes);
    } else {
      // Minimal update if only counts/transform changed
      _updateShapeCount(shapeCount);
    }

    // Always update the transform as the offset/bounds might have shifted
    _uploadTransformUniforms(bounds, offset);

    // 3. Update Blur Kernels
    _uploadBlurKernels(nKernel, kernel);

    // 4. Update Touch & Glow
    // NEU: Wir übergeben 'shapes', um auf die individuellen Glow-Daten zuzugreifen
    _uploadTouchAndGlow(ownedTouches, shapes);

    _lastSettings = _settings;
    _lastShapeCount = shapeCount;
  }

  void _uploadProjectionUniforms(Rect bounds, Offset offset) {
    final double dpr = _devicePixelRatio;
    final int textureWidth = _imageHolder.image?.width ?? 0;
    final int textureHeight = _imageHolder.image?.height ?? 0;

    double calculatedOffX = 0.0;
    double calculatedOffY = 0.0;

    if (textureWidth > 0 && textureHeight > 0) {
      // Center the reflection texture relative to the layer center.
      final double layerOriginInTexX =
          (textureWidth - (size.width * dpr)) * 0.5;
      final double layerOriginInTexY =
          (textureHeight - (size.height * dpr)) * 0.5;

      // Calculate start pixel relative to the snapped bounds.
      final double startPixelX = layerOriginInTexX + (bounds.left * dpr);
      final double startPixelY = layerOriginInTexY + (bounds.top * dpr);

      calculatedOffX = startPixelX / textureWidth;
      calculatedOffY = startPixelY / textureHeight;
    }

    // Fallback scaling if size is zero (avoid div/0)
    final double projScaleX =
        bounds.width / (size.width > 0 ? size.width : 1.0);
    final double projScaleY =
        bounds.height / (size.height > 0 ? size.height : 1.0);

    _shader
      ..setFloat(_idxChildProjection + 0, calculatedOffX)
      ..setFloat(_idxChildProjection + 1, calculatedOffY)
      ..setFloat(_idxChildProjection + 2, projScaleX)
      ..setFloat(_idxChildProjection + 3, projScaleY)
      ..setFloat(_idxChildSize + 0, textureWidth.toDouble())
      ..setFloat(_idxChildSize + 1, textureHeight.toDouble());
  }

  void _uploadMaterialUniforms(int shapeCount, List<_ActiveShape> shapes) {
    // Determine effective thickness (clamp if restricted)
    double thickness = _settings.thickness;
    if (_restrictThickness && shapes.isNotEmpty) {
      final double smallest = shapes
          .map((e) => e.$2.size.shortestSide)
          .reduce((double a, double b) => math.min(a, b));
      thickness = math.min(thickness, smallest);
    }

    // Base Properties
    _shader
      ..setFloat(_idxGlassColor + 0, _settings.glassColor.r)
      ..setFloat(_idxGlassColor + 1, _settings.glassColor.g)
      ..setFloat(_idxGlassColor + 2, _settings.glassColor.b)
      ..setFloat(_idxGlassColor + 3, _settings.glassColor.a)
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

    // Sync specific uniforms to H-Blur shader
    _blurH
      ..setFloat(_idxOpticalProps + 0, _settings.refractiveIndex)
      ..setFloat(_idxOpticalProps + 1, _settings.chromaticAberration)
      ..setFloat(_idxOpticalProps + 2, thickness)
      ..setFloat(_idxOpticalProps + 3, _settings.blend * _devicePixelRatio)
      ..setFloat(_idxColorAdjust + 0, _settings.lightness)
      ..setFloat(_idxColorAdjust + 1, shapeCount.toDouble());

    // Upload Shapes
    _uploadShapeData(_shader, shapeCount, shapes);
    _uploadShapeData(_blurH, shapeCount, shapes);
  }

  void _uploadShapeData(
    FragmentShader targetShader,
    int count,
    List<_ActiveShape> shapes,
  ) {
    for (int i = 0; i < count; i++) {
      final RawShape shape = i < shapes.length ? shapes[i].$2 : RawShape.none;
      final int base = _shapeDataBaseFloat + (i * _shapeStride);
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

  void _uploadTransformUniforms(Rect bounds, Offset offset) {
    // Calculate precise physical position (Integer Snapped)
    final double txPx =
        ((bounds.left + offset.dx) * _devicePixelRatio).roundToDouble();
    final double tyPx =
        ((bounds.top + offset.dy) * _devicePixelRatio).roundToDouble();

    final Matrix4 transform = Matrix4.translationValues(txPx, tyPx, 0.0);
    final Float64List storage = transform.storage;

    for (int i = 0; i < 16; i++) {
      _shader.setFloat(_idxTransform + i, storage[i]);
      _blurH.setFloat(_idxTransform + i, storage[i]);
    }
  }

  void _updateShapeCount(int shapeCount) {
    if (_lastShapeCount != shapeCount) {
      _shader.setFloat(_idxColorAdjust + 1, shapeCount.toDouble());
      _blurH.setFloat(_idxColorAdjust + 1, shapeCount.toDouble());
    }
  }

  void _uploadBlurKernels(int nKernel, List<_PackedSample> kernel) {
    // H-Pass
    _blurH.setFloat(_blurBaseFloat + 2, nKernel.toDouble());
    if (nKernel != _lastKernelCountH) {
      int base = _blurSamplesFloat;
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

    // V-Pass (in main shader)
    _shader
      ..setFloat(_blurBaseFloat + 0, 0.0) // dir x
      ..setFloat(_blurBaseFloat + 1, 1.0) // dir y
      ..setFloat(_blurBaseFloat + 2, nKernel.toDouble())
      ..setFloat(_blurBaseFloat + 3, 0.0);

    if (nKernel != _lastKernelCountV) {
      int baseV = _blurSamplesFloat;
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
      List<_OwnedTouch> ownedTouches, List<_ActiveShape> shapes) {
    // 1. Upload Touch Points (Pool)
    final int nTouches = ownedTouches.length.clamp(0, 8);
    _shader.setFloat(_idxTouchCount, nTouches.toDouble());

    // Upload touches
    for (int i = 0; i < 8; i++) {
      final int base = _idxTouches + (i * 4);
      if (i < nTouches) {
        final _OwnedTouch tp = ownedTouches[i];
        _shader
          ..setFloat(base + 0, tp.position.dx * _devicePixelRatio)
          ..setFloat(base + 1, tp.position.dy * _devicePixelRatio)
          ..setFloat(base + 2, tp.radiusPx * _devicePixelRatio)
          ..setFloat(base + 3, tp.fadePx * _devicePixelRatio);
      } else {
        // Reset unused slots
        _shader
          ..setFloat(base + 0, -99999.0)
          ..setFloat(base + 1, -99999.0)
          ..setFloat(base + 2, 0.0)
          ..setFloat(base + 3, 0.0);
      }
    }

    // Upload owners and strengths
    for (int i = 0; i < 8; i++) {
      final double owner =
          (i < nTouches) ? ownedTouches[i].ownerIndex.toDouble() : -1.0;
      _shader.setFloat(_idxTouchOwners + i, owner);

      final double s =
          (i < nTouches) ? ownedTouches[i].glowStrength.clamp(0.0, 1.0) : 0.0;
      _shader.setFloat(_idxTouchGlowStrengths + i, s);
    }

    for (int i = 0; i < shapes.length; i++) {
      final GlowStyle activeStyle = shapes[i].$1.glow ?? _settings.glowStyle;

      // Wenn kein Glow, müssen wir den Speicherbereich nullen (alle 16 Floats)
      if (!activeStyle.enabled) {
        final int baseIdx = _idxShapeGlowData + (i * 16); // 16 Floats stride
        for (int k = 0; k < 16; k++) {
          _shader.setFloat(baseIdx + k, 0.0);
        }
        continue;
      }

      // Offset: i * 4 vec4s * 4 floats = i * 16
      final int baseIdx = _idxShapeGlowData + (i * 16);

      final Color c = activeStyle.color;
      final double l = activeStyle.lightness ?? -1.0;
      final double s = activeStyle.saturation ?? -1.0;
      final double b = activeStyle.blur != null
          ? (activeStyle.blur! * _devicePixelRatio)
          : -1.0;

      // LOGIK FÜR GLOW GLASS (Ersetzt Flag):
      // Wenn activeStyle.glassColor gesetzt ist -> Nimm es.
      // Wenn nicht -> Nimm die globale settings.glassColor.
      // (Blendet dann von Global zu Global = keine Änderung, genau wie gewünscht).
      final Color glassOverride =
          activeStyle.glassColor ?? _settings.glassColor;

      // Vec 0: Color RGB, Strength
      _shader
        ..setFloat(baseIdx + 0, c.red / 255.0)
        ..setFloat(baseIdx + 1, c.green / 255.0)
        ..setFloat(baseIdx + 2, c.blue / 255.0)
        ..setFloat(baseIdx + 3, c.alpha / 255.0);

      // Vec 1: Power, Mix, Blur, InsideOnly
      _shader
        ..setFloat(baseIdx + 4, activeStyle.power)
        ..setFloat(baseIdx + 5, activeStyle.mix)
        ..setFloat(baseIdx + 6, b)
        ..setFloat(baseIdx + 7, activeStyle.insideOnly ? 1.0 : 0.0);

      // Vec 2: Lightness, Saturation, TintMode, Unused
      _shader
        ..setFloat(baseIdx + 8, l)
        ..setFloat(baseIdx + 9, s)
        ..setFloat(baseIdx + 10, activeStyle.tintMode.toDouble())
        ..setFloat(baseIdx + 11, activeStyle.strength);

      // Vec 3 (NEU): Glow Glass Color (RGBA)
      _shader
        ..setFloat(baseIdx + 12, glassOverride.red / 255.0)
        ..setFloat(baseIdx + 13, glassOverride.green / 255.0)
        ..setFloat(baseIdx + 14, glassOverride.blue / 255.0)
        ..setFloat(baseIdx + 15, glassOverride.alpha / 255.0);
    }

    // Global Blur Sigma noch setzen
    _shader.setFloat(
      _idxGlobalBlurSigma,
      _settings.blur * _devicePixelRatio,
    );
  }

  bool _shapesChanged(List<_ActiveShape> shapes) {
    final List<RawShape> shapeList =
        shapes.map((e) => e.$2).toList(growable: false);
    if (_lastShapes == null || _lastShapes!.length != shapeList.length) {
      _lastShapes = shapeList;
      return true;
    }

    const double eps2 = _epsilon * _epsilon;
    for (int i = 0; i < shapeList.length; i++) {
      final RawShape a = _lastShapes![i];
      final RawShape b = shapeList[i];

      if (a.type != b.type) {
        _lastShapes = shapeList;
        return true;
      }
      if ((a.center - b.center).distanceSquared > eps2) {
        _lastShapes = shapeList;
        return true;
      }
      if ((a.size.width - b.size.width).abs() > _epsilon ||
          (a.size.height - b.size.height).abs() > _epsilon) {
        _lastShapes = shapeList;
        return true;
      }
      if ((a.cornerRadius - b.cornerRadius).abs() > _epsilon) {
        _lastShapes = shapeList;
        return true;
      }
      if ((a.cornerSmoothing ?? -1.0) != (b.cornerSmoothing ?? -1.0)) {
        _lastShapes = shapeList;
        return true;
      }
    }
    return false;
  }

  List<_OwnedTouch> _combineTouches(List<_ActiveShape> shapes) {
    final List<_OwnedTouch> combined = <_OwnedTouch>[];
    for (int i = 0; i < shapes.length; i++) {
      final List<TouchPoint> localTouches = shapes[i].$3;
      if (localTouches.isEmpty) continue;

      for (final TouchPoint lt in localTouches) {
        combined.add(_OwnedTouch(
          position: lt.position,
          radiusPx: lt.radiusPx,
          fadePx: lt.fadePx,
          glowStrength: lt.glowStrength,
          ownerIndex: i,
        ));
      }
    }
    return combined;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final List<_ActiveShape> shapes = _collectShapes();

    // Early exit if disabled or empty.
    if (_settings.thickness <= 0 || shapes.isEmpty) {
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
    final List<_OwnedTouch> ownedTouches = _combineTouches(shapes);

    // Compute geometry
    Rect clipBounds = _computeClipRect(shapes);
    clipBounds = _snapBoundsForBackdrop(
        _clampBoundsToViewport(clipBounds, offset), offset);

    // Upload
    _uploadUniformsIfNeeded(
      shapeCount: shapeCount,
      shapes: shapes,
      nKernel: nKernel,
      kernel: kernel,
      ownedTouches: ownedTouches,
      bounds: clipBounds,
      offset: offset,
    );

    // Set Image Sampler
    if (_imageHolder.image != null) {
      try {
        _shader.setImageSampler(1, _imageHolder.image!);
      } catch (e) {
        debugPrint('LiquidGlassLayer: Failed to set image sampler: $e');
      }
    }

    // 1. Paint content ABOVE the glass (glassContainsChild = true)
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    // 2. Compose Shaders (Blur + Glass)
    ImageFilter composedFilter;
    if (sigmaPx > 0.01 && nKernel > 0) {
      composedFilter = ImageFilter.compose(
        outer: ImageFilter.shader(_shader), // Main Glass pass
        inner: ImageFilter.shader(_blurH), // Horizontal Blur pass
      );
    } else {
      composedFilter = ImageFilter.shader(_shader);
    }

    // 3. Push Backdrop Filter
    final BackdropFilterLayer backdropLayer =
        _backdropHandle.layer ?? BackdropFilterLayer();
    backdropLayer.filter = composedFilter;

    // We clip strictly to the bounds to avoid processing unnecessary pixels
    context.pushClipRect(
      true,
      offset,
      clipBounds,
      (PaintingContext ctxRect, Offset offRect) {
        ctxRect.pushLayer(
          backdropLayer,
          (PaintingContext childCtx, Offset childOff) {
            // Draw a transparent rect to trigger the backdrop filter
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

    // 4. Paint content UNDER the glass (glassContainsChild = false)
    _paintShapeContents(context, offset, shapes, glassContainsChild: false);

    super.paint(context, offset);
  }

  void _paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<_ActiveShape> shapes, {
    required bool glassContainsChild,
  }) {
    for (final _ActiveShape s in shapes) {
      final RenderLiquidGlass ro = s.$1;
      if (ro.glassContainsChild == glassContainsChild) {
        final Matrix4 transform = ro.getTransformTo(this);
        context.pushTransform(
          true,
          offset,
          transform,
          ro.paintFromLayer,
        );
      }
    }
  }

  @override
  void dispose() {
    _glassLink
      ..removeListener(_onGlassLinkChanged)
      ..dispose();
    _backdropHandle.layer = null;
    super.dispose();
  }
}

/// Internal representation of a touch point mapped to a specific shape index.
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

/// Helper class to generate packed Gaussian kernels for Impeller shaders.
class _GaussianKernelGenerator {
  static const int maxKernelSize = 50;
  static const double _maxSigma = 500.0;
  static const double _sqrt3 = 1.7320508075688772;

  static double _scaleSigma(double s) {
    final double ss = s.clamp(0.0, _maxSigma);
    const double a = 3.4e-06;
    const double b = -3.4e-3;
    const double c = 1.0;
    return ss * (c + b * ss + a * ss * ss);
  }

  static double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _sqrt3 : 0.0;
  }

  static List<_RawSample> _genRaw(double blurSigma, int radius,
      {int step = 1}) {
    final List<_RawSample> out = <_RawSample>[];
    int count = ((2 * radius) ~/ step) + 1;
    int xOff = 0;

    // Optimization for large radii
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

  /// Packs two samples into one texture lookup using linear interpolation.
  /// This doubles performance on GPUs with fast linear filtering.
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

/// Packed kernel entry forwarded to the GPU.
class _PackedSample {
  _PackedSample(this.tPx, this.w);
  final double tPx; // Sample offset (pixels)
  final double w; // Sample weight
}
