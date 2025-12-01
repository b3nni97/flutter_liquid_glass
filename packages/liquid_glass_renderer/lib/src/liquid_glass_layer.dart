// liquid_glass_layer.dart
// ignore_for_file: avoid_setters_without_getters

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/raw_shapes.dart';
import 'package:liquid_glass_renderer/src/background_child_sampler.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';
import 'package:meta/meta.dart';

// NEU: Helferklasse für den Bildaustausch
class _ImageHolder {
  ui.Image? _image;
  Size _size = Size.zero; // <--- NEU: Größe speichern

  ui.Image? get image => _image;
  Size get size => _size; // <--- NEU

  void update(ui.Image newImage, Size newSize) {
    // <--- Signatur angepasst
    _image?.dispose();
    _image = newImage.clone();
    _size = newSize; // <--- NEU
  }

  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

/// A compositing layer that renders multiple [LiquidGlass] shapes which can
/// visually merge and share a single [LiquidGlassSettings] configuration.
///
/// Notes:
/// - Requires Impeller (runtime shader + backdrop filter support). If runtime
/// shader filters are not supported, this widget becomes a no-op pass-through.
class LiquidGlassLayer extends StatefulWidget {
  const LiquidGlassLayer({
    required this.child,
    this.settings = const LiquidGlassSettings(),
    this.restrictThickness = true,
    this.backgroundChild, // Optionales Widget für Reflektionen
    super.key,
  });

  /// The subtree that contains [LiquidGlass] shapes and arbitrary content.
  final Widget child;

  /// Optionales Widget, das gesamplet wird und als Textur (Sampler 1)
  /// an den Shader übergeben wird (z.B. für Environment Maps).
  final LiquidGlassBackgroundChild? backgroundChild;

  /// Rendering parameters for the liquid glass effect shared by all shapes.
  final LiquidGlassSettings settings;

  /// If true, clamps [LiquidGlassSettings.thickness] to the shortest side of
  /// the smallest shape in the layer to avoid artifacts on very thin shapes.
  final bool restrictThickness;

  @override
  State<LiquidGlassLayer> createState() => _LiquidGlassLayerState();
}

// DTO for touch points in logical pixels (will be scaled by DPR before upload)
@immutable
class TouchPoint {
  const TouchPoint(
    this.position, {
    this.radiusPx = 60,
    this.fadePx = 40,
    this.glowStrength = 1.0, // 0..1 Multiplier pro Touch
  });

  final Offset position; // logical pixels
  final double radiusPx; // logical px
  final double fadePx; // logical px
  final double glowStrength; // 0..1
}

class _LiquidGlassLayerState extends State<LiquidGlassLayer>
    with SingleTickerProviderStateMixin {
  // Holder für das Reflection Image
  final _ImageHolder _reflectionImageHolder = _ImageHolder();

  @override
  void dispose() {
    _reflectionImageHolder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ImageFilter.isShaderFilterSupported) {
      assert(
        ImageFilter.isShaderFilterSupported,
        'liquid_glass_renderer requires Impeller with shader filter support. '
        'Enable Impeller or guard rendering with ImageFilter.isShaderFilterSupported.',
      );
      return widget.child;
    }

    // Viewport-Größe über MediaQuery holen
    final Size viewportSize = MediaQuery.sizeOf(context);

    // Build the shader pipeline:
    // 1) Load glass shader (liquid_glass.frag)
    // 2) Nest a horizontal 1D Gaussian blur shader (gauss1d_linear.frag)
    // 3) Provide a render object that uploads uniforms and performs both passes
    return ShaderBuilder(
      assetKey: liquidGlassShader, // Main pass (liquid_glass.frag)
      (context, glassShader, child) => ShaderBuilder(
        assetKey: gaussian1dBlurShader, // H-pass (gauss1d_linear.frag)
        (context, blurH, child) {
          // Das eigentliche Render-Widget (mit dem normalen Child)
          Widget glassLayerWidget = _RawShapes(
            shader: glassShader,
            blurH: blurH,
            settings: widget.settings,
            debugRenderRefractionMap: false,
            restrictThickness: widget.restrictThickness,
            imageHolder: _reflectionImageHolder,
            viewportSize: viewportSize,
            child: widget.child,
          );

          // Wenn backgroundChild da ist, rendern wir sie im Hintergrund (unsichtbar)
          if (widget.backgroundChild != null) {
            return Stack(
              fit: StackFit.passthrough,
              children: [
                // Reflection Source (wird gesamplet)
                BackgroundChildSampler(
                  (ui.Image image, Size size, Canvas canvas) {
                    // print(size); // Debug print entfernt für Production
                    _reflectionImageHolder.update(
                        image, size); // <--- Size übergeben
                  },
                  // FIX 1: Native Auflösung (1.0).
                  // Durch unsere Änderung im Sampler bedeutet ein Offset > 1.0
                  // jetzt "Größerer Viewport", nicht "Zoom".
                  // Du kannst hier auch Offset(1.5, 1.5) nutzen, wenn du mehr Rand brauchst.
                  // resolutionScale: const Offset(2, 2),
                  child: widget.backgroundChild!,
                ),
                // Glas Layer (sichtbar)
                glassLayerWidget,
              ],
            );
          }

          return glassLayerWidget;
        },
        child: widget.child,
      ),
      child: widget.child,
    );
  }
}

class _RawShapes extends SingleChildRenderObjectWidget {
  const _RawShapes({
    required this.shader,
    required this.blurH,
    required this.settings,
    required this.debugRenderRefractionMap,
    required this.restrictThickness,
    required this.imageHolder,
    required this.viewportSize,
    required Widget super.child,
  });

  final FragmentShader shader; // Main glass shader (includes V-pass)
  final FragmentShader blurH; // Horizontal blur shader (H-pass)

  final LiquidGlassSettings settings;
  final bool debugRenderRefractionMap;
  final bool restrictThickness;
  final _ImageHolder imageHolder;

  /// Viewport-Größe (logische Pixel), vom Widget-Layer durchgereicht.
  final Size viewportSize;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlassLayer(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      shader: shader,
      blurH: blurH,
      settings: settings,
      debugRenderRefractionMap: debugRenderRefractionMap,
      restrictThickness: restrictThickness,
      imageHolder: imageHolder,
      viewportSize: viewportSize,
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
      ..debugRenderRefractionMap = debugRenderRefractionMap
      ..restrictThickness = restrictThickness
      ..imageHolder = imageHolder
      ..viewportSize = viewportSize
      ..setShaders(shader, blurH);
  }
}

const int _maxShapesPerLayer = 16;

/// Raw kernel entry (work buffer structure).
class _RawS {
  _RawS(this.x, this.w);
  double x; // sample offset (in px)
  double w; // sample weight
}

/// Packed kernel entry forwarded to the GPU.
class _PackedS {
  _PackedS(this.tPx, this.w);
  final double tPx; // sample offset (in px)
  final double w; // sample weight
}

@internal
class RenderLiquidGlassLayer extends RenderProxyBox {
  RenderLiquidGlassLayer({
    required double devicePixelRatio,
    required FragmentShader shader,
    required FragmentShader blurH,
    required LiquidGlassSettings settings,
    required bool restrictThickness,
    required _ImageHolder imageHolder,
    required Size viewportSize,
    bool debugRenderRefractionMap = false,
  })  : _devicePixelRatio = devicePixelRatio,
        _shader = shader,
        _blurH = blurH,
        _settings = settings,
        _debugRenderRefractionMap = debugRenderRefractionMap,
        _restrictThickness = restrictThickness,
        _imageHolder = imageHolder,
        _viewportSize = viewportSize,
        _glassLink = GlassLink() {
    _glassLink.addListener(_onGlassLinkChanged);
    _initHBlurInvariants();
  }

  // ───────────────── Uniform layout (sequential float indices) ──────────────
  // float[0..1]   → uSize (vec2)  [wird von Flutter/Runtime gesetzt]
  static const int _idxGlassColor = 2; // vec4  → 2..5
  static const int _idxOpticalProps = 6; // vec4  → 6..9
  static const int _idxLightConfig = 10; // vec4 → 10..13
  static const int _idxColorAdjust = 14; // x: lightness, y: numShapes
  static const int _idxLightDir = 16;
  static const int _idxTransform = 18; // mat4 → 18..33
  static const int _idxRimParams = 34;

  static const int _shapeDataBaseFloat = 36; // first float of uShapeData
  static const int _blurBaseFloat = 132; // uBlurHeader.x (u_dir_x)
  static const int _blurSamplesFloat = 136; // u_samples[0].x

  // Touch/Glow indices (match liquid_glass.frag layout ordering)
  static const int _idxTouchCount = 336;
  static const int _idxTouches = 337; // 8 * vec4 → 32 floats
  static const int _idxTouchOwners = 369;
  static const int _idxGlowParams = 377; // vec4
  static const int _idxGlowColor = 381; // vec4
  static const int _idxGlowOverrides = 385; // vec4
  static const int _idxGlowFlags = 389; // vec4
  static const int _idxGlowGlass = 393; // vec4
  static const int _idxGlobalBlurSigma = 397; // float
  static const int _idxTouchGlowStrengths = 398; // floats[8]

  // Hintergrund-Skalierung (nur im Main-Pass genutzt)
  static const int _idxBgScale = 406; // float

  // Parameter für Normalen/Abschrägung (vec2)
  static const int _idxNormalParams = 407; // float

  // Projection Uniform (vec4: offX, offY, scaleX, scaleY)
  static const int _idxChildProjection = 409;
  // NEU: Child Size Uniform (vec2: width, height)
  static const int _idxChildSize = 413;

  static const double _eps = 0.01;

  final GlassLink _glassLink;
  GlassLink get glassLink => _glassLink;
  void _onGlassLinkChanged() => markNeedsPaint();

  double _devicePixelRatio;
  FragmentShader _shader;
  FragmentShader _blurH;
  LiquidGlassSettings _settings;
  bool _debugRenderRefractionMap;
  bool _restrictThickness;
  _ImageHolder _imageHolder;

  /// Viewport-Größe in logischen Pixeln (vom Widget-Layer gesetzt).
  Size _viewportSize;

  // --- Setters ---
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

  set debugRenderRefractionMap(bool value) {
    if (_debugRenderRefractionMap == value) return;
    _debugRenderRefractionMap = value;
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
  // ------------------------------------

  // Cached kernels and state to minimize uniform uploads.
  List<_PackedS>? _cachedKernel;
  int _cachedSigmaBucketKernel = -1;
  int _lastKernelCountH = -1;
  int _lastKernelCountV = -1;
  int _lastShapeCount = -1;
  LiquidGlassSettings? _lastSettings;
  List<RawShape>? _lastShapes;

  bool _hInvariantsInitialized = false;

  // BackdropFilter layer handle
  final LayerHandle<BackdropFilterLayer> _backdropHandle =
      LayerHandle<BackdropFilterLayer>();

  /// Swap shaders. This also resets kernel-related caches as necessary.
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

  /// Set invariants for the horizontal blur shader. Only done once per shader.
  void _initHBlurInvariants() {
    if (_hInvariantsInitialized) return;
    // uBlurHeader: x=u_dir_x, y=u_dir_y, z=u_sample_count, w=u_tile_mode
    _blurH
      ..setFloat(_blurBaseFloat + 0, 1.0) // dir.x (H-pass)
      ..setFloat(_blurBaseFloat + 1, 0.0) // dir.y
      ..setFloat(_blurBaseFloat + 3, 0.0); // tile_mode = clamp
    _hInvariantsInitialized = true;
  }

  /// Nicht-uniforme Skales (sx, sy) aus der Transform-Matrix extrahieren.
  Offset _getScaleXY(Matrix4 transform) {
    final m = transform.storage;

    // Fast-path: kein Rotate/Skew.
    if (m[1] == 0 && m[4] == 0) {
      final sx = m[0].abs();
      final sy = m[5].abs();
      return Offset(sx, sy);
    }

    // General case: erste Spalte = X-Achse, zweite Spalte = Y-Achse.
    final double a = m[0], b = m[1]; // X-Spalte
    final double c = m[4], d = m[5]; // Y-Spalte

    final double sx = math.sqrt(a * a + b * b);
    final double sy = math.sqrt(c * c + d * d);

    return Offset(sx, sy);
  }

  /// Uniformer Scale (für RawShape), aus sx/sy abgeleitet.
  double _getScaleFromTransform(Matrix4 transform) {
    final Offset s = _getScaleXY(transform);
    return math.sqrt(s.dx * s.dy);
  }

  /// Collects all [RawShape]s participating in this layer + lokale Touches je Shape.
  List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> collectShapes() {
    final result = <(RenderLiquidGlass, RawShape, List<TouchPoint>)>[];
    final computed = _glassLink.computedShapes;
    if (computed.length > _maxShapesPerLayer) {
      throw UnsupportedError('Only $_maxShapesPerLayer shapes are supported!');
    }

    for (final s in computed) {
      final ro = s.renderObject;
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

  // Impeller constraints and numeric helpers for kernel synthesis.
  static const int _impellerMaxKernel = 50;
  static const double _maxSigma = 500.0;
  static const double _sqrt3 = 1.7320508075688772;

  double _scaleSigma(double s) {
    final ss = s.clamp(0.0, _maxSigma);
    const a = 3.4e-06, b = -3.4e-3, c = 1.0;
    return ss * (c + b * ss + a * ss * ss);
  }

  double _sigmaToRadius(double sigma) {
    return sigma > 0.5 ? (sigma - 0.5) * _sqrt3 : 0.0;
  }

  List<_RawS> _genRaw(double blurSigma, int radius, {int step = 1}) {
    final out = <_RawS>[];
    int count = ((2 * radius) ~/ step) + 1, xOff = 0;

    if (radius >= 16) {
      count -= 2;
      xOff = 1;
    }

    double sum = 0.0;
    for (int i = 0; i < count; i++) {
      final x = xOff + (i * step) - radius;
      final c = math.exp(-0.5 * (x * x) / (blurSigma * blurSigma)) /
          (math.sqrt(2 * math.pi) * blurSigma);
      out.add(_RawS(x.toDouble(), c));
      sum += c;
    }

    if (sum > 0) {
      for (final s in out) {
        s.w /= sum;
      }
    }
    return out;
  }

  List<_PackedS> _lerpHack(List<_RawS> raw) {
    final n = raw.length, outCount = ((n - 1) ~/ 2) + 1, mid = outCount ~/ 2;
    final out = <_PackedS>[];
    int j = 0;
    for (int i = 0; i < outCount; i++) {
      if (i == mid) {
        final s = raw[j];
        out.add(_PackedS(s.x, s.w));
        j++;
      } else {
        final a = raw[j], b = raw[j + 1];
        final w = a.w + b.w;
        final t = (a.x * a.w + b.x * b.w) / w;
        out.add(_PackedS(t, w));
        j += 2;
      }
      if (out.length >= _impellerMaxKernel) break;
    }
    return out;
  }

  int _sigmaBucket(double sigmaPx) => (sigmaPx * 10).round();

  List<_PackedS> _computeImpellerKernel(double sigmaPx) {
    final scaled = _scaleSigma(sigmaPx);
    final r = _sigmaToRadius(scaled).round();
    if (r <= 0) return <_PackedS>[_PackedS(0.0, 1.0)];
    return _lerpHack(_genRaw(scaled, r));
  }

  List<_PackedS> _getKernelAndMark(double sigmaPx) {
    final bucket = _sigmaBucket(sigmaPx);
    if (_cachedKernel != null && bucket == _cachedSigmaBucketKernel) {
      return _cachedKernel!;
    }
    final k = _computeImpellerKernel(sigmaPx);
    _cachedKernel = k;
    _cachedSigmaBucketKernel = bucket;
    _lastKernelCountH = -1;
    _lastKernelCountV = -1;
    return k;
  }

  void _updateShapeCountIfNeeded(int shapeCount) {
    if (_lastShapeCount == shapeCount) return;
    _shader.setFloat(_idxColorAdjust + 1, shapeCount.toDouble());
    _lastShapeCount = shapeCount;
  }

  bool _shapesChanged(
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes,
  ) {
    final shapeList = shapes.map((e) => e.$2).toList(growable: false);
    if (_lastShapes == null || _lastShapes!.length != shapeList.length) {
      _lastShapes = shapeList;
      return true;
    }

    const eps2 = _eps * _eps;
    for (var i = 0; i < shapeList.length; i++) {
      final a = _lastShapes![i];
      final b = shapeList[i];

      if (a.type != b.type) {
        _lastShapes = shapeList;
        return true;
      }

      final dcx = a.center.dx - b.center.dx;
      final dcy = a.center.dy - b.center.dy;
      if (dcx * dcx + dcy * dcy > eps2) {
        _lastShapes = shapeList;
        return true;
      }

      final dw = a.size.width - b.size.width;
      final dh = a.size.height - b.size.height;
      if (dw * dw + dh * dh > eps2) {
        _lastShapes = shapeList;
        return true;
      }

      if ((a.cornerRadius - b.cornerRadius).abs() > _eps) {
        _lastShapes = shapeList;
        return true;
      }
    }
    return false;
  }

  /// Interne Struktur: Touch + Owner-Index.
  List<_OwnedTouch> _combineTouches(
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes,
  ) {
    final combined = <_OwnedTouch>[];
    for (var i = 0; i < shapes.length; i++) {
      final local = shapes[i].$3;
      if (local.isEmpty) continue;
      for (final lt in local) {
        combined.add(
          _OwnedTouch(
            position: lt.position,
            radiusPx: lt.radiusPx,
            fadePx: lt.fadePx,
            glowStrength: lt.glowStrength,
            ownerIndex: i,
          ),
        );
      }
    }
    return combined;
  }

  /// Echte Glas-Bounds + Clip-/Blur-Bounds (mit Margin) in EINEM Loop.
  (Rect unionBounds, Rect clipBounds) _computeUnionAndClipRect(
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes,
  ) {
    Rect? union;
    for (final (ro, _, __) in shapes) {
      final transformToThis = ro.getTransformTo(this);
      final rectLocal =
          MatrixUtils.transformRect(transformToThis, Offset.zero & ro.size);
      union = (union == null) ? rectLocal : union!.expandToInclude(rectLocal);
    }
    final Rect unionBounds = union ?? Rect.zero;
    final double margin = (_settings.blur * 3.0) + _settings.thickness + 12.0;
    final Rect clipBounds = unionBounds.inflate(margin);

    return (unionBounds, clipBounds);
  }

  /// Neu: Bounds (mit Margin) im globalen Viewport clampen.
  Rect _clampBoundsToViewport(Rect bounds, Offset layerOffset) {
    // bounds: im lokalen Koordinatensystem des Layers
    // layerOffset: Offset, mit dem der Layer gepaintet wird
    final Rect global = bounds.shift(layerOffset);
    final Rect viewport = Offset.zero & _viewportSize;

    final double clampedLeft = global.left.clamp(viewport.left, viewport.right);
    final double clampedTop = global.top.clamp(viewport.top, viewport.bottom);
    final double clampedRight =
        global.right.clamp(viewport.left, viewport.right);
    final double clampedBottom =
        global.bottom.clamp(viewport.top, viewport.bottom);

    // Falls komplett außerhalb → leeres Rect, verhindert komische Effekte.
    if (clampedRight <= clampedLeft || clampedBottom <= clampedTop) {
      return Rect.zero;
    }

    final Rect clampedGlobal = Rect.fromLTRB(
      clampedLeft,
      clampedTop,
      clampedRight,
      clampedBottom,
    );

    // Zurück in Layer-Koordinaten
    return clampedGlobal.shift(-layerOffset);
  }

  /// Snap a rectangle to device pixels to avoid half-pixel sampling seams.
  Rect _snapRectToDeviceFull(Rect r) {
    final d = _devicePixelRatio;
    double f(double v) => (v * d).floorToDouble() / d;
    double c(double v) => (v * d).ceilToDouble() / d;
    return Rect.fromLTRB(f(r.left), f(r.top), c(r.right), c(r.bottom));
  }

  Path _computeUnionClipPath(
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes,
  ) {
    final path = Path();
    for (final (ro, raw, _) in shapes) {
      final Matrix4 toThis = ro.getTransformTo(this);
      final Rect rectLocal =
          MatrixUtils.transformRect(toThis, Offset.zero & ro.size);
      if (raw.type == RawShapeType.ellipse) {
        path.addOval(rectLocal);
      } else {
        final r = Radius.circular(raw.cornerRadius);
        path.addRRect(
          RRect.fromRectAndCorners(
            rectLocal,
            topLeft: r,
            topRight: r,
            bottomLeft: r,
            bottomRight: r,
          ),
        );
      }
    }
    return path;
  }

  /// Uploads all uniforms required for the current frame if settings, shapes,
  /// or kernel configuration have changed.
  void _uploadUniformsIfNeeded(
    int shapeCount,
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes,
    int nKernel,
    List<_PackedS> kernel,
    List<_OwnedTouch> ownedTouches,
    Rect bounds, // Clip/Blur-Bounds (mit Margin)
    Offset offset,
    Rect unionBounds, // Glas-Bounds (ohne Margin)
    Offset glassScale, // nur als Parameter
  ) {
    final settingsChanged = _lastSettings != _settings;
    final shapesChanged = _shapesChanged(shapes);

    // Optionally clamp thickness to avoid artifacts on very small shapes.
    var thickness = _settings.thickness;
    if (_restrictThickness && shapes.isNotEmpty) {
      final smallest = shapes
          .map((e) => e.$2.size.shortestSide)
          .reduce((a, b) => a < b ? a : b);
      thickness = math.min(thickness, smallest);
    }

    // --- Transform für Screen → SDF (global) ---
    final double dpr = _devicePixelRatio;
    final double theoreticalGlobalLeft = offset.dx + bounds.left;
    final double theoreticalGlobalTop = offset.dy + bounds.top;
    final double actualGlobalLeft = math.max(0.0, theoreticalGlobalLeft);
    final double actualGlobalTop = math.max(0.0, theoreticalGlobalTop);
    final double tx = actualGlobalLeft * dpr;
    final double ty = actualGlobalTop * dpr;
    final Matrix4 transform = Matrix4.translationValues(tx, ty, 0);

    // --- Projection (child) ---
    // 1. Safety Checks (Layout dimensions & Glass Scale)
    final double layerW = size.width > 0 ? size.width : 1.0;
    final double layerH = size.height > 0 ? size.height : 1.0;
    // 2. Scale Calculation (Kein Zoom, nur Bounds-Relation)
    final double projScaleX = bounds.width / layerW;
    final double projScaleY = bounds.height / layerH;

    // 3. Offset Calculation (Automatisches Zentrieren der Textur)
    final double texPhysW = _imageHolder.size.width;
    final double texPhysH = _imageHolder.size.height;
    double calculatedOffX = 0.0;
    double calculatedOffY = 0.0;

    if (texPhysW > 0 && texPhysH > 0) {
      // Umrechnen in logische Pixel
      final double texLogW = texPhysW / _devicePixelRatio;
      final double texLogH = texPhysH / _devicePixelRatio;

      // Mittelpunkte berechnen
      final double layerCenterX = size.width / 2.0;
      final double layerCenterY = size.height / 2.0;
      final double texCenterX = texLogW / 2.0;
      final double texCenterY = texLogH / 2.0;

      // Layer-Ursprung (0,0) in der Textur finden
      final double layerOriginInTexX = texCenterX - layerCenterX;
      final double layerOriginInTexY = texCenterY - layerCenterY;

      // Startpunkt der Render-Bounds in der Textur
      final double startPixelX = layerOriginInTexX + bounds.left;
      final double startPixelY = layerOriginInTexY + bounds.top;

      // Normalisieren zu UV
      calculatedOffX = startPixelX / texLogW;
      calculatedOffY = startPixelY / texLogH;
    }

    _shader
      ..setFloat(_idxChildProjection + 0, calculatedOffX)
      ..setFloat(_idxChildProjection + 1, calculatedOffY)
      ..setFloat(_idxChildProjection + 2, projScaleX)
      ..setFloat(_idxChildProjection + 3, projScaleY);

    // FIX 3: Child Size hochladen (Zwingend für RGSS / Präzision im Shader)
    final double cw = texPhysW > 0 ? texPhysW : 100.0;
    final double ch = texPhysH > 0 ? texPhysH : 100.0;
    _shader
      ..setFloat(_idxChildSize + 0, cw)
      ..setFloat(_idxChildSize + 1, ch);

    if (settingsChanged || shapesChanged) {
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
        // Skalierung des Hintergrunds im Shape
        ..setFloat(_idxBgScale, _settings.backgroundScale)
        // Normalen-Parameter
        ..setFloat(_idxNormalParams + 0, _settings.normalPlateauWidth)
        ..setFloat(_idxNormalParams + 1, _settings.normalSoftness);

      // uTransform (Screen → SDF): Translation in Device-Pixeln
      for (int i = 0; i < 16; i++) {
        _shader.setFloat(_idxTransform + i, transform.storage[i]);
      }

      for (var i = 0; i < shapeCount; i++) {
        final shape = i < shapes.length ? shapes[i].$2 : RawShape.none;
        final base = _shapeDataBaseFloat + (i * 6);
        _shader
          ..setFloat(base + 0, shape.type.index.toDouble())
          ..setFloat(base + 1, shape.center.dx * _devicePixelRatio)
          ..setFloat(base + 2, shape.center.dy * _devicePixelRatio)
          ..setFloat(base + 3, shape.size.width * _devicePixelRatio)
          ..setFloat(base + 4, shape.size.height * _devicePixelRatio)
          ..setFloat(base + 5, shape.cornerRadius * _devicePixelRatio);
      }

      // Spiegel die relevanten Uniforms in den H-Pass
      _blurH
        ..setFloat(_idxOpticalProps + 0, _settings.refractiveIndex)
        ..setFloat(_idxOpticalProps + 1, _settings.chromaticAberration)
        ..setFloat(_idxOpticalProps + 2, thickness)
        ..setFloat(_idxOpticalProps + 3, _settings.blend * _devicePixelRatio)
        ..setFloat(_idxColorAdjust + 0, _settings.lightness)
        ..setFloat(_idxColorAdjust + 1, shapeCount.toDouble());

      for (int i = 0; i < 16; i++) {
        _blurH.setFloat(_idxTransform + i, transform.storage[i]);
      }

      for (var i = 0; i < shapeCount; i++) {
        final shape = i < shapes.length ? shapes[i].$2 : RawShape.none;
        final base = _shapeDataBaseFloat + (i * 6);
        _blurH
          ..setFloat(base + 0, shape.type.index.toDouble())
          ..setFloat(base + 1, shape.center.dx * _devicePixelRatio)
          ..setFloat(base + 2, shape.center.dy * _devicePixelRatio)
          ..setFloat(base + 3, shape.size.width * _devicePixelRatio)
          ..setFloat(base + 4, shape.size.height * _devicePixelRatio)
          ..setFloat(base + 5, shape.cornerRadius * _devicePixelRatio);
      }

      _lastShapeCount = shapeCount;
      _lastSettings = _settings;
    } else {
      _updateShapeCountIfNeeded(shapeCount);
      // H-Pass: nur die Shape-Anzahl (uColorAdjust.y) updaten.
      _blurH.setFloat(_idxColorAdjust + 1, shapeCount.toDouble());

      // Transform kann sich durch Offset/Bounds trotzdem ändern → nachziehen.
      for (int i = 0; i < 16; i++) {
        _shader.setFloat(_idxTransform + i, transform.storage[i]);
        _blurH.setFloat(_idxTransform + i, transform.storage[i]);
      }
    }

    // Horizontal pass (separate shader).
    _blurH.setFloat(_blurBaseFloat + 2, nKernel.toDouble()); // sample_count
    if (nKernel != _lastKernelCountH) {
      int base = _blurSamplesFloat;
      for (int i = 0; i < nKernel; i++) {
        final s = kernel[i];
        _blurH
          ..setFloat(base + 0, s.tPx)
          ..setFloat(base + 1, 0.0)
          ..setFloat(base + 2, s.w)
          ..setFloat(base + 3, 0.0);
        base += 4;
      }
      _lastKernelCountH = nKernel;
    }

    // Vertical pass (performed in the glass shader).
    _shader
      ..setFloat(_blurBaseFloat + 0, 0.0) // u_dir_x
      ..setFloat(_blurBaseFloat + 1, 1.0) // u_dir_y
      ..setFloat(_blurBaseFloat + 2, nKernel.toDouble())
      ..setFloat(_blurBaseFloat + 3, 0.0); // clamp

    if (nKernel != _lastKernelCountV) {
      int baseV = _blurSamplesFloat;
      for (int i = 0; i < nKernel; i++) {
        final s = kernel[i];
        _shader
          ..setFloat(baseV + 0, s.tPx)
          ..setFloat(baseV + 1, 0.0)
          ..setFloat(baseV + 2, s.w)
          ..setFloat(baseV + 3, 0.0);
        baseV += 4;
      }
      _lastKernelCountV = nKernel;
    }

    // ───────────────────── Touches & Glow ────────────────────
    final int nTouches = ownedTouches.length.clamp(0, 8);
    _shader.setFloat(_idxTouchCount, nTouches.toDouble());
    for (int i = 0; i < 8; i++) {
      final base = _idxTouches + i * 4;
      if (i < nTouches) {
        final tp = ownedTouches[i];
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

    for (int i = 0; i < 8; i++) {
      final double owner =
          (i < nTouches) ? ownedTouches[i].ownerIndex.toDouble() : -1.0;
      _shader.setFloat(_idxTouchOwners + i, owner);
    }

    for (int i = 0; i < 8; i++) {
      final double s =
          (i < nTouches) ? ownedTouches[i].glowStrength.clamp(0.0, 1.0) : 0.0;
      _shader.setFloat(_idxTouchGlowStrengths + i, s);
    }

    final glow = _settings.glow;
    final bool glowOn = glow.enabled;

    _shader
      ..setFloat(_idxGlowParams + 0, glowOn ? glow.strength : 0.0)
      ..setFloat(_idxGlowParams + 1, glow.power)
      ..setFloat(_idxGlowParams + 2, glow.tintMode.toDouble())
      ..setFloat(_idxGlowParams + 3, glow.insideOnly ? 1.0 : 0.0);

    _shader
      ..setFloat(_idxGlowColor + 0, glow.color.red / 255.0)
      ..setFloat(_idxGlowColor + 1, glow.color.green / 255.0)
      ..setFloat(_idxGlowColor + 2, glow.color.blue / 255.0)
      ..setFloat(_idxGlowColor + 3, glow.color.alpha / 255.0);

    final double mix = glowOn ? glow.mix : 0.0;
    final double targetLightness = glow.lightness ?? _settings.lightness;
    final double targetSaturation = glow.saturation ?? _settings.saturation;
    final double targetBlurSigmaPx =
        (glow.blur ?? _settings.blur) * _devicePixelRatio;
    _shader
      ..setFloat(_idxGlowOverrides + 0, targetLightness)
      ..setFloat(_idxGlowOverrides + 1, targetSaturation)
      ..setFloat(_idxGlowOverrides + 2, targetBlurSigmaPx)
      ..setFloat(_idxGlowOverrides + 3, mix);

    double f(bool cond) => (glowOn && cond) ? 1.0 : 0.0;
    _shader
      ..setFloat(_idxGlowFlags + 0, f(glow.lightness != null))
      ..setFloat(_idxGlowFlags + 1, f(glow.saturation != null))
      ..setFloat(_idxGlowFlags + 2, f(glow.blur != null))
      ..setFloat(_idxGlowFlags + 3, f(glow.glassColor != null));

    final Color gg = glow.glassColor ?? const Color(0x00000000);
    _shader
      ..setFloat(_idxGlowGlass + 0, gg.red / 255.0)
      ..setFloat(_idxGlowGlass + 1, gg.green / 255.0)
      ..setFloat(_idxGlowGlass + 2, gg.blue / 255.0)
      ..setFloat(_idxGlowGlass + 3, gg.alpha / 255.0);

    _shader.setFloat(
      _idxGlobalBlurSigma,
      _settings.blur * _devicePixelRatio,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final shapes = collectShapes();

    // Early exit if the effect is disabled or there is nothing to render.
    if (_settings.thickness <= 0 || shapes.isEmpty) {
      _backdropHandle.layer = null;
      _paintShapeContents(context, offset, shapes, glassContainsChild: true);
      _paintShapeContents(context, offset, shapes, glassContainsChild: false);
      super.paint(context, offset);
      return;
    }

    final shapeCount = math.min(_maxShapesPerLayer, shapes.length);

    // Kernel generation for the separable blur.
    final double sigmaPx = _settings.blur * _devicePixelRatio;
    final List<_PackedS> kernel = _getKernelAndMark(sigmaPx);
    final int nKernel = math.min(_impellerMaxKernel, kernel.length);

    final ownedTouches = _combineTouches(shapes);

    // Bounds werden vor Uniform-Upload berechnet und übergeben.
    var (unionBounds, clipBounds) =
        _computeUnionAndClipRect(shapes); // ein Pass
    // unionBounds = _clampBoundsToViewport(unionBounds, offset);
    clipBounds = _clampBoundsToViewport(clipBounds, offset);

    // FIX 4: KEIN Snapping der Bounds mehr!
    // Wenn der Container "springt", springt auch die Projection -> Jitter.
    // Wir nutzen weiche Float-Bounds.
    final Rect bounds = clipBounds;

    // Glas-Scale aus erstem Shape (falls vorhanden)
    Offset glassScale = const Offset(1.0, 1.0);
    if (shapes.isNotEmpty) {
      final RenderLiquidGlass ro0 = shapes.first.$1;
      final Matrix4 t0 = ro0.getTransformTo(this);
      glassScale = _getScaleXY(t0);
    }

    _uploadUniformsIfNeeded(
      shapeCount,
      shapes,
      nKernel,
      kernel,
      ownedTouches,
      bounds,
      offset,
      unionBounds,
      glassScale,
    );

    // Reflection Image (Sampler 1) setzen, falls vorhanden
    if (_imageHolder.image != null) {
      try {
        _shader.setImageSampler(1, _imageHolder.image!);
      } catch (_) {
        // Ignore lifecycle errors
      }
    }

    // ABOVE the glass first.
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    // Use ImageFilter.compose mit einem LayerHandle
    ImageFilter composedFilter;

    if (sigmaPx > 0.01 && nKernel > 0) {
      composedFilter = ImageFilter.compose(
        outer: ImageFilter.shader(_shader), // V-Pass + Effects
        inner: ImageFilter.shader(_blurH), // H-Pass (Blur only)
      );
    } else {
      // Kein Blur nötig, nur der Glass-Shader
      composedFilter = ImageFilter.shader(_shader);
    }

    final BackdropFilterLayer backdropLayer =
        _backdropHandle.layer ?? BackdropFilterLayer();
    backdropLayer.filter = composedFilter;

    context.pushClipRect(
      true,
      offset,
      bounds,
      (ctxRect, offRect) {
        ctxRect.pushLayer(
          backdropLayer,
          (childCtx, childOff) {
            childCtx.canvas.drawRect(
              bounds.shift(-childOff),
              Paint()..color = const Color(0x00000000),
            );
          },
          offRect,
        );
      },
      clipBehavior: Clip.hardEdge,
    );
    _backdropHandle.layer = backdropLayer;

    // UNDER the glass.
    _paintShapeContents(context, offset, shapes, glassContainsChild: false);

    super.paint(context, offset);
  }

  @override
  void dispose() {
    _glassLink
      ..removeListener(_onGlassLinkChanged)
      ..dispose();
    _backdropHandle.layer = null;
    super.dispose();
  }

  void _paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlass, RawShape, List<TouchPoint>)> shapes, {
    required bool glassContainsChild,
  }) {
    for (final (ro, _, __) in shapes) {
      if (ro.glassContainsChild == glassContainsChild) {
        final Matrix4 transform = ro.getTransformTo(this);
        context.pushTransform(true, offset, transform, ro.paintFromLayer);
      }
    }
  }
}

class _OwnedTouch {
  _OwnedTouch({
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
  final int ownerIndex; // 0..N-1
}
