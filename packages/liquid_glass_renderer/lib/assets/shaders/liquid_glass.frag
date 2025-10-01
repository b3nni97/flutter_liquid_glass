// liquid_glass.frag — Hybrid (gepackte Host-Uniforms) + deine Blur-Pipeline, mit vec2 uLightDirection

#version 320 es
precision mediump float;

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
#include "shared.glsl"
// ============================================================================
// SDFs (deine Varianten)
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

#ifndef UNION_EXTRA_PX
#define UNION_EXTRA_PX 2.0
#endif

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
// Normalen – dein Ansatz
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

float sceneSDF(vec2 p){ int dummy; return sceneSDF_withIndex_fast(p, dummy); }

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

// Ganz oben im File (oder vor main) schaltbar:
#define DEBUG_UNIFORMS 0

void main() {
  vec2 p  = FlutterFragCoord().xy + vec2(0.5);
  vec2 screenUV = p / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  screenUV.y = 1.0 - screenUV.y;
#endif

#if DEBUG_UNIFORMS
  // --- Sanity checks ---
  if (uSize.x < 1.0 || uSize.y < 1.0) {
    // Gelb = Size fehlt
    fragColor = vec4(1.0, 1.0, 0.0, 1.0);
    return;
  }
  if (uNumShapes < 0.5) {
    // Magenta = keine Shapes (Count nicht gesetzt)
    fragColor = vec4(1.0, 0.0, 1.0, 1.0);
    return;
  }
  if (u_sample_count < 1.0) {
    // Cyan = Blur-Kernel nicht befüllt
    fragColor = vec4(0.0, 1.0, 1.0, 1.0);
    return;
  }

  // --- Visual legend ---
  // Wir teilen das Bild in 6 Kacheln:
  //  [0,0.5)x[0,0.5): GlassColor
  //  [0.5,1)x[0,0.5): RI/CA/Thickness (vertikal gedrittelt)
  //  [0,1/3)x[0.5,1): LightDirection
  //  [1/3,2/3)x[0.5,1): LightIntensity / AmbientStrength (horizontal gedrittelt)
  //  [2/3,1)x[0.5,1): Saturation (R) + Lightness (G)

  vec2 uv = screenUV;
  vec3 col = vec3(0.0);

  if (uv.y < 0.5) {
    // obere Hälfte
    if (uv.x < 0.5) {
      // oben links: glass color
      col = uGlassColor.rgb;
    } else {
      // oben rechts: 3 Streifen (je ~1/3 Höhe)
      float y = uv.y * 2.0; // 0..1
      if (y < (1.0/3.0)) {
        // RI (mappe 1.0..1.5 -> 0..1, clampen)
        float riN = clamp((uRefractiveIndex - 1.0) / 0.5, 0.0, 1.0);
        col = vec3(riN);
      } else if (y < (2.0/3.0)) {
        // ChromaticAberration
        col = vec3(clamp(uChromaticAberration, 0.0, 1.0));
      } else {
        // Thickness (durch 64.0 normalisiert)
        col = vec3(clamp(uThickness / 64.0, 0.0, 1.0));
      }
    }
  } else {
    // untere Hälfte
    float x = uv.x;
    if (x < (1.0/3.0)) {
      // unten links: LightDirection als Farbe (-1..1 -> 0..1)
      col = vec3(0.5 + 0.5 * uLightDirection.x, 0.5 + 0.5 * uLightDirection.y, 0.0);
    } else if (x < (2.0/3.0)) {
      // unten mitte: 3 vertikale Streifen: Intensity, Ambient, SampleCount-Norm
      float xr = (x - 1.0/3.0) * 3.0; // 0..1
      if (xr < (1.0/3.0)) {
        col = vec3(clamp(uLightIntensity, 0.0, 1.0)); // grau
      } else if (xr < (2.0/3.0)) {
        col = vec3(clamp(uAmbientStrength, 0.0, 1.0)); // grau
      } else {
        // SampleCount / 50 (wie dein Kernel)
        col = vec3(clamp(u_sample_count / 50.0, 0.0, 1.0));
      }
    } else {
      // unten rechts: Saturation (R), Lightness (G)
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
  // ───────── Deine normale Glas-Rendering-Pipeline ─────────
  int   idx;
  float sd  = sceneSDF_withIndex_fast(p, idx);
  float foregroundAlpha = 1.0 - smoothstep(-2.0, 0.0, sd);
  if (foregroundAlpha < 0.01) {
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
#endif
}

