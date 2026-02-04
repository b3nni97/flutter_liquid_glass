import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_shaders/flutter_shaders.dart';

// Stelle sicher, dass dieser Pfad in deinem Projekt stimmt:
import 'package:liquid_glass_renderer/src/shaders.dart';

/// Definiert, wie ein Layer gerendert werden soll.
enum BlendLayerType {
  /// Zeichnet das Originalbild ohne Shader-Maskierung.
  base,

  /// Zeichnet NUR die [keyColor]-Bereiche (das Icon) in der gewählten Farbe.
  colorize,

  /// Zeichnet das Bild, schneidet aber die [keyColor]-Bereiche heraus (Loch).
  cutout,
}

/// Konfiguration für einen einzelnen Blend-Layer.
class BlendLayer {
  const BlendLayer({
    this.color,
    this.blendMode = BlendMode.srcOver,
    this.type = BlendLayerType.base,
  });

  final Color? color;
  final BlendMode blendMode;
  final BlendLayerType type;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlendLayer &&
          other.color == color &&
          other.blendMode == blendMode &&
          other.type == type;

  @override
  int get hashCode => Object.hash(color, blendMode, type);
}

/// Ein Widget, das mehrere Blend-Layer auf sein Kind anwendet.
class LayeredBlendRenderer extends StatefulWidget {
  const LayeredBlendRenderer({
    super.key,
    required this.layers,
    required this.child,
    this.keyColor = const Color(0xFFFFFFFF), // Standard: Weiß
    this.filterQuality = FilterQuality.low,
  });

  final List<BlendLayer> layers;
  final Widget child;
  final Color keyColor;
  final FilterQuality filterQuality;

  @override
  State<LayeredBlendRenderer> createState() => _LayeredBlendRendererState();
}

class _LayeredBlendRendererState extends State<LayeredBlendRenderer> {
  final ChangeNotifier _repaintNotifier = ChangeNotifier();

  @override
  void dispose() {
    _repaintNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double pixelRatio = MediaQuery.of(context).devicePixelRatio;

    return ShaderBuilder(
      assetKey: blendMaskShader,
      (BuildContext context, ui.FragmentShader shader, Widget? child) {
        return _LayeredBlendRenderObjectWidget(
          layers: widget.layers,
          pixelRatio: pixelRatio,
          filterQuality: widget.filterQuality,
          repaintNotifier: _repaintNotifier,
          keyColor: widget.keyColor,
          maskingShader: shader,
          child: child!,
        );
      },
      child: _NotifyRepaintBoundary(
        repaintNotifier: _repaintNotifier,
        child: widget.child,
      ),
    );
  }
}

// --- REPAINT BOUNDARY NOTIFIER ---

class _NotifyRepaintBoundary extends SingleChildRenderObjectWidget {
  const _NotifyRepaintBoundary({
    required Widget child,
    required this.repaintNotifier,
  }) : super(child: child);

  final ChangeNotifier repaintNotifier;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNotifyRepaintBoundary(repaintNotifier: repaintNotifier);

  @override
  void updateRenderObject(
      BuildContext context, _RenderNotifyRepaintBoundary renderObject) {
    renderObject.repaintNotifier = repaintNotifier;
  }
}

class _RenderNotifyRepaintBoundary extends RenderRepaintBoundary {
  _RenderNotifyRepaintBoundary({required ChangeNotifier repaintNotifier})
      : _repaintNotifier = repaintNotifier;
  ChangeNotifier _repaintNotifier;
  set repaintNotifier(ChangeNotifier value) {
    if (_repaintNotifier == value) return;
    _repaintNotifier = value;
  }

  @override
  void markNeedsPaint() {
    if (attached) {
      // ignore: invalid_use_of_protected_member
      _repaintNotifier.notifyListeners();
    }
    super.markNeedsPaint();
  }
}

// --- RENDER OBJECT WIDGET ---

class _LayeredBlendRenderObjectWidget extends SingleChildRenderObjectWidget {
  const _LayeredBlendRenderObjectWidget({
    required this.layers,
    required this.pixelRatio,
    required this.filterQuality,
    required this.repaintNotifier,
    required this.keyColor,
    required this.maskingShader,
    required Widget child,
  }) : super(child: child);

  final List<BlendLayer> layers;
  final double pixelRatio;
  final FilterQuality filterQuality;
  final ChangeNotifier repaintNotifier;
  final Color keyColor;
  final ui.FragmentShader maskingShader;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLayeredBlendProxy(
        layers: layers,
        pixelRatio: pixelRatio,
        filterQuality: filterQuality,
        repaintNotifier: repaintNotifier,
        keyColor: keyColor,
        maskingShader: maskingShader,
      );

  @override
  void updateRenderObject(
      BuildContext context, _RenderLayeredBlendProxy renderObject) {
    renderObject
      ..layers = layers
      ..pixelRatio = pixelRatio
      ..filterQuality = filterQuality
      ..repaintNotifier = repaintNotifier
      ..keyColor = keyColor
      ..maskingShader = maskingShader;
  }
}

// --- CORE RENDERER ---

class _RenderLayeredBlendProxy extends RenderProxyBox {
  _RenderLayeredBlendProxy({
    required List<BlendLayer> layers,
    required double pixelRatio,
    required FilterQuality filterQuality,
    required ChangeNotifier repaintNotifier,
    required Color keyColor,
    required ui.FragmentShader maskingShader,
    RenderBox? child,
  })  : _layers = layers,
        _pixelRatio = pixelRatio,
        _filterQuality = filterQuality,
        _repaintNotifier = repaintNotifier,
        _keyColor = keyColor,
        _maskingShader = maskingShader,
        super(child);

  List<BlendLayer> _layers;
  double _pixelRatio;
  FilterQuality _filterQuality;
  ChangeNotifier _repaintNotifier;
  Color _keyColor;
  ui.FragmentShader _maskingShader;

  ui.Image? _cachedImage;
  bool _isCacheStale = false;
  bool _snapshotScheduled = false;
  final Paint _paintObject = Paint();

  set layers(List<BlendLayer> value) {
    if (listEquals(_layers, value)) return;
    _layers = value;
    markNeedsPaint();
  }

  set pixelRatio(double value) {
    if (_pixelRatio == value) return;
    _pixelRatio = value;
    _invalidateCache();
  }

  set filterQuality(FilterQuality value) {
    if (_filterQuality == value) return;
    _filterQuality = value;
    markNeedsPaint();
  }

  set repaintNotifier(ChangeNotifier value) {
    if (_repaintNotifier == value) return;
    _repaintNotifier.removeListener(_invalidateCache);
    _repaintNotifier = value;
    if (attached) _repaintNotifier.addListener(_invalidateCache);
  }

  set keyColor(Color value) {
    if (_keyColor == value) return;
    _keyColor = value;
    markNeedsPaint();
  }

  set maskingShader(ui.FragmentShader value) {
    if (_maskingShader == value) return;
    _maskingShader = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _repaintNotifier.addListener(_invalidateCache);
  }

  @override
  void detach() {
    _repaintNotifier.removeListener(_invalidateCache);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (_cachedImage != null) {
      _paintCachedImage(context, offset);
      _handleStaleCache(context, offset);
      return;
    }
    context.paintChild(child!, offset);
    _requestSnapshot();
  }

  @override
  void dispose() {
    _cachedImage?.dispose();
    _cachedImage = null;
    super.dispose();
  }

  void _paintCachedImage(PaintingContext context, Offset offset) {
    final ui.Image? image = _cachedImage;
    if (image == null) return;

    final Rect dst = offset & size;

    for (final BlendLayer layer in _layers) {
      _paintObject.colorFilter = null;
      _paintObject.shader = null;
      _paintObject.blendMode = layer.blendMode;

      // Wenn wir eine Maskierungslogik brauchen (Colorize oder Cutout)
      if (layer.type != BlendLayerType.base) {
        // Deine funktionierenden Koordinaten
        final double physX = offset.dx;
        final double physY = offset.dy;
        final double physW = size.width;
        final double physH = size.height;

        _maskingShader.setFloat(0, physX);
        _maskingShader.setFloat(1, physY);
        _maskingShader.setFloat(2, physW);
        _maskingShader.setFloat(3, physH);

        // uKeyColor (RGB)
        _maskingShader.setFloat(4, _keyColor.red / 255.0);
        _maskingShader.setFloat(5, _keyColor.green / 255.0);
        _maskingShader.setFloat(6, _keyColor.blue / 255.0);

        // Initialisierung der Uniforms
        double r = 0, g = 0, b = 0, a = 0;
        double mode = 1.0; // Standard: Cutout

        if (layer.type == BlendLayerType.colorize) {
          final Color c = layer.color ?? Colors.white;
          r = c.red / 255.0;
          g = c.green / 255.0;
          b = c.blue / 255.0;
          a = c.opacity;
          mode = 0.0; // Modus: Colorize
        }

        _maskingShader.setFloat(7, r);
        _maskingShader.setFloat(8, g);
        _maskingShader.setFloat(9, b);
        _maskingShader.setFloat(10, a);
        _maskingShader.setFloat(11, mode); // uMode

        _maskingShader.setImageSampler(0, image);
        _paintObject.shader = _maskingShader;

        context.canvas.drawRect(dst, _paintObject);
      } else {
        // --- BASE MODUS ---
        // Ganz normales Zeichnen des Bildes
        context.canvas.drawImageRect(
            image,
            Rect.fromLTWH(
                0, 0, image.width.toDouble(), image.height.toDouble()),
            dst,
            _paintObject);
      }
    }
  }

  // --- CACHE HANDLING ---

  void _handleStaleCache(PaintingContext context, Offset offset) {
    if (!_isCacheStale) return;
    context.pushOpacity(offset, 0, (PaintingContext ctx, Offset off) {
      ctx.paintChild(child!, off);
    });
    _requestSnapshot();
  }

  void _requestSnapshot() {
    if (!_snapshotScheduled) {
      _snapshotScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _captureSnapshot());
    }
  }

  Future<void> _captureSnapshot() async {
    _snapshotScheduled = false;
    if (child == null || !attached) return;
    final RenderBox? currentChild = child;
    if (currentChild is! RenderRepaintBoundary ||
        !currentChild.hasSize ||
        currentChild.size.isEmpty) {
      _requestSnapshot();
      return;
    }
    try {
      final ui.Image image =
          await currentChild.toImage(pixelRatio: _pixelRatio);
      _cachedImage?.dispose();
      _cachedImage = image;
      _isCacheStale = false;
      markNeedsPaint();
    } catch (e) {}
  }

  void _invalidateCache() {
    if (_cachedImage != null) {
      _isCacheStale = true;
    }
    markNeedsPaint();
  }
}
