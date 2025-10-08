// ======================== lg_union_sdf.glsl (LIBRARY ONLY) ==================
// Enthält SDFs, Smooth-Union und die schnelle Szenen-Abfrage inkl. Index.
// Diese Datei greift auf folgende Symbole zu, die im Host-Shader definiert
// sein müssen:
//
// - #define MAX_SHAPES 16
// - uniform float uShapeData[MAX_SHAPES * 6];
//   Layout pro Shape: (type, centerX, centerY, sizeW, sizeH, cornerRadius)
// - float uBlend;        // Smooth-Union-Koeffizient (px)
// - float uThickness;    // Effektive Dicke (px) — nur für Broad-Phase-Margin
// - float uNumShapes;    // Anzahl Shapes (als float)
//
// Optional (kann vom Host vordefiniert werden):
// - #define UNION_EXTRA_PX 2.0
//
// Diese Library deklariert KEINE Uniforms/Layouts selbst, um Doppel-Decls zu
// vermeiden. Sie kann sowohl im Liquid-Glass-Mainpass als auch in deinem
// H-Blur-Pass wiederverwendet werden.

#ifndef LG_UNION_SDF_GLSL
#define LG_UNION_SDF_GLSL 1

#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

// ============================================================================
// Optimized SDFs
// ============================================================================
float sdfRRect(in vec2 p, in vec2 b, in float r){
  float shortest = min(b.x, b.y);
  r = min(r, shortest);
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}
float sdfRect(vec2 p, vec2 b){
  vec2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
float sdfSquircle2(vec2 p, vec2 b, float r){
  float shortest = min(b.x, b.y);
  r = min(r, shortest);
  vec2 q = abs(p) - b + r;
  vec2 qp = max(q, vec2(0.0));
  float s = qp.x * qp.x + qp.y * qp.y;
  return min(max(q.x, q.y), 0.0) + sqrt(s) - r;
}
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

// type: 1=Squircle(n=2), 2=Ellipse, 3=RRect
float getShapeSDF(float type, vec2 p, vec2 center, vec2 size, float r){
  vec2  hp   = p - center;
  vec2  hb   = size * 0.5;
  float d1   = sdfSquircle2(hp, hb, r);
  float d2   = sdfEllipse (hp, hb);
  float d3   = sdfRRect   (hp, hb, r);
  float s12 = mix(d1, d2, step(1.5, type));
  float s23 = mix(d2, d3, step(2.5, type));
  float sA  = mix(d1, s12, step(1.0, type));
  float sB  = mix(d2, s23, step(2.0, type));
  return mix(sA, sB, step(2.0, type));
}

void readShapeAt(int index, out float type, out vec2 center, out vec2 size, out float cr){
  int base = index * 6;
  type   = uShapeData[base + 0];
  center = vec2(uShapeData[base + 1], uShapeData[base + 2]);
  size   = vec2(uShapeData[base + 3], uShapeData[base + 4]);
  cr     = uShapeData[base + 5];
}

float aabbLowerBoundD2(vec2 p, vec2 c, vec2 sz){
  vec2 h  = 0.5 * sz;
  vec2 d  = abs(p - c) - h;
  vec2 dp = max(d, vec2(0.0));
  return dot(dp, dp);
}

float sdShape(float st, vec2 c, vec2 sz, float cr, vec2 p){
  return getShapeSDF(st, p, c, sz, cr);
}

// ============================================================================
// Scene SDF with index (fast path)
// ============================================================================
float sceneSDF_withIndex_fast(vec2 p, out int outIdx){
  int count = int(uNumShapes + 0.5);
  if (count <= 0) { outIdx = -1; return 1e9; }

  // Unroll up to four shapes for better performance on small scenes.
  if (count <= 4) {
    float st0, cr0; vec2 c0, sz0;
    readShapeAt(0, st0, c0, sz0, cr0);
    float d0 = sdShape(st0, c0, sz0, cr0, p);
    float unionD = d0;
    float bestMin = d0;
    int   minIdx  = 0;

    if (count >= 2){
      float st1, cr1; vec2 c1, sz1; readShapeAt(1, st1, c1, sz1, cr1);
      float d1 = sdShape(st1, c1, sz1, cr1, p);
      unionD = smoothUnion(unionD, d1, uBlend);
      if (d1 < bestMin) { bestMin = d1; minIdx = 1; }
    }
    if (count >= 3){
      float st2, cr2; vec2 c2, sz2; readShapeAt(2, st2, c2, sz2, cr2);
      float d2 = sdShape(st2, c2, sz2, cr2, p);
      unionD = smoothUnion(unionD, d2, uBlend);
      if (d2 < bestMin) { bestMin = d2; minIdx = 2; }
    }
    if (count >= 4){
      float st3, cr3; vec2 c3, sz3; readShapeAt(3, st3, c3, sz3, cr3);
      float d3 = sdShape(st3, c3, sz3, cr3, p);
      unionD = smoothUnion(unionD, d3, uBlend);
      if (d3 < bestMin) { bestMin = d3; minIdx = 3; }
    }
    outIdx = minIdx;
    return unionD;
  }

  // Broad phase pruning using AABB distance lower bounds.
  float margin  = uThickness + 16.0 + uBlend + UNION_EXTRA_PX;
  float margin2 = margin * margin;

  float bestD2A = 1e30; int idxA = -1;
  float bestD2B = 1e30; int idxB = -1;

  for (int i = 0; i < MAX_SHAPES; ++i){
    if (i >= count) break;
    float st, cr; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr);
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
    float st, cr; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr);
    float d2 = aabbLowerBoundD2(p, c, sz);
    if (d2 > thr2 && i != idxA && i != idxB) continue;

    float d = sdShape(st, c, sz, cr, p);
    unionD  = have ? smoothUnion(unionD, d, uBlend) : d;
    have    = true;

    if (d < bestMin) { bestMin = d; minIdx = i; }
  }

  outIdx = (minIdx >= 0) ? minIdx : idxA;
  return have ? unionD : (minLB - margin);
}

// Bequemer Wrapper ohne Index.
float sceneSDF(vec2 p){ int dummy; return sceneSDF_withIndex_fast(p, dummy); }

// Standardisierte Foreground-Maske (wie im Main-Shader genutzt).
float lg_foreground_alpha(float sd){
  return 1.0 - smoothstep(-2.0, 0.0, sd);
}

#endif // LG_UNION_SDF_GLSL
