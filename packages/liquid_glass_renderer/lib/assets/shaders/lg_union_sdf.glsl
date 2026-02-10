#ifndef LG_UNION_SDF_GLSL
#define LG_UNION_SDF_GLSL 1

#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

// Calculates the signed distance field for a rounded rectangle.
// Returns the distance from point p to the shape defined by half-size b and radius r.
float calculateRoundedRectSDF(vec2 position, vec2 halfSize, float radius) {
  float limit = min(halfSize.x, halfSize.y);
  float effectiveRadius = min(radius, limit);
  vec2 q = abs(position) - halfSize + effectiveRadius;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - effectiveRadius;
}

// Calculates an algebraic distance approximation for an ellipse.
// Returns a value related to the distance from point p to the ellipse with radii r.
float calculateEllipseSDF(vec2 position, vec2 radii) {
  vec2 safeRadii = max(radii, vec2(1e-4));
  vec2 inverseRadii = 1.0 / safeRadii;
  float k1 = length(position * inverseRadii);
  float k2 = length(position * (inverseRadii * inverseRadii));
  return (k1 * (k1 - 1.0)) / max(k2, 1e-4);
}

// Calculates the signed distance field for an "Apple-style" squircle.
// Interpolates between a rounded rectangle and a superellipse based on smoothing.
float calculateSquircleSDF(vec2 position, vec2 halfSize, float radius, float smoothing) {
  float straightDistance = calculateRoundedRectSDF(position, halfSize, radius);

  if (smoothing < 0.01) {
    return straightDistance;
  }

  float shortestSide = min(halfSize.x, halfSize.y);
  float safeRadius = max(radius, 0.001);

  float nGlobal = 2.0 * (shortestSide / safeRadius);
  nGlobal = clamp(nGlobal, 2.0, 40.0);

  vec2 normalizedPos = abs(position) / halfSize;
  float rawCurvedDistance = pow(pow(normalizedPos.x, nGlobal) + pow(normalizedPos.y, nGlobal), 1.0 / nGlobal);
  float curvedDistance = (rawCurvedDistance - 1.0) * shortestSide;

  return mix(straightDistance, curvedDistance, smoothing);
}

// Combines two signed distance fields smoothly.
// Uses a polynomial mix controlled by factor k.
float smoothUnion(float distanceA, float distanceB, float k) {
  float h = clamp(0.5 + 0.5 * (distanceB - distanceA) / max(k, 1e-4), 0.0, 1.0);
  return mix(distanceB, distanceA, h) - k * h * (1.0 - h);
}

// Unpacks shape data from the global array for a specific index.
// Populates the output parameters with shape properties.
void unpackShapeData(int index, out float type, out vec2 center, out vec2 size, out float radius, out float smoothing) {
  int baseIndex = index * 7;
  type = uShapeData[baseIndex + 0];
  center = vec2(uShapeData[baseIndex + 1], uShapeData[baseIndex + 2]);
  size = vec2(uShapeData[baseIndex + 3], uShapeData[baseIndex + 4]);
  radius = uShapeData[baseIndex + 5];
  smoothing = uShapeData[baseIndex + 6];
}

// Computes the SDF for a specific shape type.
// Dispatches the calculation to the appropriate primitive function.
float calculateShapeSDF(float type, vec2 position, vec2 center, vec2 size, float radius, float smoothing) {
  vec2 localPosition = position - center;
  vec2 halfSize = size * 0.5;

  // Type 1: Squircle.
  if (type < 1.5) {
    return calculateSquircleSDF(localPosition, halfSize, radius, clamp(smoothing, 0.0, 1.0));
  }

  // Type 3: Rounded Rectangle.
  if (type > 2.5) {
    return calculateRoundedRectSDF(localPosition, halfSize, radius);
  }

  // Type 2: Ellipse.
  return calculateEllipseSDF(localPosition, halfSize);
}

// Calculates the combined SDF for the entire scene.
// Returns the union distance and outputs the index of the closest shape.
float sceneSDF_withIndex_fast(vec2 position, out int closestShapeIndex) {
  int shapeCount = int(uNumShapes + 0.5);

  float type, radius, smoothing;
  vec2 center, size;

  unpackShapeData(0, type, center, size, radius, smoothing);
  float currentDistance = calculateShapeSDF(type, position, center, size, radius, smoothing);

  float minDistance = currentDistance;
  float unionDistance = currentDistance;
  closestShapeIndex = 0;

  for (int i = 1; i < MAX_SHAPES; i++) {
    if (i >= shapeCount) {
      break;
    }

    unpackShapeData(i, type, center, size, radius, smoothing);
    currentDistance = calculateShapeSDF(type, position, center, size, radius, smoothing);

    if (currentDistance < minDistance) {
      minDistance = currentDistance;
      closestShapeIndex = i;
    }
    unionDistance = smoothUnion(unionDistance, currentDistance, uBlend);
  }

  return unionDistance;
}

// Wrapper for sceneSDF without index tracking.
// Useful for general SDF queries where the shape index is not required.
float sceneSDF(vec2 position) {
  int dummyIndex;
  return sceneSDF_withIndex_fast(position, dummyIndex);
}

// Calculates the alpha value for the foreground based on the signed distance.
// Uses smoothstep to create an anti-aliased edge.
float lg_foreground_alpha(float signedDistance) {
  return smoothstep(0.0, 2.0, -signedDistance);
}

#endif // LG_UNION_SDF_GLSL