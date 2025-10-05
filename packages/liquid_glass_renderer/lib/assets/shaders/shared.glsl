// ======================== shared.glsl (LIBRARY ONLY) ========================
#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

// ---------- Configuration ----------
#ifndef TAU
#define TAU 6.28318530718
#endif
#ifndef SAMPLER_CLAMP
#define SAMPLER_CLAMP 1   // 1 = clamp to [0,1], 0 = mirror repeat
#endif
#ifndef MAX_VSAMPLES
#define MAX_VSAMPLES 64
#endif

// Performance/quality switches (can be overridden by the host via #define)
#ifndef LG_CA_VIS_THRESHOLD
#define LG_CA_VIS_THRESHOLD 1e-3  // Visibility threshold for CA (ca*dispLenPx)
#endif
#ifndef LG_USE_EXPLICIT_LOD
#define LG_USE_EXPLICIT_LOD 0     // 1 = use textureLod with bias under strong refraction
#endif
#ifndef LG_LOD_BIAS_SCALE
#define LG_LOD_BIAS_SCALE 0.75
#endif

// CA pass control for separable blur
#ifndef LG_CA_PASS_MODE
// 0 = both passes, 1 = vertical only (|u_dir_y| >= |u_dir_x|), 2 = horizontal only
#define LG_CA_PASS_MODE 1
#endif

// Numerical stability
#ifndef LG_EPS
#define LG_EPS 1e-8
#endif

// ---------- Small utilities ----------
float hash12(vec2 p){
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
}
vec2 lg_norm2(vec2 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}
vec3 lg_norm3(vec3 v){
  float d = max(dot(v, v), LG_EPS);
  return v * inversesqrt(d);
}

// ---------- sRGB helpers (define once) ----------
#ifndef LG_SRGB_HELPERS_DEFINED
#define LG_SRGB_HELPERS_DEFINED 1
#ifndef USE_EXACT_SRGB
#define USE_EXACT_SRGB 0
#endif
#if USE_EXACT_SRGB
float _srgb_to_linear(float c){
  return (c <= 0.04045) ? (c/12.92) : pow((c+0.055)/1.055, 2.4);
}
float _linear_to_srgb(float c){
  return (c <= 0.0031308) ? (c*12.92) : (1.055*pow(c,1.0/2.4)-0.055);
}
vec3 toLin(vec3 s){ return vec3(_srgb_to_linear(s.r), _srgb_to_linear(s.g), _srgb_to_linear(s.b)); }
vec3 toSR (vec3 l){ return vec3(_linear_to_srgb(l.r), _linear_to_srgb(l.g), _linear_to_srgb(l.b)); }
#else
vec3 toLin(vec3 s){ return pow(max(s, vec3(0.0)), vec3(2.2)); }
vec3 toSR (vec3 l){ return pow(max(l, vec3(0.0)), vec3(1.0/2.2)); }
#endif
#endif // LG_SRGB_HELPERS_DEFINED

// ---------- Tiling helpers ----------
float mirror1(float x){ float m = mod(x, 2.0); return (m <= 1.0) ? m : 2.0 - m; }
vec2  mirror01(vec2 uv){ return vec2(mirror1(uv.x), mirror1(uv.y)); }

#if SAMPLER_CLAMP
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, clamp(uv, vec2(0.0), vec2(1.0))); }
#else
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, mirror01(uv)); }
#endif

// ---------- Impeller-identical tiling (math only; no sampler params) ----------
vec2 tile_uv_mode(vec2 uv, vec2 size, float mode){
  if (mode < 0.5) {
    // Clamp with a half-texel margin like Impeller
    vec2 eps = 0.5 / size;
    return clamp(uv, eps, vec2(1.0) - eps);
  } else if (mode < 1.5) {
    return fract(uv); // repeat
  } else if (mode < 2.5) {
    // mirror
    vec2 m = mod(uv, 2.0);
    return mix(m, 2.0 - m, step(1.0, m));
  } else {
    // decal: leave UV as-is; out-of-bounds handled separately
    return uv;
  }
}

// ────────────────────────────────────────────────────────────────────────────
/*  Exact Impeller-style Gaussian 1D (inline sampling; ES-safe) */
// ────────────────────────────────────────────────────────────────────────────
vec4 applyGaussian1D_Impeller(sampler2D tex, vec2 baseUV){
  vec2 pixel    = vec2(1.0 / uSize.x, 1.0 / uSize.y);
  vec2 step_vec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);

  vec4 sum  = vec4(0.0);
  float wsum = 0.0;

  float nRaw = u_sample_count;
  if ((nRaw == nRaw) && (nRaw > 0.5)) {
    int nS = int(nRaw + 0.5);
    for (int i = 0; i < 50; ++i) {
      if (i >= nS) break;
      float t = u_samples[i].x;  // offset in pixels along axis
      float w = u_samples[i].z;  // weight
      if (!(w > 1e-6)) continue;

      vec2 uvOff = baseUV + step_vec * t;

      vec4 s;
      if (u_tile_mode >= 2.5 &&
          (any(lessThan(uvOff, vec2(0.0))) || any(greaterThan(uvOff, vec2(1.0))))) {
        s = vec4(0.0);
      } else {
        vec2 tiled = tile_uv_mode(uvOff, uSize, u_tile_mode);
        s = texture(tex, tiled);
      }

      sum  += w * s;
      wsum += w;
    }
  }

  if (wsum > 1e-6) return sum / wsum;

  // Fallback: clamped sample at base UV with half-texel guard
  vec2 eps = vec2(0.5 / uSize.x, 0.5 / uSize.y);
  return texture(tex, clamp(baseUV, eps, vec2(1.0) - eps));
}

// ────────────────────────────────────────────────────────────────────────────
// Pass logic for CA to avoid double work in separable blur
// ────────────────────────────────────────────────────────────────────────────
bool _shouldApplyCA(){
#if LG_CA_PASS_MODE == 0
  return true;
#elif LG_CA_PASS_MODE == 1
  // Vertical pass only (|dir_y| dominates)
  return (abs(u_dir_y) >= abs(u_dir_x));
#else
  // Horizontal pass only
  return (abs(u_dir_x) > abs(u_dir_y));
#endif
}

// ────────────────────────────────────────────────────────────────────────────
/* Lighting / Color helpers */
// ────────────────────────────────────────────────────────────────────────────
vec3 getHighlightColor(vec3 backgroundColor, float targetBrightness) {
  float luminance = dot(backgroundColor, vec3(0.299, 0.587, 0.114));

  float maxC = max(max(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float minC = min(min(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float saturation = maxC > 0.0 ? (maxC - minC) / maxC : 0.0;

  vec3 coloredHighlight = vec3(targetBrightness);
  if (luminance > 0.001) {
    vec3 normalizedBackground = backgroundColor / max(luminance, 1e-6);
    coloredHighlight = normalizedBackground * targetBrightness;
    float saturationBoost = 1.3;
    vec3 gray = vec3(dot(coloredHighlight, vec3(0.299, 0.587, 0.114)));
    coloredHighlight = mix(gray, coloredHighlight, saturationBoost);
    coloredHighlight = min(coloredHighlight, vec3(1.0));
  }

  float luminanceFactor  = smoothstep(0.0, 0.6, luminance);
  float saturationFactor = smoothstep(0.0, 0.4, saturation);
  float colorInfluence   = luminanceFactor * saturationFactor;

  vec3 whiteHighlight = vec3(targetBrightness);
  return mix(whiteHighlight, coloredHighlight, colorInfluence);
}

float getHeight(float sd, float thickness){
  if (sd >= 0.0 || thickness <= 0.0) return 0.0;
  if (sd < -thickness) return thickness;
  float x = thickness + sd;
  return sqrt(max(0.0, thickness*thickness - x*x));
}

// Inverted dispersion: “red refracts more than blue”
float calculateDispersiveIndex(float baseIndex, float chromaticAberration, float wavelength) {
  if (chromaticAberration < 0.001) return baseIndex;
  float wavelengthSq   = wavelength * wavelength;
  float wavelengthQuad = wavelengthSq * wavelengthSq;
  float B = chromaticAberration * 0.08  * (baseIndex - 1.0);
  float C = chromaticAberration * 0.003 * (baseIndex - 1.0);
  return baseIndex - B / wavelengthSq - C / wavelengthQuad;
}

// ────────────────────────────────────────────────────────────────────────────
// Rim masks (inner-only) – band & core, pixel-accurate via |∇sd|
struct RimMasks { float band; float core; };

RimMasks rimMasksInner(float sd, float rimWidthPx, float rimSharpness){
  // Convert a pixel width (rimWidthPx) into an SDF-width using gradient magnitude.
  vec2  g    = vec2(dFdx(sd), dFdy(sd));
  float gmag = max(length(g), 1e-6);
  float wSDF = max(rimWidthPx, 0.0) * gmag;

  // 0..1 only for sd in [-wSDF, 0] (inside the shape)
  float edge01 = step(sd, 0.0) * smoothstep(-wSDF, 0.0, sd);

  // Outer band (overall rim thickness) and a tighter core (sharp inner fringe).
  float gamma = max(rimSharpness, 1e-3);
  float band  = pow(edge01, 1.0 / gamma);

  float coreExp = mix(3.0, 1.1, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float core    = pow(edge01, coreExp / gamma);

  RimMasks m; m.band = band; m.core = core; return m;
}

// ────────────────────────────────────────────────────────────────────────────
// White Fresnel-like fringe (under the rim light) – thickens the bright edge
// without softening the geometric contour.
float fresnelSchlick(float cosTheta, float F0){
  return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}
vec3 applyWhiteFringe(
  vec3 baseColor, vec3 normal, float sd, float rimWidthPx, float rimSharpness
){
  RimMasks rm = rimMasksInner(sd, rimWidthPx, rimSharpness);

  // Fresnel relative to the view vector (V=(0,0,1)), cos = N·V = normal.z.
  float cosNV = clamp(abs(normal.z), 0.0, 1.0);
  float F = fresnelSchlick(cosNV, 0.04); // dielectric glass F0 ≈ 0.04

  // Amount of “pull toward white”: band controls width, core concentrates the inner fringe.
  float bandGain = mix(0.25, 0.65, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float coreGain = mix(0.15, 0.40, clamp(rimWidthPx / 64.0, 0.0, 1.0));

  float amt = rm.band * bandGain + rm.core * coreGain;
  amt *= F;

  return mix(baseColor, vec3(1.0), clamp(amt, 0.0, 1.0));
}

// ────────────────────────────────────────────────────────────────────────────
// Refraction + Chromatic Aberration (Gaussian, pass-compatible)
// ────────────────────────────────────────────────────────────────────────────
vec4 calculateRefraction(
  vec2 screenUV, vec3 normal, float sd, float height, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec2 sizePx, sampler2D backgroundTexture,
  out vec2 refractionDisplacement,
  float rimWidthPx, float rimSharpness,
  vec2 lightDirection, float lightIntensity
){
  // 1) Refraction → displacement
  vec3 incident = vec3(0.0, 0.0, -1.0);
  float n       = max(refractiveIndex, 1.0001);
  vec3 refr     = refract(incident, normal, 1.0 / n);
  float baseH   = thickness * 8.0;
  float refrL   = (height + baseH) / max(0.001, abs(refr.z));

  // Subtle displacement boost gated by light and inner rim band,
  // so the colored edge becomes visibly thicker without a soft overlay.
  RimMasks rm     = rimMasksInner(sd, rimWidthPx, rimSharpness);
  vec2  L         = lightDirection;
  vec2  nxy       = lg_norm2(normal.xy);
  float facing    = abs(dot(nxy, L));
  float lightMask = pow(facing, 0.7) * clamp(lightIntensity, 0.0, 1.0);
  float boost     = 1.0 + 0.4 * (rm.band * lightMask);

  vec2 dispPx = refr.xy * (refrL * boost);       // in pixels
  refractionDisplacement = dispPx / sizePx;      // in UV
  vec2 uvBase = screenUV + refractionDisplacement;

  // Base: one Gaussian (Impeller)
  vec4 gS = applyGaussian1D_Impeller(backgroundTexture, uvBase);

  // CA gating
  float ca = max(chromaticAberration, 0.0);
  float dispLenPx = length(dispPx);
  if (ca * dispLenPx < LG_CA_VIS_THRESHOLD || !_shouldApplyCA()) {
    return gS; // Invisible or the wrong pass → keep base
  }

  // Direction in UV, robustly normalized
  vec2 dirUV = lg_norm2(refractionDisplacement + vec2(LG_EPS, LG_EPS));

  // Offset proportional to CA and displacement length; clamp to avoid extremes
  float caPixels = clamp(dispLenPx * (1.5 * ca), 0.0, 6.0);
  float shortSide = max(1.0, min(sizePx.x, sizePx.y));
  vec2  caUV      = dirUV * (caPixels / shortSide);

  // Optional LOD bias
  #if LG_USE_EXPLICIT_LOD
    float lodBias = clamp(LG_LOD_BIAS_SCALE * caPixels / 2.0, 0.0, 3.5);
    #define SAMPLE_GAUSS_AT(_uv) textureLod(backgroundTexture, clamp((_uv), vec2(0.0), vec2(1.0)), lodBias)
  #else
    #define SAMPLE_GAUSS_AT(_uv) applyGaussian1D_Impeller(backgroundTexture, (_uv))
  #endif

  // Two additional Gaussian samples: R forward, B backward
  float r = SAMPLE_GAUSS_AT(uvBase + caUV).r;
  float b = SAMPLE_GAUSS_AT(uvBase - caUV).b;

  #undef SAMPLE_GAUSS_AT

  // G/Alpha kept from base; mix R/B proportionally to CA (no-op when ca=0)
  float mixAmt = clamp(ca, 0.0, 1.0);
  float outR = mix(gS.r, r, mixAmt);
  float outG = gS.g;
  float outB = mix(gS.b, b, mixAmt);

  return vec4(outR, outG, outB, gS.a);
}

// ────────────────────────────────────────────────────────────────────────────
// Lighting — inner-only, uses the same rim masks; symmetric w.r.t. ±L
// ────────────────────────────────────────────────────────────────────────────
vec3 calculateLighting(
  vec2 uv, vec3 normal, float sd, float thickness, float height,
  vec2 lightDirection, float lightIntensity, float ambientStrength,
  vec3 backgroundColor, float rimWidthPx, float rimSharpness
){
  float thicknessFactor = smoothstep(5.0, 7.0, thickness);
  if (thicknessFactor < 0.01 || lightIntensity < 0.01) return vec3(0.0);

  RimMasks rm   = rimMasksInner(sd, rimWidthPx, rimSharpness);

  vec2  L        = lightDirection;
  vec2  nxy      = lg_norm2(normal.xy);
  float facing   = abs(dot(nxy, L));       // symmetric for ±L
  float lightMask= pow(facing, 0.7);

  float rimMask  = rm.band * lightMask;
  if (rimMask < 1e-3) return vec3(0.0);

  float mainL = max(0.0, dot(nxy,  L));
  float oppL  = max(0.0, dot(nxy, -L));
  float total = mainL + oppL * 0.8;

  vec3 hl             = getHighlightColor(backgroundColor, 0.7);
  vec3 directionalRim = hl * (total * total) * lightIntensity * 2.0;
  vec3 ambientRim     = getHighlightColor(backgroundColor, 0.4) * ambientStrength;

  vec3 lighting = (directionalRim + ambientRim);

  // Slight pull towards white only in the core to improve perceived sparkle.
  float whitePull  = 0.55;
  float coreGain   = mix(0.16, 0.36, clamp(rimWidthPx/64.0, 0.0, 1.0));
  vec3  towardWhite= mix(lighting, vec3(1.0), whitePull);
  lighting = mix(lighting, towardWhite, rm.core * coreGain);

  return lighting * rimMask * thicknessFactor;
}

// ────────────────────────────────────────────────────────────────────────────
// Post color ops
// ────────────────────────────────────────────────────────────────────────────
vec3 applySaturationLightness(vec3 color, float saturation, float lightness){
  float luminance = dot(color, vec3(0.299, 0.587, 0.114));
  vec3 saturatedColor = mix(vec3(luminance), color, saturation);
  vec3 adjustedColor;
  if (lightness > 1.0) {
    adjustedColor = mix(saturatedColor, vec3(1.0), lightness - 1.0);
  } else {
    adjustedColor = saturatedColor * lightness;
  }
  return clamp(adjustedColor, 0.0, 1.0);
}

// Apply glass color tint to the refracted color
vec4 applyGlassColor(vec4 liquidColor, vec4 glassColor){
  vec4 finalColor = liquidColor;

  if (glassColor.a > 0.0) {
    float glassLuminance = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));
    if (glassLuminance < 0.5) {
      vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
      finalColor.rgb = mix(liquidColor.rgb, darkened, glassColor.a);
    } else {
      vec3 invLiquid = vec3(1.0) - liquidColor.rgb;
      vec3 invGlass  = vec3(1.0) - glassColor.rgb;
      vec3 screened  = vec3(1.0) - (invLiquid * invGlass);
      finalColor.rgb = mix(liquidColor.rgb, screened, glassColor.a);
    }
    finalColor.a = liquidColor.a;
  }
  return finalColor;
}

// ────────────────────────────────────────────────────────────────────────────
// PUBLIC API – no Kawase parameters; fully compatible with the blur pipeline
// ────────────────────────────────────────────────────────────────────────────
vec4 renderLiquidGlass(
  vec2 screenUV, vec2 p, vec2 uSizePx,
  float sd, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec4  glassColor, vec2 lightDirection, float lightIntensity, float ambientStrength,
  sampler2D backgroundTexture, vec3 normal, float foregroundAlpha,
  float saturation, float lightness, float rimWidthPx, float rimSharpness
){
  vec4 backgroundColor = texScreen(backgroundTexture, screenUV);

  if (foregroundAlpha < 0.001) return backgroundColor;
  if (thickness < 0.01)       return backgroundColor;

  float height = getHeight(sd, thickness);

  vec2 refractionDisplacement;
  vec4 refractColor = calculateRefraction(
    screenUV, normal, sd, height, thickness, refractiveIndex, chromaticAberration,
    uSizePx, backgroundTexture, refractionDisplacement,
    rimWidthPx, rimSharpness,
    lightDirection, lightIntensity
  );

  // Widen the bright inner edge beneath the rim light.
  refractColor.rgb = applyWhiteFringe(refractColor.rgb, normal, sd, rimWidthPx, rimSharpness);

  vec3 lighting = calculateLighting(
    screenUV, normal, sd, thickness, height,
    lightDirection, lightIntensity, ambientStrength,
    backgroundColor.rgb, rimWidthPx, rimSharpness
  );

  vec4 finalColor = applyGlassColor(refractColor, glassColor);
  finalColor.rgb += lighting;
  finalColor.rgb  = applySaturationLightness(finalColor.rgb, saturation, lightness);

  // Optional: slight edge alpha lift based on the inner rim band.
  RimMasks rm = rimMasksInner(sd, rimWidthPx, rimSharpness);
  float edgeAlphaGain = mix(0.20, 0.45, clamp(rimWidthPx/64.0, 0.0, 1.0));
  float mixA = clamp(max(foregroundAlpha, rm.band * edgeAlphaGain), 0.0, 1.0);

  return mix(backgroundColor, finalColor, mixA);
}

// Optional: debug normals overlay
vec4 debugNormals(vec4 originalColor, vec3 normal, bool enableDebug) {
  if (enableDebug) {
    vec3 normalColor = (normal + 1.0) * 0.5;
    return mix(originalColor, vec4(normalColor, 1.0), 0.99);
  }
  return originalColor;
}

#endif // LIQUID_GLASS_SHARED_GLSL
