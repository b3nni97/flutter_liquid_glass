// liquid_glass.frag — Packed locations; Blur nach uShapeData verschoben (106/107)
#version 320 es

precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// ───────────────────── Packed header (feste Locations) ─────────────────────
layout(location = 0) uniform vec2 uSize;            // (width, height) – von Flutter
layout(location = 1) uniform vec4 uGlassColor;      // r,g,b,a
layout(location = 2) uniform vec4 uOpticalProps;    // RI, CA, thickness, blend
layout(location = 3) uniform vec4 uLightConfig;     // angle, intensity, ambient, saturation
layout(location = 4) uniform vec2 uColorAdjust;     // lightness, numShapes
layout(location = 5) uniform vec2 uLightDirection;  // cos(angle), sin(angle)
layout(location = 6) uniform mat4 uTransform;       // Transform für FragCoord

// ───────────────────── Shapes (16 max; feste Location) ─────────────────────
#define MAX_SHAPES 16
layout(location = 10) uniform float uShapeData[MAX_SHAPES * 6];
// (type, centerX, centerY, sizeW, sizeH, cornerRadius)
// -> Belegt bei 16 Shapes 96 Floats: Locations 10..105

// ───────────────────── Blur-Uniforms (hinter uShapeData) ───────────────────
// Nächste freie Location = 106
layout(location = 106) uniform vec4 uBlurHeader;     // x=u_dir_x, y=u_dir_y, z=u_sample_count, w=u_tile_mode
#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

// Samples starten bei 107 (50 * vec4 → 200 Locations 107..306)
layout(location = 107) uniform vec4 u_samples[50];

// ───────────────────── Textur/Output ───────────────────────────────────────
uniform sampler2D uBackgroundTexture;
layout(location = 0) out vec4 fragColor;

// ───────────────────── Aliases aus gepackten Vektoren ──────────────────────
float uRefractiveIndex     = uOpticalProps.x;
float uChromaticAberration = uOpticalProps.y;
float uThickness           = uOpticalProps.z;
float uBlend               = uOpticalProps.w;

float uLightAngle          = uLightConfig.x;
float uLightIntensity      = uLightConfig.y;
float uAmbientStrength     = uLightConfig.z;
float uSaturation          = uLightConfig.w;

float uLightness           = uColorAdjust.x;
float uNumShapes           = uColorAdjust.y;

// Shared-Funktionen erst NACH den Uniforms einbinden
#include "shared.glsl"

// ============================================================================
// Kleinere Performance-Defines
// ============================================================================
#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

#ifdef NORMAL_MODE
#undef NORMAL_MODE
#endif
#define NORMAL_MODE 0

vec2 fastNormalize2(vec2 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}
vec3 fastNormalize3(vec3 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}

// ============================================================================
// SDFs (optimiert)
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
float getShapeSDF(float type, vec2 p, vec2 center, vec2 size, float r){
  // type: 1 = Squircle(n=2), 2 = Ellipse, 3 = RRect
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
// Szene-SDF mit Index (fast path)
// ============================================================================
float sceneSDF_withIndex_fast(vec2 p, out int outIdx){
  int count = int(uNumShapes + 0.5);
  if (count <= 0) { outIdx = -1; return 1e9; }

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

// ============================================================================
// Normalen – schneller Pfad
// ============================================================================
#ifndef NORMAL_FILTER_PX
#define NORMAL_FILTER_PX 1.0
#endif
#ifndef MID_WARP_POWER
#define MID_WARP_POWER 1.8
#endif
#ifndef SIDE_MASK_POWER
#define SIDE_MASK_POWER 3.0
#endif
#ifndef SIDE_MASK_HARD
#define SIDE_MASK_HARD 0.6
#endif

float sceneSDF(vec2 p){ int dummy; return sceneSDF_withIndex_fast(p, dummy); }

vec3 getNormal(float sd, float thickness, int idx){
  vec2 g  = vec2(dFdx(sd), dFdy(sd));
  vec2 gN = fastNormalize2(g + vec2(LG_EPS));

  float n_cos = smoothstep(-thickness - 32.0, 0.0, sd);
  float n_sin = sqrt(max(1.0 - n_cos * n_cos, 0.0));

  if (idx < 0){
    vec2 xy = gN * n_cos;
    return fastNormalize3(vec3(xy, n_sin));
  }

  float st, cr; vec2 c, sz;
  readShapeAt(idx, st, c, sz, cr);

  float halfH = (st == 2.0)
      ? max(sz.y * 0.5, 1e-4)
      : max(max(sz.y * 0.5, cr), 1e-4);

  float yRel    = clamp(abs(FlutterFragCoord().y - c.y) / halfH, 0.0, 1.0);
  float midMask = pow(1.0 - yRel, MID_WARP_POWER);

  float side     = smoothstep(SIDE_MASK_HARD, 1.0, abs(gN.x));
  float sideMask = pow(side, SIDE_MASK_POWER);

  float boost = 1.0 + (midMask * sideMask);

  vec2 xy = gN * n_cos * boost;
  return fastNormalize3(vec3(xy, n_sin));
}

// #define DEBUG_UNIFORMS 0

void main(){
  vec2 pScreen = FlutterFragCoord().xy + vec2(0.5);
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 screenUV = pScreen * invSize;

#ifdef IMPELLER_TARGET_OPENGLES
  screenUV.y = 1.0 - screenUV.y;
#endif

  vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
  vec2 p = transformedCoord.xy;

#if 0 // DEBUG_UNIFORMS
  if (uSize.x < 1.0 || uSize.y < 1.0) {
    fragColor = vec4(1.0, 1.0, 0.0, 1.0); return;
  }
  if (uNumShapes < 0.5) {
    fragColor = vec4(1.0, 0.0, 1.0, 1.0); return;
  }
  if (u_sample_count < 1.0) {
    fragColor = vec4(0.0, 1.0, 1.0, 1.0); return;
  }
#endif

  int   idx;
  float sd  = sceneSDF_withIndex_fast(p, idx);

  float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);
  if (foregroundAlpha < 0.01){
    fragColor = texScreen(uBackgroundTexture, screenUV);
    return;
  }

  vec3 normal = getNormal(sd, uThickness, idx);

  fragColor = renderLiquidGlass(
      screenUV, p, uSize,
      sd, uThickness,
      uRefractiveIndex, uChromaticAberration,
      uGlassColor, uLightDirection, uLightIntensity, uAmbientStrength,
      uBackgroundTexture, normal, foregroundAlpha,
      /*saturation*/ uSaturation, /*lightness*/ uLightness
  );
}
