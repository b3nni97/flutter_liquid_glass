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

const int _maxShapesPerLayer = 16;

class _RawS {
  _RawS(this.x, this.w);
  double x;
  double w;
}

class _PackedS {
  _PackedS(this.tPx, this.w);
  final double tPx;
  final double w;
}

@internal
class RenderLiquidGlassLayer extends RenderProxyBox {
  RenderLiquidGlassLayer({
    required double devicePixelRatio,
    required FragmentShader shader,
    required FragmentShader blurH,
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

  // ───────────────── Uniform-Layout (sequentielle Float-Indizes) ────────────
  // 0..1    : uSize (vec2) [von Flutter gesetzt]
  // 2..5    : uGlassColor (vec4)
  // 6..9    : uOpticalProps (vec4)
  // 10..13  : uLightConfig (vec4)
  // 14..15  : uColorAdjust (vec2) => [14]=lightness, [15]=numShapes
  // 16..17  : uLightDirection (vec2) => cos,sin
  // 18..33  : uTransform (mat4)
  // 34..129 : uShapeData (float[MAX_SHAPES*6])
  // 130..133: uBlurHeader (vec4) => dir.x, dir.y, sample_count, tile_mode
  // 134..   : u_samples[0].. (vec4 pro Sample)
  static const int _idxGlassColor = 2;
  static const int _idxOpticalProps = 6;
  static const int _idxLightConfig = 10;
  static const int _idxColorAdjust = 14; // x: lightness, y: numShapes(@+1)
  static const int _idxLightDir = 16;
  static const int _idxTransform = 18;

  static const int _shapeDataBaseFloat = 34; // erster Float von uShapeData
  static const int _blurBaseFloat = 130; // uBlurHeader.x (u_dir_x)
  static const int _blurSamplesFloat = 134; // u_samples[0].x

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

  List<_PackedS>? _cachedKernel;
  int _cachedSigmaBucketKernel = -1;
  int _lastKernelCountH = -1;
  int _lastKernelCountV = -1;
  int _lastShapeCount = -1;
  LiquidGlassSettings? _lastSettings;
  List<RawShape>? _lastShapes;

  bool _hInvariantsInitialized = false;

  // Layerhandles wie in der funktionierenden Version
  final LayerHandle<BackdropFilterLayer> _hHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<BackdropFilterLayer> _vHandle =
      LayerHandle<BackdropFilterLayer>();

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
      ..setFloat(2, 1.0) // u_dir.x (H-Pass Shader)
      ..setFloat(3, 0.0) // u_dir.y
      ..setFloat(5, 0.0); // u_tile_mode (clamp)
    _hInvariantsInitialized = true;
  }

  List<(RenderLiquidGlass, RawShape)> collectShapes() {
    final result = <(RenderLiquidGlass, RawShape)>[];
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
        ));
      }
    }
    return result;
  }

  double _getScaleFromTransform(Matrix4 transform) {
    final m = transform.storage;
    if (m[1] == 0 && m[4] == 0) {
      final sx = m[0].abs();
      final sy = m[5].abs();
      return math.sqrt(sx * sy);
    }
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final scaleXSq = a * a + b * b;
    final scaleYSq = c * c + d * d;
    return math.sqrt(math.sqrt(scaleXSq * scaleYSq));
  }

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

  static final List<double> _identityMat4 = <double>[
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1,
  ];

  void _uploadUniformsIfNeeded(
    int shapeCount,
    List<(RenderLiquidGlass, RawShape)> shapes,
    int nKernel,
    List<_PackedS> kernel,
  ) {
    final settingsChanged = _lastSettings != _settings;
    final shapesChanged = _shapesChanged(shapes);

    var thickness = _settings.thickness;
    if (_restrictThickness && shapes.isNotEmpty) {
      final smallest = shapes
          .map((e) => e.$2.size.shortestSide)
          .reduce((a, b) => a < b ? a : b);
      thickness = math.min(thickness, smallest);
    }

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
        ..setFloat(_idxLightDir + 1, math.sin(_settings.lightAngle));

      for (int i = 0; i < 16; i++) {
        _shader.setFloat(_idxTransform + i, _identityMat4[i]);
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

      _lastShapeCount = shapeCount;
      _lastSettings = _settings;
    } else {
      _updateShapeCountIfNeeded(shapeCount);
    }

    // H-Pass (separater Shader)
    _blurH.setFloat(4, nKernel.toDouble());
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

    // V-Pass (im Glas-Shader)
    _shader
      ..setFloat(_blurBaseFloat + 0, 0.0) // u_dir_x
      ..setFloat(_blurBaseFloat + 1, 1.0) // u_dir_y
      ..setFloat(_blurBaseFloat + 2, nKernel.toDouble()) // u_sample_count
      ..setFloat(_blurBaseFloat + 3, 0.0); // u_tile_mode = clamp

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
  }

  Rect _snapRectToDeviceFull(Rect r) {
    final d = _devicePixelRatio;
    double s(double v) => (v * d).roundToDouble() / d;
    final l = s(r.left), t = s(r.top), rr = s(r.right), bb = s(r.bottom);
    return Rect.fromLTRB(l, t, rr, bb);
  }

  Path _computeUnionClipPath(List<(RenderLiquidGlass, RawShape)> shapes) {
    final path = Path();
    for (final (ro, raw) in shapes) {
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

    // σ & Kernel
    final double sigmaPx = _settings.blur * _devicePixelRatio;
    final List<_PackedS> kernel = _getKernelAndMark(sigmaPx);
    final int nKernel = math.min(_impellerMaxKernel, kernel.length);

    // Uniforms hochladen (inkl. V-Pass Samples später)
    _uploadUniformsIfNeeded(shapeCount, shapes, nKernel, kernel);

    // Inhalte ÜBER dem Glas zuerst
    _paintShapeContents(context, offset, shapes, glassContainsChild: true);

    // Clip-Pfad exakt auf Shapes
    final Path clipPath = _computeUnionClipPath(shapes);
    if (clipPath.computeMetrics().isEmpty) {
      _hHandle.layer = null;
      _vHandle.layer = null;
      super.paint(context, offset);
      return;
    }

    // Inflated Bounds (Sampling Coverage), auf Device-Pixel gesnappt
    final Rect bounds = _snapRectToDeviceFull(_computeUnionClipRect(shapes));

    context.pushClipRect(
      true,
      offset,
      bounds,
      (ctxRect, offRect) {
        // ein gemeinsamer Path-Clip für beide Pässe → exakt gleiche Maske
        ctxRect.pushClipPath(
          true,
          offRect,
          bounds,
          clipPath,
          (ctx, off) {
            // ---------- PASS 1: Horizontaler Blur ----------
            if (sigmaPx > 0.0 && nKernel > 0) {
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
              hLayer..filter = ImageFilter.shader(_blurH);

              ctx.pushLayer(hLayer, (c2, o2) {
                final paint = Paint()..color = const Color(0x01000000);
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
              ..setFloat(_blurBaseFloat + 3, 0.0); // clamp

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
            vLayer..filter = ImageFilter.shader(_shader);

            ctx.pushLayer(vLayer, (c2, o2) {
              final paint = Paint()..color = const Color(0x01000000);
              c2.canvas.drawRect(bounds.shift(-off), paint);
            }, off);
            _vHandle.layer = vLayer;
          },
          clipBehavior:
              Clip.hardEdge, // exakt wie in der funktionierenden Version
        );
      },
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

  void _paintShapeContents(
    PaintingContext context,
    Offset offset,
    List<(RenderLiquidGlass, RawShape)> shapes, {
    required bool glassContainsChild,
  }) {
    for (final (ro, _) in shapes) {
      if (ro.glassContainsChild == glassContainsChild) {
        // ← zurück zur alten Variante
        final Matrix4 transform = ro.getTransformTo(this);
        context.pushTransform(true, offset, transform, ro.paintFromLayer);
      }
    }
  }
}
