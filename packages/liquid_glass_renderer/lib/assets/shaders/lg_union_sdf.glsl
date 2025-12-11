// ======================== lg_union_sdf.glsl (FINAL SINGLE FLOAT) ============
// Enthält SDFs, Smooth-Union und die schnelle Szenen-Abfrage inkl. Index.
//
// WICHTIG: Daten-Layout ist MAX_SHAPES * 7.
// Layout: (type, cx, cy, w, h, radius, cornerSmoothing)
//
// Types:
// 1 = Squircle
//     -> cornerSmoothing < 0: Fallback to Legacy Auto-Logic
//     -> cornerSmoothing >= 0: Apple Organic Squircle (0.0 = Straight, 1.0 = Max Organic)
// 2 = Ellipse
// 3 = RRect (Explicit Standard)
//
// - #define MAX_SHAPES 16
// - uniform float uShapeData[MAX_SHAPES * 7];
// ...

#ifndef LG_UNION_SDF_GLSL
#define LG_UNION_SDF_GLSL 1

#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

// ============================================================================
// SDF Functions
// ============================================================================

// 1. Helper für Legacy Auto-Logic
float getFlutterN(float halfSide, float radius) {
  float ratio = (halfSide * 2.0) / max(radius, 0.001);
  float r_clamped = clamp(ratio, 2.0, 5.0);
  float n = 2.0;
  if (r_clamped < 3.0) n = mix(2.00, 3.36, r_clamped - 2.0);
  else if (r_clamped < 4.0) n = mix(3.36, 4.85, r_clamped - 3.0);
  else n = mix(4.85, 6.43, r_clamped - 4.0);
  if (ratio > 5.0) n = 6.43 + (ratio - 5.0) * 1.56;
  return n;
}

// 2. Standard Rounded Rect (Gerade Seiten)
float sdfRRect(in vec2 p, in vec2 b, in float r){
  float shortest = min(b.x, b.y);
  r = min(r, shortest);
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// 3. Legacy Squircle (Auto-N via Flutter Logic)
float sdfSquircle2(vec2 p, vec2 b, float r){
  float shortestHalf = min(b.x, b.y);
  r = min(r, shortestHalf);
  float n = getFlutterN(shortestHalf, r);
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + pow(
      pow(max(q.x, 0.0), n) + pow(max(q.y, 0.0), n),
      1.0 / n
  ) - r;
}

// 4. APPLE ORGANIC SQUIRCLE (Figma Style)
// smoothing: 0.0 (Gerade) bis 1.0 (Apple Bauch).
float sdfAppleSquircle(vec2 p, vec2 b, float r, float smoothing) {
    // A. Basis-Form (Gerade)
    float d_straight = sdfRRect(p, b, r);
    
    // Performance-Abkürzung
    if (smoothing < 0.01) return d_straight;

    // B. Organische Form (Global Curved)
    // Heuristik für den perfekten Exponenten N basierend auf Größe/Radius
    float shortestSide = min(b.x, b.y);
    float safeR = max(r, 0.001);
    
    float n_global = 2.0 * (shortestSide / safeR);
    n_global = clamp(n_global, 2.0, 40.0);
    
    vec2 pos = abs(p) / b;
    float d_curved_raw = pow(pow(pos.x, n_global) + pow(pos.y, n_global), 1.0/n_global);
    float d_curved = (d_curved_raw - 1.0) * shortestSide;
    
    // Mischen
    return mix(d_straight, d_curved, smoothing);
}

// 5. Ellipse
float sdfEllipse(vec2 p, vec2 r){
  r = max(r, 1e-4);
  vec2 invR  = 1.0 / r;
  vec2 invR2 = invR * invR;
  float k1   = length(p * invR);
  float k2   = length(p * invR2);
  return (k1 * (k1 - 1.0)) / max(k2, 1e-4);
}

float smoothUnion(float d1, float d2, float k){
  if (k <= 0.0) return min(d1, d2);
  float e = max(k - abs(d1 - d2), 0.0);
  return min(d1, d2) - (e * e) * 0.25 / k;
}

// ============================================================================
// Shape Management
// ============================================================================

// WICHTIG: cornerSmoothing ist jetzt ein einfacher float
float getShapeSDF(float type, vec2 p, vec2 center, vec2 size, float r, float cornerSmoothing){
  vec2 hp = p - center;
  vec2 hb = size * 0.5; 

  // --- TYPE 1: SQUIRCLE ---
  if (type < 1.5) {
      // < 0.0 -> Auto Legacy Mode (Default)
      if (cornerSmoothing < 0.0) {
          return sdfSquircle2(hp, hb, r);
      } 
      
      // >= 0.0 -> Apple Hybrid Mode
      return sdfAppleSquircle(hp, hb, r, clamp(cornerSmoothing, 0.0, 1.0));
  }
  
  // --- TYPE 2: ELLIPSE ---
  if (type < 2.5) {
      return sdfEllipse(hp, hb);
  }
  
  // --- TYPE 3: RRECT ---
  return sdfRRect(hp, hb, r);
}

// WICHTIG: Stride 7 Floats
void readShapeAt(int index, out float type, out vec2 center, out vec2 size, out float cr, out float cornerSmoothing){
  int base = index * 7; 
  type            = uShapeData[base + 0];
  center          = vec2(uShapeData[base + 1], uShapeData[base + 2]);
  size            = vec2(uShapeData[base + 3], uShapeData[base + 4]);
  cr              = uShapeData[base + 5];
  cornerSmoothing = uShapeData[base + 6]; // Der 7. Wert
}

float aabbLowerBoundD2(vec2 p, vec2 c, vec2 sz){
  vec2 h  = 0.5 * sz;
  vec2 d  = abs(p - c) - h;
  vec2 dp = max(d, vec2(0.0));
  return dot(dp, dp);
}

float sdShape(float st, vec2 c, vec2 sz, float cr, float cornerSmoothing, vec2 p){
  return getShapeSDF(st, p, c, sz, cr, cornerSmoothing);
}

// ============================================================================
// Scene SDF with index (fast path)
// ============================================================================
float sceneSDF_withIndex_fast(vec2 p, out int outIdx){
  int count = int(uNumShapes + 0.5);
  if (count <= 0) { outIdx = -1; return 1e9; }

  // Unroll Loop
  if (count <= 4) {
    float st0, cr0, cs0; vec2 c0, sz0;
    readShapeAt(0, st0, c0, sz0, cr0, cs0);
    float d0 = sdShape(st0, c0, sz0, cr0, cs0, p);
    float unionD = d0;
    float bestMin = d0;
    int   minIdx  = 0;

    if (count >= 2){
      float st1, cr1, cs1; vec2 c1, sz1;
      readShapeAt(1, st1, c1, sz1, cr1, cs1);
      float d1 = sdShape(st1, c1, sz1, cr1, cs1, p);
      unionD = smoothUnion(unionD, d1, uBlend);
      if (d1 < bestMin) { bestMin = d1; minIdx = 1; }
    }
    if (count >= 3){
      float st2, cr2, cs2; vec2 c2, sz2;
      readShapeAt(2, st2, c2, sz2, cr2, cs2);
      float d2 = sdShape(st2, c2, sz2, cr2, cs2, p);
      unionD = smoothUnion(unionD, d2, uBlend);
      if (d2 < bestMin) { bestMin = d2; minIdx = 2; }
    }
    if (count >= 4){
      float st3, cr3, cs3; vec2 c3, sz3;
      readShapeAt(3, st3, c3, sz3, cr3, cs3);
      float d3 = sdShape(st3, c3, sz3, cr3, cs3, p);
      unionD = smoothUnion(unionD, d3, uBlend);
      if (d3 < bestMin) { bestMin = d3; minIdx = 3; }
    }
    outIdx = minIdx;
    return unionD;
  }

  // Broad phase loop
  float margin  = uThickness + 16.0 + uBlend + UNION_EXTRA_PX;
  float margin2 = margin * margin;

  float bestD2A = 1e30; int idxA = -1;
  float bestD2B = 1e30; int idxB = -1;

  for (int i = 0; i < MAX_SHAPES; ++i){
    if (i >= count) break;
    float st, cr, dummyCS; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr, dummyCS);
    float d2 = aabbLowerBoundD2(p, c, sz);
    if (d2 < bestD2A){ bestD2B = bestD2A; idxB = idxA; bestD2A = d2; idxA = i; }
    else if (d2 < bestD2B){ bestD2B = d2; idxB = i; }
  }

  if (bestD2A > margin2){
    outIdx = idxA;
    return sqrt(bestD2A) - margin;
  }

  float minLB = sqrt(bestD2A);
  float thr   = minLB + margin;
  float thr2  = thr * thr;

  float unionD  = 0.0;
  bool  have    = false;
  float bestMin = 1e30;
  int   minIdx  = -1;

  for (int i = 0; i < MAX_SHAPES; ++i){
    if (i >= count) break;
    float st, cr, cs; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr, cs);
    float d2 = aabbLowerBoundD2(p, c, sz);
    if (d2 > thr2 && i != idxA && i != idxB) continue;

    float d = sdShape(st, c, sz, cr, cs, p);
    unionD  = have ? smoothUnion(unionD, d, uBlend) : d;
    have    = true;

    if (d < bestMin) { bestMin = d; minIdx = i; }
  }

  outIdx = (minIdx >= 0) ? minIdx : idxA;
  return have ? unionD : (minLB - margin);
}

float sceneSDF(vec2 p){ int dummy; return sceneSDF_withIndex_fast(p, dummy); }

float lg_foreground_alpha(float sd){
  return 1.0 - smoothstep(-2.0, 0.0, sd);
}

#endif // LG_UNION_SDF_GLSL