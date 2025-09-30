// liquid_glass.frag — V-Pass: exakter Gaussian 1D + volle Glaslogik.

#version 320 es
precision highp float;

#include <flutter/runtime_effect.glsl>

// ============================================================================
// UNIFORMS (bestehende Reihenfolge beibehalten, wo möglich)
// ============================================================================
layout(location = 0)  uniform float uSizeW;
layout(location = 1)  uniform float uSizeH;
vec2 uSize = vec2(uSizeW, uSizeH);

layout(location = 2)  uniform float uChromaticAberration;

layout(location = 3)  uniform float uGlassColorR;
layout(location = 4)  uniform float uGlassColorG;
layout(location = 5)  uniform float uGlassColorB;
layout(location = 6)  uniform float uGlassColorA;
vec4 uGlassColor = vec4(uGlassColorR, uGlassColorG, uGlassColorB, uGlassColorA);

layout(location = 7)  uniform float uLightAngle;
layout(location = 8)  uniform float uLightIntensity;
layout(location = 9)  uniform float uAmbientStrength;
layout(location = 10) uniform float uThickness;
layout(location = 11) uniform float uRefractiveIndex;
layout(location = 12) uniform float uBlend;
layout(location = 13) uniform float uNumShapes;
layout(location = 14) uniform float uSaturation;
layout(location = 15) uniform float uLightness;

// (16/17 bleiben erhalten für ABI-Kompatibilität – werden nicht verwendet)
layout(location = 16) uniform float uBlurSigmaPx_IGNORED;
layout(location = 17) uniform float uKawaseSteps_IGNORED;

// ── Impeller-Blur Uniforms (EXAKT wie gaussian_1d_blur.frag) ───────────────
layout(location = 18) uniform float u_size_x;
layout(location = 19) uniform float u_size_y;
layout(location = 20) uniform float u_dir_x;
layout(location = 21) uniform float u_dir_y;
layout(location = 22) uniform float u_sample_count;
layout(location = 23) uniform float u_tile_mode;
layout(location = 24) uniform vec4  u_samples[50]; // belegt Slots 24..223

// Shapes-Array hinter die Samples verschoben (Ab Slot 224)
#define MAX_SHAPES 64
layout(location = 224) uniform float uShapeData[MAX_SHAPES * 6];

// Textur/Output
uniform sampler2D uBackgroundTexture;
layout(location = 0) out vec4 fragColor;

// ============================================================================
// Jetzt include — shared.glsl nutzt oben deklarierte Uniforms
// ============================================================================
#include "shared.glsl"

// ============================================================================
// SDFs
// ============================================================================
float sdfRRect( in vec2 p, in vec2 b, in float r ) {
    float shortest = min(b.x, b.y);
    r = min(r, shortest);
    vec2 q = abs(p)-b+r;
    return min(max(q.x,q.y),0.0) + length(max(q,0.0)) - r;
}
float sdfRect(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
float sdfSquircle(vec2 p, vec2 b, float r, float n) {
    float shortest = min(b.x, b.y);
    r = min(r, shortest);
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + pow(
        pow(max(q.x, 0.0), n) + pow(max(q.y, 0.0), n),
        1.0 / n
    ) - r;
}
float sdfEllipse(vec2 p, vec2 r) {
    r = max(r, 1e-4);
    float k1 = length(p / r);
    float k2 = length(p / (r * r));
    return (k1 * (k1 - 1.0)) / max(k2, 1e-4);
}
float smoothUnion(float d1, float d2, float k) {
    if (k <= 0.0) return min(d1, d2);
    float e = max(k - abs(d1 - d2), 0.0);
    return min(d1, d2) - e * e * 0.25 / k;
}

float getShapeSDF(float type, vec2 p, vec2 center, vec2 size, float r) {
    if (type == 1.0) return sdfSquircle(p - center, size / 2.0, r, 2.0);
    if (type == 2.0) return sdfEllipse (p - center, size / 2.0);
    if (type == 3.0) return sdfRRect   (p - center, size / 2.0, r);
    return 1e9;
}
float getShapeSDFFromArray(int index, vec2 p) {
    int baseIndex = index * 6;
    float type = uShapeData[baseIndex + 0];
    vec2  center = vec2(uShapeData[baseIndex + 1], uShapeData[baseIndex + 2]);
    vec2  size   = vec2(uShapeData[baseIndex + 3], uShapeData[baseIndex + 4]);
    float cr     = uShapeData[baseIndex + 5];
    return getShapeSDF(type, p, center, size, cr);
}
float sceneSDF(vec2 p) {
    int n = int(uNumShapes + 0.5);
    if (n <= 0) return 1e9;
    float d = getShapeSDFFromArray(0, p);
    for (int i = 1; i < n; ++i)
        d = smoothUnion(d, getShapeSDFFromArray(i, p), uBlend);
    return d;
}

#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif
void readShapeAt(int index, out float type, out vec2 center, out vec2 size, out float cr) {
    int base = index * 6;
    type   = uShapeData[base + 0];
    center = vec2(uShapeData[base + 1], uShapeData[base + 2]);
    size   = vec2(uShapeData[base + 3], uShapeData[base + 4]);
    cr     = uShapeData[base + 5];
}
float aabbLowerBoundD2(vec2 p, vec2 c, vec2 sz) {
  vec2 h  = 0.5 * sz;
  vec2 d  = abs(p - c) - h;
  vec2 dp = max(d, vec2(0.0));
  return dot(dp, dp);
}
float sdShape(float st, vec2 c, vec2 sz, float cr, vec2 p) {
  return getShapeSDF(st, p, c, sz, cr);
}
float sceneSDF_withIndex_fast(vec2 p, out int outIdx) {
  int count = int(uNumShapes + 0.5);
  if (count <= 0) { outIdx = -1; return 1e9; }

  float margin  = uThickness + 32.0 + uBlend + UNION_EXTRA_PX;
  float margin2 = margin * margin;

  float bestD2A = 1e30; int idxA = -1;
  float bestD2B = 1e30; int idxB = -1;

  for (int i = 0; i < MAX_SHAPES; ++i) {
    if (i >= count) break;
    float st, cr; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr);
    float d2 = aabbLowerBoundD2(p, c, sz);
    if (d2 < bestD2A) { bestD2B = bestD2A; idxB = idxA; bestD2A = d2; idxA = i; }
    else if (d2 < bestD2B) { bestD2B = d2; idxB = i; }
  }

  float minLB = sqrt(bestD2A);
  if (bestD2A > margin2) { outIdx = idxA; return minLB - margin; }

  float thr  = minLB + margin;
  float thr2 = thr * thr;

  float unionD  = 0.0;
  bool  have    = false;
  float bestMin = 1e30;
  int   minIdx  = -1;

  for (int i = 0; i < MAX_SHAPES; ++i) {
    if (i >= count) break;

    float st, cr; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr);
    float d2 = aabbLowerBoundD2(p, c, sz);
    if (d2 > thr2 && i != idxA && i != idxB) continue;

    float d = sdShape(st, c, sz, cr, p);
    if (!have) { unionD = d; have = true; } else { unionD = smoothUnion(unionD, d, uBlend); }

    if (d < bestMin) { bestMin = d; minIdx = i; }
  }

  outIdx = (minIdx >= 0) ? minIdx : idxA;
  return have ? unionD : (minLB - margin);
}

// ============================================================================
// Normalen
// ============================================================================
#ifndef NORMAL_MODE
#define NORMAL_MODE 0 // 0=dFdx/dFdy, 1=zentral, 2=Sobel
#endif
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

vec2 gradCentralScene(vec2 p, float h) {
    float sx1 = sceneSDF(p + vec2( h, 0.0));
    float sx0 = sceneSDF(p + vec2(-h, 0.0));
    float sy1 = sceneSDF(p + vec2(0.0,  h));
    float sy0 = sceneSDF(p + vec2(0.0, -h));
    return 0.5 * vec2(sx1 - sx0, sy1 - sy0);
}
vec2 gradSobelScene(vec2 p, float h) {
    float s00 = sceneSDF(p + h*vec2(-1,-1));
    float s01 = sceneSDF(p + h*vec2( 0,-1));
    float s02 = sceneSDF(p + h*vec2( 1,-1));
    float s10 = sceneSDF(p + h*vec2(-1, 0));
    float s12 = sceneSDF(p + h*vec2( 1, 0));
    float s20 = sceneSDF(p + h*vec2(-1, 1));
    float s21 = sceneSDF(p + h*vec2( 0, 1));
    float s22 = sceneSDF(p + h*vec2( 1, 1));
    float gx=(s02+2.0*s12+s22)-(s00+2.0*s10+s20);
    float gy=(s20+2.0*s21+s22)-(s00+2.0*s01+s02);
    return vec2(gx,gy);
}

vec3 getNormal(float sd, float thickness, int idx) {
    vec2 p = FlutterFragCoord().xy;

    vec2 g;
#if NORMAL_MODE == 0
    g = vec2(dFdx(sd), dFdy(sd));
#elif NORMAL_MODE == 1
    g = gradCentralScene(p, NORMAL_FILTER_PX);
#else
    g = gradSobelScene(p, NORMAL_FILTER_PX);
#endif
    vec2 gN = normalize(g + 1e-8);

    float n_cos = smoothstep(-thickness - 32.0, 0.0, sd);
    float n_sin = sqrt(max(1.0 - n_cos*n_cos, 0.0));

    float st, cr; vec2 c, sz;
    readShapeAt(idx, st, c, sz, cr);

    float halfH = (st == 2.0) ? max(sz.y * 0.5, 1e-4)
                              : max(max(sz.y * 0.5, cr), 1e-4);

    float yRel    = clamp(abs(p.y - c.y) / halfH, 0.0, 1.0);
    float midMask = pow(1.0 - yRel, MID_WARP_POWER);

    float side     = smoothstep(SIDE_MASK_HARD, 1.0, abs(gN.x));
    float sideMask = pow(side, SIDE_MASK_POWER);

    float boost = 1.0 + 1.00 * (midMask * sideMask);

    vec2 xy = gN * n_cos * boost;
    return normalize(vec3(xy, n_sin));
}

// ============================================================================
// MAIN
// ============================================================================
void main() {
  // Pixelcenter + GLES-Flip wie im Referenzshader
  vec2 p  = FlutterFragCoord().xy + vec2(0.5);
  vec2 screenUV = p / vec2(u_size_x, u_size_y);
#ifdef IMPELLER_TARGET_OPENGLES
  screenUV.y = 1.0 - screenUV.y;
#endif

  // Szene
  int   idx;
  float sd  = sceneSDF_withIndex_fast(p, idx);
  float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);
  if (foregroundAlpha < 0.01) {
    fragColor = texScreen(uBackgroundTexture, screenUV);
    return;
  }

  vec3  normal = getNormal(sd, uThickness, idx);

  // API-kompatibler Call: Blur-Parameter werden ignoriert (Impeller-Uniforms)
  fragColor = renderLiquidGlass(
      screenUV, p, vec2(u_size_x, u_size_y),
      sd, uThickness,
      uRefractiveIndex, uChromaticAberration,
      uGlassColor, uLightAngle, uLightIntensity, uAmbientStrength,
      uBackgroundTexture, normal, foregroundAlpha,
      /*gaussianBlurSigmaPx*/ 0.0, /*kawaseSteps*/ 0.0,
      uSaturation, uLightness
  );
}
