import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_renderer/src/liquid_shape.dart';

/// Computed geometry and metadata for a liquid glass shape.
///
/// This class encapsulates the global positioning and transformation data
/// required by the renderer to draw the glass effect correctly over the
/// underlying render object.
@immutable
class ComputedShapeInfo {
  /// Creates an immutable snapshot of a shape's geometry.
  const ComputedShapeInfo({
    required this.renderObject,
    required this.shape,
    required this.glassContainsChild,
    required this.globalBounds,
    required this.transform,
  });

  /// The render object that defines the shape's bounds.
  final RenderObject renderObject;

  /// The configuration of the liquid shape (e.g., corner radius, smoothing).
  final LiquidShape shape;

  /// Whether the glass effect should visually encompass the child widget.
  final bool glassContainsChild;

  /// The axis-aligned bounding box of the shape in global coordinates.
  final Rect globalBounds;

  /// The full transform matrix from the local coordinate system to global.
  final Matrix4 transform;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ComputedShapeInfo &&
        other.renderObject == renderObject &&
        other.shape == shape &&
        other.glassContainsChild == glassContainsChild &&
        other.globalBounds == globalBounds &&
        other.transform == transform;
  }

  @override
  int get hashCode => Object.hash(
        renderObject,
        shape,
        glassContainsChild,
        globalBounds,
        transform,
      );

  @override
  String toString() {
    return 'ComputedShapeInfo(bounds: $globalBounds, shape: $shape)';
  }
}

/// A centralized coordinator that tracks positions and transforms of liquid glass shapes.
///
/// This class acts as a registry for [RenderObject]s that participate in the glass
/// effect. It calculates their global transforms and notifies listeners (typically
/// the glass renderer) when layout changes occur, ensuring the glass effect
/// stays synchronized with the widget tree.
class GlassLink with ChangeNotifier {
  /// Creates a registry for liquid glass shapes.
  GlassLink();

  /// Internal storage for registered shapes and their configuration.
  final Map<RenderObject, _GlassShapeState> _shapes = {};

  /// Returns a list of shapes with their currently computed global geometry.
  ///
  /// This getter calculates the global transform and bounds for every registered
  /// shape that is currently attached and has a size.
  List<ComputedShapeInfo> get computedShapes {
    final List<ComputedShapeInfo> result = <ComputedShapeInfo>[];

    for (final MapEntry<RenderObject, _GlassShapeState> entry
        in _shapes.entries) {
      final RenderObject renderObject = entry.key;
      final _GlassShapeState state = entry.value;

      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        continue;
      }

      try {
        // Calculate the transform from local coordinates to the global root.
        final Matrix4 transform = renderObject.getTransformTo(null);
        final Rect rect = MatrixUtils.transformRect(
          transform,
          Offset.zero & renderObject.size,
        );

        result.add(ComputedShapeInfo(
          renderObject: renderObject,
          shape: state.shape,
          glassContainsChild: state.glassContainsChild,
          globalBounds: rect,
          transform: transform,
        ));
      } catch (exception, stack) {
        // Silently skip shapes that fail transform calculation (e.g. singular transforms).
        // Reporting to FlutterError is avoided here to prevent noise during
        // transient layout states, but logged if debug mode is preferred.
        if (kDebugMode) {
          debugPrint(
              'GlassLink: Failed to compute transform for $renderObject: $exception');
        }
      }
    }

    return result;
  }

  /// Whether any shapes are currently registered.
  bool get hasShapes => _shapes.isNotEmpty;

  /// The total number of registered shapes.
  int get shapeCount => _shapes.length;

  /// Registers a render object to be tracked by this link.
  ///
  /// The [shape] defines the visual properties, and [glassContainsChild]
  /// determines compositing behavior.
  void registerShape(
    RenderObject renderObject,
    LiquidShape shape, {
    required bool glassContainsChild,
  }) {
    _shapes[renderObject] = _GlassShapeState(
      shape: shape,
      glassContainsChild: glassContainsChild,
    );
    _scheduleNotification();
  }

  /// Unregisters a render object, stopping it from contributing to the glass effect.
  void unregisterShape(RenderObject renderObject) {
    if (_shapes.remove(renderObject) != null) {
      _scheduleNotification();
    }
  }

  /// Updates the configuration of an already registered shape.
  ///
  /// Use this when the widget parameters change but the [RenderObject] remains the same.
  void updateShape(
    RenderObject renderObject,
    LiquidShape shape, {
    required bool glassContainsChild,
  }) {
    final _GlassShapeState? state = _shapes[renderObject];
    if (state != null) {
      state.shape = shape;
      state.glassContainsChild = glassContainsChild;
      _scheduleNotification();
    }
  }

  /// Signals that the layout of a specific shape has changed.
  ///
  /// This triggers a recalculation of transforms and notifies listeners.
  void notifyShapeLayoutChanged(RenderObject renderObject) {
    if (_shapes.containsKey(renderObject)) {
      _scheduleNotification();
    }
  }

  @override
  void dispose() {
    _shapes.clear();
    super.dispose();
  }

  /// Safely schedules a notification to listeners.
  ///
  /// If called during the build or layout phase, the notification is deferred
  /// until the end of the frame to prevent 'dirty during build' errors.
  void _scheduleNotification() {
    final SchedulerPhase phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (hasListeners) {
          notifyListeners();
        }
      });
    } else {
      notifyListeners();
    }
  }
}

/// Private mutable state for a registered shape.
///
/// Used internally by [GlassLink] to track updates before computing
/// the final immutable [ComputedShapeInfo].
class _GlassShapeState {
  _GlassShapeState({
    required this.shape,
    required this.glassContainsChild,
  });

  LiquidShape shape;
  bool glassContainsChild;
}
