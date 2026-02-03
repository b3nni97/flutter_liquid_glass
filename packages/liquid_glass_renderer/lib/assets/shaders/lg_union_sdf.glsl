// ======================== lg_union_sdf.glsl (FIXED) =========================
#ifndef LG_UNION_SDF_GLSL
#define LG_UNION_SDF_GLSL 1

#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

// ============================================================================
// SDF Primitives
// ============================================================================

// 1. Standard RRect
float sdfRRect(vec2 p, vec2 b, float r){
  float shortest = min(b.x, b.y);
  r = min(r, shortest);
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// 2. Ellipse
float sdfEllipse(vec2 p, vec2 r){
  vec2 safeR = max(r, vec2(1e-4)); 
  vec2 invR = 1.0 / safeR;
  float k1 = length(p * invR);
  float k2 = length(p * (invR * invR));
  return (k1 * (k1 - 1.0)) / max(k2, 1e-4);
}

// 3. APPLE ORGANIC SQUIRCLE (1:1 Original Logic)
float sdfAppleSquircle(vec2 p, vec2 b, float r, float smoothing) {
    // A. Basis-Form (Gerade)
    float d_straight = sdfRRect(p, b, r);
    
    // Performance-Abkürzung
    if (smoothing < 0.01) return d_straight;

    // B. Organische Form (Global Curved)
    float shortestSide = min(b.x, b.y);
    float safeR = max(r, 0.001); // Original logic: nur max(0.001)
    
    float n_global = 2.0 * (shortestSide / safeR);
    n_global = clamp(n_global, 2.0, 40.0);
    
    vec2 pos = abs(p) / b;
    float d_curved_raw = pow(pow(pos.x, n_global) + pow(pos.y, n_global), 1.0/n_global);
    float d_curved = (d_curved_raw - 1.0) * shortestSide;
    
    // Mischen
    return mix(d_straight, d_curved, smoothing);
}

// ─── Smooth Union ───
float smoothUnion(float d1, float d2, float k){
    float h = clamp(0.5 + 0.5 * (d2 - d1) / max(k, 1e-4), 0.0, 1.0);
    return mix(d2, d1, h) - k * h * (1.0 - h);
}

// ============================================================================
// Scene Logic
// ============================================================================

void readShapeAt(int index, out float type, out vec2 center, out vec2 size, out float cr, out float cs){
  int base = index * 7; 
  type   = uShapeData[base + 0];
  center = vec2(uShapeData[base + 1], uShapeData[base + 2]);
  size   = vec2(uShapeData[base + 3], uShapeData[base + 4]);
  cr     = uShapeData[base + 5];
  cs     = uShapeData[base + 6];
}

float getShapeSDF(float type, vec2 p, vec2 center, vec2 size, float r, float cs){
  vec2 hp = p - center;
  vec2 hb = size * 0.5; 

  // TYPE 1: Squircle (Standard)
  if (type < 1.5) {
      // Wenn dein cornerSmoothing immer > 0 ist, nehmen wir es einfach.
      // WICHTIG: clamp(0.0, 1.0) wieder eingefügt, damit es exakt wie vorher ist!
      return sdfAppleSquircle(hp, hb, r, clamp(cs, 0.0, 1.0));
  }
  
  // TYPE 3: RRect
  if (type > 2.5) {
      return sdfRRect(hp, hb, r);
  }
  
  // TYPE 2: Ellipse
  return sdfEllipse(hp, hb);
}

float sceneSDF_withIndex_fast(vec2 p, out int outIdx){
  int count = int(uNumShapes + 0.5);

  float type, r, cs;
  vec2 c, s;
  
  readShapeAt(0, type, c, s, r, cs);
  float d = getShapeSDF(type, p, c, s, r, cs);

  float minDist = d;
  float unionD = d;
  outIdx = 0;

  for(int i = 1; i < MAX_SHAPES; i++) {
      if (i >= count) break;

      readShapeAt(i, type, c, s, r, cs);
      d = getShapeSDF(type, p, c, s, r, cs);
      
      if (d < minDist) {
          minDist = d;
          outIdx = i;
      }
      unionD = smoothUnion(unionD, d, uBlend);
  }

  return unionD;
}

float sceneSDF(vec2 p){ int dummy; return sceneSDF_withIndex_fast(p, dummy); }

float lg_foreground_alpha(float sd){
  return smoothstep(0.0, 2.0, -sd); 
}

#endif // LG_UNION_SDF_GLSL