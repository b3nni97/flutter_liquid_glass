// liquid_glass_arbitrary.frag — Arbitrary-Variante (kompatibles Layout zu liquid_glass.frag)
//
// Layout-Übersicht (kompatibel zu liquid_glass.frag):
//   0 : vec2 uSize
//   1 : vec4 uGlassColor
//   2 : vec4 uOpticalProps   (RI, CA, thickness, blend)
//   3 : vec4 uLightConfig    (angle, intensity, ambient, saturation)
//   4 : vec2 uColorAdjust    (lightness, numShapes[unused])
//   5 : vec2 uLightDirection (cos, sin)
//   6..9 : mat4 uTransform
//   10 : vec2 uForegroundSize     // NEU (Matte) – layer size in device px
//   11 : vec2 uOffset             // NEU (Matte) – layer top-left (device px)
//   106 : vec4 uBlurHeader        // (dir.x, dir.y, sample_count, tile_mode)
//   107.. : vec4 u_samples[50]    // vec4(tPx, 0, w, 0)

#version 320 es
precision highp float;

#include <flutter/runtime_effect.glsl>

// ────────────────────────────────────────────────────────────────────────────
// Gepackter Header (IDENTISCH zu liquid_glass.frag) + Transform
// ────────────────────────────────────────────────────────────────────────────
layout(location = 0) uniform vec2 uSize;           // auto von Flutter
layout(location = 1) uniform vec4 uGlassColor;     // r,g,b,a
layout(location = 2) uniform vec4 uOpticalProps;   // RI, CA, thickness, blend
layout(location = 3) uniform vec4 uLightConfig;    // angle, intensity, ambient, saturation
layout(location = 4) uniform vec2 uColorAdjust;    // lightness, numShapes (hier ungenutzt)
layout(location = 5) uniform vec2 uLightDirection; // cos(angle), sin(angle)
layout(location = 6) uniform mat4 uTransform;      // Transform für FragCoord (kompatibel)

// Backwards-compatible Aliases
float uRefractiveIndex     = uOpticalProps.x;
float uChromaticAberration = uOpticalProps.y;
float uThickness           = uOpticalProps.z;
float uBlend               = uOpticalProps.w;

float uLightAngle          = uLightConfig.x;  // legacy
float uLightIntensity      = uLightConfig.y;
float uAmbientStrength     = uLightConfig.z;
float uSaturation          = uLightConfig.w;

float uLightness           = uColorAdjust.x;
// float uNumShapes         = uColorAdjust.y; // hier nicht benötigt

// ────────────────────────────────────────────────────────────────────────────
// Matte/Layer-spezifische Uniforms (NEU) → Locations 10 und 11
// ────────────────────────────────────────────────────────────────────────────
layout(location = 10) uniform vec2 uForegroundSize; // Größe der Matte in Device-Px
layout(location = 11) uniform vec2 uOffset;         // Top-left der Matte in Device-Px (Screen-Koords)

// ────────────────────────────────────────────────────────────────────────────
#define DEBUG_NORMALS     0
#define DEBUG_BLUR_MATTE  0

// ────────────────────────────────────────────────────────────────────────────
// Impeller-Blur-Uniforms (IDENTISCH zu liquid_glass.frag)
// ────────────────────────────────────────────────────────────────────────────
layout(location = 106) uniform vec4 uBlurHeader;  // x=dir.x, y=dir.y, z=sample_count, w=tile_mode
#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

layout(location = 107) uniform vec4 u_samples[50]; // vec4(tPx, 0, w, 0)

// ────────────────────────────────────────────────────────────────────────────
// Texturen
// ────────────────────────────────────────────────────────────────────────────
uniform sampler2D uBackgroundTexture;        // Szene hinter Glas
uniform sampler2D uForegroundTexture;        // Matte (RGBA) – ungeblurred
uniform sampler2D uForegroundBlurredTexture; // Matte (RGBA) – geblurrt (für SDF/Normal-Reko)

layout(location = 0) out vec4 fragColor;

// ────────────────────────────────────────────────────────────────────────────
// shared.glsl (nutzt uSize und Impeller-Uniforms oben)
// ────────────────────────────────────────────────────────────────────────────
#include "shared.glsl"

// ────────────────────────────────────────────────────────────────────────────
// Arbitrary-Hilfsfunktionen
// ────────────────────────────────────────────────────────────────────────────
float approximateSDF(float blurredAlpha, float thickness) {
  // alpha: 0=edge → 1=center  =>  SDF: 0=edge → -thickness=center
  float normalizedDistance = clamp(blurredAlpha, 0.0, 1.0);
  return -normalizedDistance * thickness;
}

vec2 findShapeCenter(vec2 currentUV) {
  // UV 0..1 relativ zur Matte
  vec2 texel = 2.0 / max(uForegroundSize, vec2(1.0));
  vec2 centerSum = vec2(0.0);
  float totalAlpha = 0.0;

  const int R = 10;
  for (int y = -R; y <= R; y++) {
    for (int x = -R; x <= R; x++) {
      vec2 suv = currentUV + vec2(float(x), float(y)) * texel;
      if (all(greaterThanEqual(suv, vec2(0.0))) &&
          all(lessThanEqual   (suv, vec2(1.0)))) {
        float a = texture(uForegroundTexture, suv).a;
        if (a > 0.1) {
          centerSum   += suv * a;
          totalAlpha  += a;
        }
      }
    }
  }
  return (totalAlpha > 0.0) ? (centerSum / totalAlpha) : currentUV;
}

vec3 getReconstructedNormal(vec2 p, float thickness) {
  // p: layer-lokale Device-Pixel-Koordinate
  vec2 uv = p / max(uForegroundSize, vec2(1.0));

  // ohne Matte → keine Normale
  if (texture(uForegroundTexture, uv).a < 0.01) {
    return vec3(0.0, 0.0, 1.0);
  }

  vec2 centerUV = findShapeCenter(uv);
  vec2 d = uv - centerUV;
  float lenD = length(d);
  if (lenD < 1e-3) return vec3(0.0, 0.0, 1.0);

  vec2 outward = d / lenD;

  float blurredAlpha  = texture(uForegroundBlurredTexture, uv).a;
  float edgeDistance  = clamp(blurredAlpha, 0.0, 1.0);

  // z flacher machen, damit der Rand stärker reflektiert
  float nz = pow(edgeDistance, 0.2);
  float xyScale = sqrt(max(0.0, 1.0 - nz * nz));

  return normalize(vec3(outward * xyScale, nz));
}

vec3 getNormal(vec2 p, float thickness) {
  return getReconstructedNormal(p, thickness);
}

// ────────────────────────────────────────────────────────────────────────────
// MAIN
// ────────────────────────────────────────────────────────────────────────────
void main() {
  vec2 pScreen = FlutterFragCoord().xy + vec2(0.5);
  vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0));
  vec2 screenUV = pScreen * invSize;

#ifdef IMPELLER_TARGET_OPENGLES
  screenUV.y = 1.0 - screenUV.y;
#endif

  // Kompatibel zur Standard-Variante: Transform anwenden
  vec4 transformedCoord = uTransform * vec4(pScreen, 0.0, 1.0);
  vec2 p = transformedCoord.xy;

  // Layer-lokale Koords/UV
  vec2 layerLocal = p - uOffset;
  vec2 layerUV    = layerLocal / uForegroundSize;

  // Außerhalb der Matte → Hintergrund
  if (any(lessThan(layerUV, vec2(0.0))) || any(greaterThan(layerUV, vec2(1.0)))) {
    fragColor = texScreen(uBackgroundTexture, screenUV);
    return;
  }

  vec4 fg = texture(uForegroundTexture, layerUV);
  if (fg.a < 0.001) {
    fragColor = texScreen(uBackgroundTexture, screenUV);
    return;
  }

  // SDF aus geblurrter Matte
  float blurredA = texture(uForegroundBlurredTexture, layerUV).a;
  float sd = approximateSDF(blurredA, uThickness);

  // Normale aus Matte rekonstruieren
  vec3 normal = getNormal(layerLocal, uThickness);

  // Glas-Rendering (CA + Impeller-Blur in shared.glsl)
  fragColor = renderLiquidGlass(
      screenUV,
      p,
      uSize,                     // sizePx
      sd,
      uThickness,
      uRefractiveIndex,
      uChromaticAberration,
      uGlassColor,
      uLightDirection,
      uLightIntensity,
      uAmbientStrength,
      uBackgroundTexture,
      normal,
      fg.a,                      // foregroundAlpha = Matte
      uSaturation,
      uLightness,1.5, 0.89
  );

#if DEBUG_NORMALS
  // simple visualization: overlay normal as color
  fragColor.rgb = mix(fragColor.rgb, normalize(normal) * 0.5 + 0.5, 0.6);
#endif

#if DEBUG_BLUR_MATTE
  vec4 blurredTex = texture(uForegroundBlurredTexture, layerUV);
  fragColor = mix(fragColor, blurredTex, 0.95);
#endif
}
