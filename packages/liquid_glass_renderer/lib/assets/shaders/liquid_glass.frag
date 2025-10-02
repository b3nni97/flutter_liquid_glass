// liquid_glass.frag — Hybrid (gepackte Host-Uniforms) + deine Blur-Pipeline, mit vec2 uLightDirection
#version 320 es

// Präzision: knappe Defaults für Mobile
precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// ---- Packed header (wie beim Autor) ----
layout(location = 0) uniform vec2 uSize;           // auto von Flutter gesetzt
layout(location = 1) uniform vec4 uGlassColor;     // r,g,b,a
layout(location = 2) uniform vec4 uOpticalProps;   // RI, CA, thickness, blend
layout(location = 3) uniform vec4 uLightConfig;    // angle, intensity, ambient, saturation
layout(location = 4) uniform vec2 uColorAdjust;    // lightness, numShapes
layout(location = 5) uniform vec2 uLightDirection; // cos(angle), sin(angle)

// ---- Shapes (wie beim Autor) ----
#define MAX_SHAPES 16
layout(location = 6) uniform float uShapeData[MAX_SHAPES * 6];
// 6..101 belegt (96 floats)

// ---- Blur-Uniforms NACH den Shapes ----
layout(location = 102) uniform float u_dir_x;
layout(location = 103) uniform float u_dir_y;
layout(location = 104) uniform float u_sample_count;
layout(location = 105) uniform float u_tile_mode;
layout(location = 106) uniform vec4  u_samples[50]; // 106..305 belegt

// Textur/Output
uniform sampler2D uBackgroundTexture;
layout(location = 0) out vec4 fragColor;

// ---- Aliases aus den gepackten Vektoren (backwards compatible names) ----
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

// ============================================================================
// Kleinere Performance-Defines
// ============================================================================

// Etwas konservativeres Default-Margin (wird zusätzlich in shared.glsl adaptiv)
#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

// Erzwinge schnellen Normalenpfad (dFdx/dFdy)
#ifdef NORMAL_MODE
#undef NORMAL_MODE
#endif
#define NORMAL_MODE 0

// Hilfsfunktionen: schnellere Normierung, stabile eps
const float LG_EPS = 1e-8;

vec2 fastNormalize2(vec2 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}

vec3 fastNormalize3(vec3 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}

// ============================================================================
#include "shared.glsl"
// ============================================================================
// SDFs (optimiert)
// ============================================================================

// RRect wie gehabt (ok)
float sdfRRect(in vec2 p, in vec2 b, in float r){
  float shortest = min(b.x, b.y);
  r = min(r, shortest);
  vec2 q = abs(p) - b + r;
  // length(max(q,0)) bleibt: outside-branch, robust
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// (Rect wird aktuell nicht verwendet, belassen wir aber)
float sdfRect(vec2 p, vec2 b){
  vec2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Squircle (n==2) ohne pow()
float sdfSquircle2(vec2 p, vec2 b, float r){
  float shortest = min(b.x, b.y);
  r = min(r, shortest);
  vec2 q = abs(p) - b + r;

  // pow(max(q.x,0.0), 2.0) + pow(max(q.y,0.0), 2.0)
  vec2 qp = max(q, vec2(0.0));
  float s = qp.x * qp.x + qp.y * qp.y;

  return min(max(q.x, q.y), 0.0) + sqrt(s) - r;
}

// Ellipse (ok)
float sdfEllipse(vec2 p, vec2 r){
  r = max(r, 1e-4);
  float k1 = length(p / r);
  float k2 = length(p / (r * r));
  return (k1 * (k1 - 1.0)) / max(k2, 1e-4);
}

float smoothUnion(float d1, float d2, float k){
  if (k <= 0.0) return min(d1, d2);
  float e = max(k - abs(d1 - d2), 0.0);
  return min(d1, d2) - (e * e) * 0.25 / k;
}

// Brancharme Auswahl, ohne pow()
float getShapeSDF(float type, vec2 p, vec2 center, vec2 size, float r){
  // type: 1 = Squircle(n=2), 2 = Ellipse, 3 = RRect
  vec2  hp   = p - center;
  vec2  hb   = size * 0.5;
  float d1   = sdfSquircle2(hp, hb, r);
  float d2   = sdfEllipse (hp, hb);
  float d3   = sdfRRect   (hp, hb, r);
  // Selektiere über step/mix, um Divergenz zu reduzieren
  float s12 = mix(d1, d2, step(1.5, type));         // type >= 2 ? d2 : d1
  float s23 = mix(d2, d3, step(2.5, type));         // type >= 3 ? d3 : d2
  // Wenn type<2 -> nimm d1, wenn 2<=type<3 -> d2, wenn >=3 -> d3
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

// unteres Bound d^2 (gut für frühes Pruning)
float aabbLowerBoundD2(vec2 p, vec2 c, vec2 sz){
  vec2 h  = 0.5 * sz;
  vec2 d  = abs(p - c) - h;
  vec2 dp = max(d, vec2(0.0));
  return dot(dp, dp);
}
float sdShape(float st, vec2 c, vec2 sz, float cr, vec2 p){
  return getShapeSDF(st, p, c, sz, cr);
}

// Schneller SDF + Index
float sceneSDF_withIndex_fast(vec2 p, out int outIdx){
  int count = int(uNumShapes + 0.5);
  if (count <= 0) { outIdx = -1; return 1e9; }

  // adaptives Margin: thickness + kleinerer Puffer (Blend extrinsisch)
  float margin  = uThickness + 16.0 + uBlend + UNION_EXTRA_PX;
  float margin2 = margin * margin;

  float bestD2A = 1e30; int idxA = -1;
  float bestD2B = 1e30; int idxB = -1;

  // Top-2 nach AABB d^2
  for (int i = 0; i < MAX_SHAPES; ++i){
    if (i >= count) break;
    float st, cr; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr);
    float d2 = aabbLowerBoundD2(p, c, sz);
    if (d2 < bestD2A){ bestD2B = bestD2A; idxB = idxA; bestD2A = d2; idxA = i; }
    else if (d2 < bestD2B){ bestD2B = d2; idxB = i; }
  }

  // Wenn wir sicher weit entfernt sind: schneller Rückweg
  if (bestD2A > margin2){
    outIdx = idxA;
    // Abstand ~ sqrt(bestD2A) - margin (nur einmal sqrt)
    return sqrt(bestD2A) - margin;
  }

  float minLB = sqrt(bestD2A);
  float thr   = minLB + margin;
  float thr2  = thr * thr;

  float unionD  = 0.0;
  bool  have    = false;
  float bestMin = 1e30;
  int   minIdx  = -1;

  // Nur Kandidaten innerhalb thr2 (plus Top-2)
  for (int i = 0; i < MAX_SHAPES; ++i){
    if (i >= count) break;
    float st, cr; vec2 c, sz;
    readShapeAt(i, st, c, sz, cr);
    float d2 = aabbLowerBoundD2(p, c, sz);
    if (d2 > thr2 && i != idxA && i != idxB) continue;

    float d = sdShape(st, c, sz, cr, p);
    unionD  = have ? smoothUnion(unionD, d, uBlend) : d;
    have    = true;

    bestMin = min(bestMin, d);
    if (d == bestMin) minIdx = i;
  }

  outIdx = (minIdx >= 0) ? minIdx : idxA;
  return have ? unionD : (minLB - margin);
}

// ============================================================================
// Normalen – schneller Pfad (dFdx/dFdy), mit leichten Approxes
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
  // Derivatives sind billig und stabil
  vec2 g  = vec2(dFdx(sd), dFdy(sd));
  vec2 gN = fastNormalize2(g + vec2(LG_EPS));

  // Ableitung der "Kuppel": n.z aus n_cos ableiten (wie gehabt)
  float n_cos = smoothstep(-thickness - 32.0, 0.0, sd);
  float n_sin = sqrt(max(1.0 - n_cos * n_cos, 0.0));

  // Falls Index ungültig (sollte nach Alpha-Cut kaum vorkommen)
  if (idx < 0){
    vec2 xy = gN * n_cos;
    return fastNormalize3(vec3(xy, n_sin));
  }

  float st, cr; vec2 c, sz;
  readShapeAt(idx, st, c, sz, cr);

  // Halb-Höhe: für Ellipse rein aus sz, sonst r berücksichtigen
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

// Debug umschaltbar
#define DEBUG_UNIFORMS 0

void main(){
  // Precompute UV und kleine Helfer
  vec2 p  = FlutterFragCoord().xy + vec2(0.5);
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0)); // robust
  vec2 screenUV = p * invSize;

#ifdef IMPELLER_TARGET_OPENGLES
  screenUV.y = 1.0 - screenUV.y;
#endif

#if DEBUG_UNIFORMS
  // --- Sanity checks ---
  if (uSize.x < 1.0 || uSize.y < 1.0) {
    fragColor = vec4(1.0, 1.0, 0.0, 1.0); return;
  }
  if (uNumShapes < 0.5) {
    fragColor = vec4(1.0, 0.0, 1.0, 1.0); return;
  }
  if (u_sample_count < 1.0) {
    fragColor = vec4(0.0, 1.0, 1.0, 1.0); return;
  }

  // Visual legend (unverändert, aber mit invSize)
  vec2 uv = screenUV;
  vec3 col = vec3(0.0);

  if (uv.y < 0.5) {
    if (uv.x < 0.5) {
      col = uGlassColor.rgb;
    } else {
      float y = uv.y * 2.0;
      if (y < (1.0/3.0)) {
        float riN = clamp((uRefractiveIndex - 1.0) / 0.5, 0.0, 1.0);
        col = vec3(riN);
      } else if (y < (2.0/3.0)) {
        col = vec3(clamp(uChromaticAberration, 0.0, 1.0));
      } else {
        col = vec3(clamp(uThickness / 64.0, 0.0, 1.0));
      }
    }
  } else {
    float x = uv.x;
    if (x < (1.0/3.0)) {
      col = vec3(0.5 + 0.5 * uLightDirection.x, 0.5 + 0.5 * uLightDirection.y, 0.0);
    } else if (x < (2.0/3.0)) {
      float xr = (x - 1.0/3.0) * 3.0;
      if (xr < (1.0/3.0)) {
        col = vec3(clamp(uLightIntensity, 0.0, 1.0));
      } else if (xr < (2.0/3.0)) {
        col = vec3(clamp(uAmbientStrength, 0.0, 1.0));
      } else {
        col = vec3(clamp(u_sample_count / 50.0, 0.0, 1.0));
      }
    } else {
      col = vec3(
        clamp(uSaturation, 0.0, 1.0),
        clamp(uLightness, 0.0, 1.0),
        0.0
      );
    }
  }

  fragColor = vec4(col, 1.0);
  return;
#else
  // ───────── Glas-Rendering ─────────
  int   idx;
  float sd  = sceneSDF_withIndex_fast(p, idx);

  // Early-out: keine Vordergrundbeteiligung
  float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);
  if (foregroundAlpha < 0.01){
    fragColor = texScreen(uBackgroundTexture, screenUV);
    return;
  }

  // Schnelle Normalen
  vec3 normal = getNormal(sd, uThickness, idx);

  fragColor = renderLiquidGlass(
      screenUV, p, uSize,
      sd, uThickness,
      uRefractiveIndex, uChromaticAberration,
      uGlassColor, uLightDirection, uLightIntensity, uAmbientStrength,
      uBackgroundTexture, normal, foregroundAlpha,
      /*saturation*/ uSaturation, /*lightness*/ uLightness
  );
#endif
}
