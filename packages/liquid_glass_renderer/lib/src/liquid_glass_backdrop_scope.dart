import 'package:flutter/rendering.dart' show BackdropKey;
import 'package:flutter/widgets.dart';

/// Shares a single [BackdropKey] with all descendant liquid glass layers, so the
/// engine captures the backdrop **once** and reuses it for every glass element.
///
/// When several [LiquidGlassLayer]s (directly, or via standalone [LiquidGlass]
/// widgets) sit below the same scope, they all push their [BackdropFilterLayer]
/// with the **same** [backdropKey]. The Flutter engine then snapshots the
/// backdrop a single time and feeds that shared input to each filter, collapsing
/// N backdrop captures into one — a meaningful performance win when a page has
/// many glass surfaces over the same content.
///
/// ### This is a performance optimization only
///
/// It does **NOT** fix the "glass inside an isolating save layer (e.g. [Opacity]
/// / `FadeTransition`) loses its backdrop" problem. Even with a capture anchor that
/// demonstrably reads the real backdrop above the [Opacity], a glass filter
/// *inside* the save layer keeps reading its empty offscreen and renders without
/// refraction. The shared-key mechanism only deduplicates captures between
/// sibling filters at the same nesting level; it cannot propagate a backdrop into
/// an isolated subpass. For the isolation case use `LiquidGlassOpacity` (avoids
/// the save layer) instead.
///
/// ### Where to put it
///
/// Place one scope **per page/route**, not at the app root: the captured backdrop
/// is page-specific, and sharing a key across routes can bleed the wrong content
/// during transitions. The capture point is the first keyed filter in paint
/// order, so the scope must sit above the glass but below (after) the page
/// content the glass should refract.
///
/// ### Opting out
///
/// Overlapping / stacked glass should **not** share a key — with a shared input
/// they can't refract each other, so only one effect shows through the overlap.
/// Opt such elements out per-element via `LiquidGlassLayer(shareBackdrop: false)`
/// (or `LiquidGlass(shareBackdrop: false)`); they then capture their own local
/// backdrop again.
class LiquidGlassBackdropScope extends InheritedWidget {
  /// Creates a scope that shares a [backdropKey] with descendant glass layers.
  ///
  /// If [backdropKey] is omitted, a fresh one is created for this scope.
  LiquidGlassBackdropScope({
    super.key,
    BackdropKey? backdropKey,
    required super.child,
  }) : backdropKey = backdropKey ?? BackdropKey();

  /// The key shared by all descendant glass layers that opt into sharing.
  final BackdropKey backdropKey;

  /// Returns the [backdropKey] of the nearest scope, or `null` if there is none.
  static BackdropKey? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<LiquidGlassBackdropScope>()
        ?.backdropKey;
  }

  @override
  bool updateShouldNotify(LiquidGlassBackdropScope oldWidget) {
    return backdropKey != oldWidget.backdropKey;
  }
}
