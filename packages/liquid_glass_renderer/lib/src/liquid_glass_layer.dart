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
      ..setShaders(shader, blurH); // neue Instanzen übernehmen
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
  }

  // -------------------- Konstanten / Layout --------------------
  // Shader-Layout:
  //  0:  uSize (vec2) — von Flutter gesetzt (nicht manuell setzen!)
  //  1:  uGlassColor   (vec4) → floats  2..5
  //  2:  uOpticalProps (vec4) → floats  6..9
  //  3:  uLightConfig  (vec4) → floats 10..13
  //  4:  uColorAdjust  (vec2) → floats 14..15
  //  5:  uLightDirection(vec2)→ floats 16..17
  //  6:  uShapeData[96]       → floats 18..113  (16*6)
  // 102: u_dir_x               → float 114
  // 103: u_dir_y               → float 115
  // 104: u_sample_count        → float 116
  // 105: u_tile_mode           → float 117
  // 106: u_samples[0] (vec4)   → float 118, dann +4 je Sample
  static const int _shapeDataBaseFloat = 18; // = first float of uShapeData
  static const int _blurBaseFloat = 114; // u_dir_x Start
  static const int _blurSamplesFloat = 118; // u_samples[0]

  static const double _eps = 0.01;

  // -------------------- GlassLink / Registrierung --------------
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
      markNeedsPaint();
    }
    if (!identical(_blurH, blurH)) {
      _blurH = blurH;
      markNeedsPaint();
    }
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
    // Sicherheitsrand: 3*σ + thickness + Puffer
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

  List<_PackedS> _computeImpellerKernel(double sigmaPx) {
    final scaled = _scaleSigma(sigmaPx);
    final r = _sigmaToRadius(scaled).round();
    if (r <= 0) return <_PackedS>[_PackedS(0.0, 1.0)];
    return _lerpHack(_genRaw(scaled, r));
  }

  // -------------------- Upload Glass-Uniforms -------------------
  LiquidGlassSettings? _lastSettings;
  List<RawShape>? _lastShapes;

  void _uploadUniformsIfNeeded(
    int shapeCount,
    List<(RenderLiquidGlass, RawShape)> shapes,
  ) {
    final settingsChanged = _lastSettings != _settings;
    final shapesChanged = _shapesChanged(shapes);

    // thickness ggf. clampen (restrictThickness)
    var thickness = _settings.thickness;
    if (_restrictThickness && shapes.isNotEmpty) {
      final smallest = shapes
          .map((e) => e.$2.size.shortestSide)
          .reduce((a, b) => a < b ? a : b);
      thickness = math.min(thickness, smallest);
    }

    if (!settingsChanged && !shapesChanged) {
      // shapeCount wird immer aktualisiert
      _shader.setFloat(15, shapeCount.toDouble()); // count an float 15
      return;
    }
    _lastSettings = _settings;

    // Packed Header (Float-Indizes, NICHT locations):
    _shader
      // uGlassColor (vec4) 2..5
      ..setFloat(2, _settings.glassColor.r)
      ..setFloat(3, _settings.glassColor.g)
      ..setFloat(4, _settings.glassColor.b)
      ..setFloat(5, _settings.glassColor.a)
      // uOpticalProps (vec4) 6..9
      ..setFloat(6, _settings.refractiveIndex)
      ..setFloat(7, _settings.chromaticAberration)
      ..setFloat(8, thickness)
      ..setFloat(9, _settings.blend * _devicePixelRatio)
      // uLightConfig (vec4) 10..13
      ..setFloat(10, _settings.lightAngle)
      ..setFloat(11, _settings.lightIntensity)
      ..setFloat(12, _settings.ambientStrength)
      ..setFloat(13, _settings.saturation)
      // uColorAdjust (vec2) 14..15
      ..setFloat(14, _settings.lightness)
      ..setFloat(15, shapeCount.toDouble())
      // uLightDirection (vec2) 16..17
      ..setFloat(16, math.cos(_settings.lightAngle))
      ..setFloat(17, math.sin(_settings.lightAngle));

    // Shapes: je 6 floats ab 18
    for (var i = 0; i < shapeCount; i++) {
      final shape = i < shapes.length ? shapes[i].$2 : RawShape.none;
      final base = _shapeDataBaseFloat + (i * 6); // 18 + i*6
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

  Offset _snapOffsetToDevice(Offset o) {
    final d = _devicePixelRatio;
    double s(double v) => (v * d).roundToDouble() / d;
    return Offset(s(o.dx), s(o.dy));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Shapes einsammeln (über GlassLink)
    final shapes = collectShapes();

    // Early-out: kein Glas oder keine Shapes
    if (_settings.thickness <= 0 || shapes.isEmpty) {
      _hHandle.layer = null;
      _vHandle.layer = null;
      _paintShapeContents(context, offset, shapes, glassContainsChild: true);
      _paintShapeContents(context, offset, shapes, glassContainsChild: false);
      super.paint(context, offset);
      return;
    }

    // Host-Uniforms (Glass) updaten
    final shapeCount = math.min(_maxShapesPerLayer, shapes.length);
    _uploadUniformsIfNeeded(shapeCount, shapes);

    // Inhalte ÜBER dem Glas zuerst
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    // Clip-Path nur unter den Shapes
    final Path clipPath = _computeUnionClipPath(shapes);
    if (clipPath.computeMetrics().isEmpty) {
      _hHandle.layer = null;
      _vHandle.layer = null;
      super.paint(context, offset);
      return;
    }

    // Bounds (gesnappt)
    final Rect rawBounds = _computeUnionClipRect(shapes);
    final Rect bounds = _snapRectToDeviceFull(rawBounds);

    // σ in Device-Pixeln (Impeller-Kernel)
    final double sigmaPx = _settings.blur * _devicePixelRatio;

    context.pushClipPath(
      true,
      offset,
      bounds,
      clipPath,
      (ctx, off) {
        final Size screenLogical = RendererBinding.instance.renderView.size;
        final Size screenDevice = Size(
          screenLogical.width * _devicePixelRatio,
          screenLogical.height * _devicePixelRatio,
        );

        // ---------- PASS 1: H-Blur (gaussian_1d_blur.frag) ----------
        if (sigmaPx > 0.0) {
          final kH = _computeImpellerKernel(sigmaPx); // tPx,w

          // u_dir=(1,0), u_sample_count, u_tile_mode=0 (clamp)
          _blurH
            ..setFloat(2, 1.0) // u_dir.x
            ..setFloat(3, 0.0) // u_dir.y
            ..setFloat(4, kH.length.toDouble()) // u_sample_count
            ..setFloat(5, 0.0); // u_tile_mode (clamp)

          // u_samples[i] = vec4(tPx, 0, w, 0)
          int base = 6;
          final int nH = math.min(_impellerMaxKernel, kH.length);
          for (int i = 0; i < nH; i++) {
            final s = kH[i];
            _blurH
              ..setFloat(base + i * 4 + 0, s.tPx)
              ..setFloat(base + i * 4 + 1, 0.0)
              ..setFloat(base + i * 4 + 2, s.w)
              ..setFloat(base + i * 4 + 3, 0.0);
          }

          final BackdropFilterLayer hLayer =
              _hHandle.layer ?? BackdropFilterLayer();
          hLayer
            ..filter = ImageFilter.shader(_blurH)
            ..backdropKey = null;

          // sichere Coverage (unsichtbares Rechteck)
          ctx.pushLayer(hLayer, (c2, o2) {
            final paint = Paint()..color = const Color(0x01000000);
            c2.canvas.drawRect(bounds.shift(-off), paint);
          }, off);
          _hHandle.layer = hLayer;
        } else {
          _hHandle.layer = null;
        }

        // ---------- PASS 2: V-Blur + Glas (liquid_glass.frag) ----------
        if (sigmaPx > 0.0 || true) {
          final kV = _computeImpellerKernel(sigmaPx); // tPx,w
          final int nV = math.min(_impellerMaxKernel, kV.length);

          // u_dir = (0,1), u_sample_count, tile_mode=0
          _shader
            ..setFloat(_blurBaseFloat + 0, 0.0) // u_dir_x @114
            ..setFloat(_blurBaseFloat + 1, 1.0) // u_dir_y @115
            ..setFloat(_blurBaseFloat + 2, nV.toDouble()) // u_sample_count @116
            ..setFloat(_blurBaseFloat + 3, 0.0); // u_tile_mode @117

          // u_samples[i] = vec4(tPx, 0, w, 0) ab 118
          int baseV = _blurSamplesFloat;
          for (int i = 0; i < nV; i++) {
            final s = kV[i];
            _shader
              ..setFloat(baseV + 0, s.tPx)
              ..setFloat(baseV + 1, 0.0)
              ..setFloat(baseV + 2, s.w)
              ..setFloat(baseV + 3, 0.0);
            baseV += 4;
          }

          final BackdropFilterLayer vLayer =
              _vHandle.layer ?? BackdropFilterLayer();
          vLayer
            ..filter = ImageFilter.shader(_shader) // liquid_glass.frag
            ..backdropKey = null;

          ctx.pushLayer(vLayer, (c2, o2) {
            final paint = Paint()..color = const Color(0x01000000);
            c2.canvas.drawRect(bounds.shift(-off), paint);
          }, off);
          _vHandle.layer = vLayer;
        } else {
          _vHandle.layer = null;
        }
      },
      clipBehavior: Clip.antiAlias,
    );

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
