// ignore_for_file: avoid_setters_without_getters

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_shaders/flutter_shaders.dart';
import 'package:liquid_glass_renderer/src/glass_link.dart';
import 'package:liquid_glass_renderer/src/liquid_glass.dart';
import 'package:liquid_glass_renderer/src/liquid_glass_settings.dart';
import 'package:liquid_glass_renderer/src/raw_shapes.dart';
import 'package:liquid_glass_renderer/src/shaders.dart';
import 'package:meta/meta.dart';

/// Represents a layer of multiple [LiquidGlass] shapes that can flow together
/// and share [LiquidGlassSettings].
class LiquidGlassLayer extends StatefulWidget {
  const LiquidGlassLayer({
    required this.child,
    this.settings = const LiquidGlassSettings(),
    this.restrictThickness = true,
    super.key,
  });

  final Widget child;
  final LiquidGlassSettings settings;

  /// If true, clamp thickness to the shortest side of the smallest shape.
  /// Prevents artifacts on very thin/small shapes.
  final bool restrictThickness;

  @override
  State<LiquidGlassLayer> createState() => _LiquidGlassLayerState();
}

class _LiquidGlassLayerState extends State<LiquidGlassLayer>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    if (!ImageFilter.isShaderFilterSupported) {
      assert(
        ImageFilter.isShaderFilterSupported,
        'liquid_glass_renderer is only supported with Impeller. '
        'Enable Impeller or guard with ImageFilter.isShaderFilterSupported.',
      );
      return widget.child;
    }

    return ShaderBuilder(
      assetKey: liquidGlassShader, // Host (liquid_glass.frag)
      (context, glassShader, child) => ShaderBuilder(
        assetKey: gaussian1dBlurShader, // H-Pass (gauss1d_linear.frag)
        (context, blurH, child) => _RawShapes(
          shader: glassShader,
          blurH: blurH,
          settings: widget.settings,
          debugRenderRefractionMap: false,
          restrictThickness: widget.restrictThickness,
          child: child!,
        ),
        child: child,
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
    required Widget super.child,
  });

  final FragmentShader shader;
  final FragmentShader blurH;
  final LiquidGlassSettings settings;
  final bool debugRenderRefractionMap;
  final bool restrictThickness;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidGlassLayer(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      shader: shader,
      blurH: blurH,
      settings: settings,
      debugRenderRefractionMap: debugRenderRefractionMap,
      restrictThickness: restrictThickness,
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
      ..setShaders(shader, blurH);
  }
}

/// Maximum number of shapes supported per layer due to Impeller's uniform limit
const int _maxShapesPerLayer = 16;

// ────────────────────────── Top-Level Helper-Klassen ──────────────────────────
class _RawS {
  _RawS(this.x, this.w);
  double x; // Offset in Pixeln
  double w; // Gewicht (normalisiert wird später)
}

class _PackedS {
  _PackedS(this.tPx, this.w);
  final double tPx; // Offset entlang Achse in Pixeln
  final double w; // Gewicht (normiert)
}

// ───────────────────────── RenderLiquidGlassLayer ─────────────────────────────
@internal
class RenderLiquidGlassLayer extends RenderProxyBox {
  RenderLiquidGlassLayer({
    required double devicePixelRatio,
    required FragmentShader shader, // liquid_glass.frag (V-Pass + Extras)
    required FragmentShader blurH, // gaussian_1d_blur.frag (H-Pass)
    required LiquidGlassSettings settings,
    required bool restrictThickness,
    bool debugRenderRefractionMap = false,
  })  : _devicePixelRatio = devicePixelRatio,
        _shader = shader,
        _blurH = blurH,
        _settings = settings,
        _debugRenderRefractionMap = debugRenderRefractionMap,
        _restrictThickness = restrictThickness,
        _glassLink = GlassLink() {
    _glassLink.addListener(_onGlassLinkChanged);
    _initHBlurInvariants();
  }

  // -------------------- Shader-Layout (Float-Indices) ----------
  static const int _shapeDataBaseFloat = 18; // first float of uShapeData
  static const int _blurBaseFloat = 114; // u_dir_x start
  static const int _blurSamplesFloat = 118; // u_samples[0]
  static const double _eps = 0.01;

  // -------------------- GlassLink -------------------------------
  final GlassLink _glassLink;
  GlassLink get glassLink => _glassLink;
  void _onGlassLinkChanged() => markNeedsPaint();

  // -------------------- State / Shader / Settings --------------
  double _devicePixelRatio;
  FragmentShader _shader; // liquid_glass.frag
  FragmentShader _blurH; // gaussian_1d_blur.frag
  LiquidGlassSettings _settings;
  bool _debugRenderRefractionMap;
  bool _restrictThickness;

  // ---- Kernel-/Uniform-Optimierungen ----
  List<_PackedS>? _cachedKernel;
  int _cachedSigmaBucketKernel = -1;
  int _lastKernelCountH = -1;
  int _lastKernelCountV = -1;
  int _lastShapeCount = -1;
  LiquidGlassSettings? _lastSettings;
  List<RawShape>? _lastShapes;

  // H-Pass invariants init-Flag
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

  void _initHBlurInvariants() {
    if (_hInvariantsInitialized) return;
    _blurH
      ..setFloat(2, 1.0) // u_dir.x
      ..setFloat(3, 0.0) // u_dir.y
      ..setFloat(5, 0.0); // u_tile_mode (clamp)
    _hInvariantsInitialized = true;
  }

  // -------------------- Layer Handles --------------------------
  final LayerHandle<BackdropFilterLayer> _hHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<BackdropFilterLayer> _vHandle =
      LayerHandle<BackdropFilterLayer>();

  // -------------------- Shapes sammeln -------------------------
  List<(RenderLiquidGlass, RawShape)> collectShapes() {
    final result = <(RenderLiquidGlass, RawShape)>[];
    final computed = _glassLink.computedShapes;

    if (computed.length > _maxShapesPerLayer) {
      throw UnsupportedError('Only $_maxShapesPerLayer shapes are supported!');
    }

    for (final s in computed) {
      final ro = s.renderObject;
      if (ro is RenderLiquidGlass) {
        result.add((
          ro,
          RawShape.fromLiquidGlassShape(
            s.shape,
            center: s.globalBounds.center,
            size: s.globalBounds.size,
          ),
        ));
      }
    }
    return result;
  }

  // -------------------- Union-Bounds / Path --------------------
  Rect _computeUnionClipRect(List<(RenderLiquidGlass, RawShape)> shapes) {
    Rect? union;
    for (final (ro, _) in shapes) {
      final transformToThis = ro.getTransformTo(this);
      final rectLocal =
          MatrixUtils.transformRect(transformToThis, Offset.zero & ro.size);
      union = (union == null) ? rectLocal : union!.expandToInclude(rectLocal);
    }
    // 3σ + thickness + Puffer → genügend Sampling-Reichweite
    final double margin = (_settings.blur * 3.0) + _settings.thickness + 12.0;
    return (union ?? Rect.zero).inflate(margin);
  }

  Path _computeUnionClipPath(List<(RenderLiquidGlass, RawShape)> shapes) {
    final path = Path();
    for (final (ro, raw) in shapes) {
      final transform = ro.getTransformTo(this);
      final rectLocal =
          MatrixUtils.transformRect(transform, Offset.zero & ro.size);
      final t = raw.type.index;
      if (t == 2) {
        path.addOval(rectLocal);
      } else {
        final r = Radius.circular(raw.cornerRadius);
        path.addRRect(RRect.fromRectAndCorners(
          rectLocal,
          topLeft: r,
          topRight: r,
          bottomLeft: r,
          bottomRight: r,
        ));
      }
    }
    return path;
  }

  // ----------------- Impeller/Skia-Kernel (Pixel) ---------------
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

  // -------------------- Upload Glass-Uniforms -------------------
  void _updateShapeCountIfNeeded(int shapeCount) {
    if (_lastShapeCount == shapeCount) return;
    _shader.setFloat(15, shapeCount.toDouble());
    _lastShapeCount = shapeCount;
  }

  bool _shapesChanged(List<(RenderLiquidGlass, RawShape)> shapes) {
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

  void _uploadUniformsIfNeeded(
    int shapeCount,
    List<(RenderLiquidGlass, RawShape)> shapes,
  ) {
    final settingsChanged = _lastSettings != _settings;
    final shapesChanged = _shapesChanged(shapes);

    // thickness ggf. clampen
    var thickness = _settings.thickness;
    if (_restrictThickness && shapes.isNotEmpty) {
      final smallest = shapes
          .map((e) => e.$2.size.shortestSide)
          .reduce((a, b) => a < b ? a : b);
      thickness = math.min(thickness, smallest);
    }

    if (!settingsChanged && !shapesChanged) {
      _updateShapeCountIfNeeded(shapeCount);
      return;
    }
    _lastSettings = _settings;

    _shader
      ..setFloat(2, _settings.glassColor.r)
      ..setFloat(3, _settings.glassColor.g)
      ..setFloat(4, _settings.glassColor.b)
      ..setFloat(5, _settings.glassColor.a)
      ..setFloat(6, _settings.refractiveIndex)
      ..setFloat(7, _settings.chromaticAberration)
      ..setFloat(8, thickness)
      ..setFloat(9, _settings.blend * _devicePixelRatio)
      ..setFloat(10, _settings.lightAngle)
      ..setFloat(11, _settings.lightIntensity)
      ..setFloat(12, _settings.ambientStrength)
      ..setFloat(13, _settings.saturation)
      ..setFloat(14, _settings.lightness)
      ..setFloat(15, shapeCount.toDouble())
      ..setFloat(16, math.cos(_settings.lightAngle))
      ..setFloat(17, math.sin(_settings.lightAngle));

    _lastShapeCount = shapeCount;

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
  }

  // -------------------- Snap Helpers ---------------------------
  Rect _snapRectToDeviceFull(Rect r) {
    final d = _devicePixelRatio;
    double s(double v) => (v * d).roundToDouble() / d;
    final l = s(r.left), t = s(r.top), rr = s(r.right), bb = s(r.bottom);
    return Rect.fromLTRB(l, t, rr, bb);
  }

  // -------------------- Painting -------------------------------
  @override
  void paint(PaintingContext context, Offset offset) {
    final shapes = collectShapes();

    // Early-out
    if (_settings.thickness <= 0 || shapes.isEmpty) {
      _hHandle.layer = null;
      _vHandle.layer = null;
      _paintShapeContents(context, offset, shapes, glassContainsChild: true);
      _paintShapeContents(context, offset, shapes, glassContainsChild: false);
      super.paint(context, offset);
      return;
    }

    final shapeCount = math.min(_maxShapesPerLayer, shapes.length);
    _uploadUniformsIfNeeded(shapeCount, shapes);

    // Inhalte ÜBER dem Glas zuerst
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    // Clip-Path exakt auf Shapes
    final Path clipPath = _computeUnionClipPath(shapes);
    if (clipPath.computeMetrics().isEmpty) {
      _hHandle.layer = null;
      _vHandle.layer = null;
      super.paint(context, offset);
      return;
    }

    // Inflated Bounds (Sampling-Coverage), gesnappt
    final Rect bounds = _snapRectToDeviceFull(_computeUnionClipRect(shapes));

    // σ in Device-Pixeln
    final double sigmaPx = _settings.blur * _devicePixelRatio;
    final List<_PackedS> kernel = _getKernelAndMark(sigmaPx);
    final int nKernel = math.min(_impellerMaxKernel, kernel.length);

    context.pushClipRect(
      true,
      offset,
      bounds, // große Coverage-Rechteckfläche (Sampling/Invalidation)
      (ctxRect, offRect) {
        // EIN gemeinsamer Pfadclip für beide Pässe → sichtbares Ergebnis exakt
        ctxRect.pushClipPath(
          true,
          offRect,
          bounds,
          clipPath,
          (ctx, off) {
            // ---------- PASS 1: Horizontaler Blur ----------
            if (sigmaPx > 0.0 && nKernel > 0) {
              // Invariants wurden einmalig gesetzt
              _blurH.setFloat(4, nKernel.toDouble()); // u_sample_count
              if (nKernel != _lastKernelCountH) {
                int base = 6;
                for (int i = 0; i < nKernel; i++) {
                  final s = kernel[i];
                  _blurH
                    ..setFloat(base + i * 4 + 0, s.tPx)
                    ..setFloat(base + i * 4 + 1, 0.0)
                    ..setFloat(base + i * 4 + 2, s.w)
                    ..setFloat(base + i * 4 + 3, 0.0);
                }
                _lastKernelCountH = nKernel;
              }

              final BackdropFilterLayer hLayer =
                  _hHandle.layer ?? BackdropFilterLayer();
              hLayer
                ..filter = ImageFilter.shader(_blurH)
                ..backdropKey = null;

              ctx.pushLayer(hLayer, (c2, o2) {
                final paint = Paint()..color = const Color(0x01000000);
                // wichtig: in Layer-Koordinaten zeichnen
                c2.canvas.drawRect(bounds.shift(-off), paint);
              }, off);
              _hHandle.layer = hLayer;
            } else {
              _hHandle.layer = null;
            }

            // ---------- PASS 2: Vertikaler Blur + Glas ----------
            final int nV = (sigmaPx > 0.0) ? nKernel : 0;

            _shader
              ..setFloat(_blurBaseFloat + 0, 0.0) // dir.x
              ..setFloat(_blurBaseFloat + 1, 1.0) // dir.y
              ..setFloat(_blurBaseFloat + 2, nV.toDouble())
              ..setFloat(_blurBaseFloat + 3, 0.0); // tile_mode=clamp

            if (nV != _lastKernelCountV) {
              int baseV = _blurSamplesFloat;
              for (int i = 0; i < nV; i++) {
                final s = kernel[i];
                _shader
                  ..setFloat(baseV + 0, s.tPx)
                  ..setFloat(baseV + 1, 0.0)
                  ..setFloat(baseV + 2, s.w)
                  ..setFloat(baseV + 3, 0.0);
                baseV += 4;
              }
              _lastKernelCountV = nV;
            }

            final BackdropFilterLayer vLayer =
                _vHandle.layer ?? BackdropFilterLayer();
            vLayer
              ..filter = ImageFilter.shader(_shader)
              ..backdropKey = null;

            ctx.pushLayer(vLayer, (c2, o2) {
              final paint = Paint()..color = const Color(0x01000000);
              c2.canvas.drawRect(bounds.shift(-off), paint);
            }, off);
            _vHandle.layer = vLayer;
          },
          clipBehavior:
              Clip.antiAlias, // AA wie in deiner funktionierenden Version
        );
      },
      // Rect-Clip kann hard oder AA sein; AA hier egal, da Path danach maskiert.
      clipBehavior: Clip.hardEdge,
    );

    // Inhalte UNTER dem Glas zuletzt
    _paintShapeContents(context, offset, shapes, glassContainsChild: false);

    super.paint(context, offset);
  }

  @override
  void dispose() {
    _glassLink
      ..removeListener(_onGlassLinkChanged)
      ..dispose();
    super.dispose();
  }

  // -------------------- Inhalte malen --------------------------
  void _paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlass, RawShape)> shapes, {
    required bool glassContainsChild,
  }) {
    for (final (ro, _) in shapes) {
      if (ro.glassContainsChild == glassContainsChild) {
        final transform = ro.getTransformTo(this);
        context.pushTransform(true, offset, transform, ro.paintFromLayer);
      }
    }
  }
}
