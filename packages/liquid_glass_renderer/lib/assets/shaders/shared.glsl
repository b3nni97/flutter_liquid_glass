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

#ifndef LG_CA_VIS_THRESHOLD
#define LG_CA_VIS_THRESHOLD 1e-3
#endif
#ifndef LG_USE_EXPLICIT_LOD
#define LG_USE_EXPLICIT_LOD 0
#endif
#ifndef LG_LOD_BIAS_SCALE
#define LG_LOD_BIAS_SCALE 0.75
#endif

#ifndef LG_CA_PASS_MODE
// 0 = both passes, 1 = vertical only (|u_dir_y| >= |u_dir_x|), 2 = horizontal only
#define LG_CA_PASS_MODE 1
#endif

#ifndef LG_EPS
#define LG_EPS 1e-8
#endif

// ---------- Host-provided uniforms (declared in main .frag) ----------
// Base blur kernel header/taps, size, etc. exist in deinem Hauptshader.
// Wir listen hier nur Glow-spezifische Inputs, die diese Datei nutzt:
//
// uniform float uTouchCount_f;         // 0..8
// uniform vec4  uTouches[8];           // (x_px, y_px, radius_px, fade_px)
// uniform float uTouchGlowStrengths[8];// NEU: per-touch Glow-Multiplikator (0..1)
// uniform vec4  uGlowParams;           // (strength, power, tintMode, insideOnly)
// uniform vec4  uGlowColor;            // (r, g, b, a)  -> a = Tint-Intensität
//
// NEU (für GlowStyle-Overrides):
// uniform vec4  uGlowOverrides;        // (lightness, saturation, blurSigmaPx, mix)
// uniform vec4  uGlowFlags;            // (hasLightness, hasSaturation, hasBlur, hasGlassColor)
// uniform vec4  uGlowGlass;            // (glass_r, glass_g, glass_b, glass_a)

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

// ---------- sRGB helpers ----------
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

vec2 tile_uv_mode(vec2 uv, vec2 size, float mode){
  if (mode < 0.5) {
    vec2 eps = 0.5 / size;
    return clamp(uv, eps, vec2(1.0) - eps);
  } else if (mode < 1.5) {
    return fract(uv);
  } else if (mode < 2.5) {
    vec2 m = mod(uv, 2.0);
    return mix(m, 2.0 - m, step(1.0, m));
  } else {
    return uv; // decal
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Impeller 1D Gaussian (inline); benötigt u_* aus dem Host
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
      float t = u_samples[i].x;  // offset px
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

  vec2 eps = vec2(0.5 / uSize.x, 0.5 / uSize.y);
  return texture(tex, clamp(baseUV, eps, vec2(1.0) - eps));
}

// CA-pass gating
bool _shouldApplyCA(){
#if LG_CA_PASS_MODE == 0
  return true;
#elif LG_CA_PASS_MODE == 1
  return (abs(u_dir_y) >= abs(u_dir_x));
#else
  return (abs(u_dir_x) > abs(u_dir_y));
#endif
}

// ────────────────────────────────────────────────────────────────────────────
// Lighting / Color helpers
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

// „umgedrehte“ Dispersion
float calculateDispersiveIndex(float baseIndex, float chromaticAberration, float wavelength) {
  if (chromaticAberration < 0.001) return baseIndex;
  float wavelengthSq   = wavelength * wavelength;
  float wavelengthQuad = wavelengthSq * wavelengthSq;
  float B = chromaticAberration * 0.08  * (baseIndex - 1.0);
  float C = chromaticAberration * 0.003 * (baseIndex - 1.0);
  return baseIndex - B / wavelengthSq - C / wavelengthQuad;
}

// Rim masks
struct RimMasks { float band; float core; };

RimMasks rimMasksInner(float sd, float rimWidthPx, float rimSharpness){
  vec2  g    = vec2(dFdx(sd), dFdy(sd));
  float gmag = max(length(g), 1e-6);
  float wSDF = max(rimWidthPx, 0.0) * gmag;

  float edge01 = step(sd, 0.0) * smoothstep(-wSDF, 0.0, sd);

  float gamma = max(rimSharpness, 1e-3);
  float band  = pow(edge01, 1.0 / gamma);

  float coreExp = mix(3.0, 1.1, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float core    = pow(edge01, coreExp / gamma);

  RimMasks m; m.band = band; m.core = core; return m;
}

float fresnelSchlick(float cosTheta, float F0){
  return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}
vec3 applyWhiteFringe(vec3 baseColor, vec3 normal, float sd, float rimWidthPx, float rimSharpness){
  RimMasks rm = rimMasksInner(sd, rimWidthPx, rimSharpness);
  float cosNV = clamp(abs(normal.z), 0.0, 1.0);
  float F = fresnelSchlick(cosNV, 0.04);
  float bandGain = mix(0.25, 0.65, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float coreGain = mix(0.15, 0.40, clamp(rimWidthPx / 64.0, 0.0, 1.0));
  float amt = rm.band * bandGain + rm.core * coreGain;
  amt *= F;
  return mix(baseColor, vec3(1.0), clamp(amt, 0.0, 1.0));
}

// ────────────────────────────────────────────────────────────────────────────
// Refraction + CA
// ────────────────────────────────────────────────────────────────────────────
vec4 calculateRefraction(
  vec2 screenUV, vec3 normal, float sd, float height, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec2 sizePx, sampler2D backgroundTexture,
  out vec2 refractionDisplacement,
  float rimWidthPx, float rimSharpness,
  vec2 lightDirection, float lightIntensity
){
  vec3 incident = vec3(0.0, 0.0, -1.0);
  float n       = max(refractiveIndex, 1.0001);
  vec3 refr     = refract(incident, normal, 1.0 / n);
  float baseH   = thickness * 8.0;
  float refrL   = (height + baseH) / max(0.001, abs(refr.z));

  RimMasks rm     = rimMasksInner(sd, rimWidthPx, rimSharpness);
  vec2  L         = lightDirection;
  vec2  nxy       = lg_norm2(normal.xy);
  float facing    = abs(dot(nxy, L));
  float lightMask = pow(facing, 0.7) * clamp(lightIntensity, 0.0, 1.0);
  float boost     = 1.0 + 0.4 * (rm.band * lightMask);

  vec2 dispPx = refr.xy * (refrL * boost);
  refractionDisplacement = dispPx / sizePx;
  vec2 uvBase = screenUV + refractionDisplacement;

  vec4 gS = applyGaussian1D_Impeller(backgroundTexture, uvBase);

  float ca = max(chromaticAberration, 0.0);
  float dispLenPx = length(dispPx);
  if (ca * dispLenPx < LG_CA_VIS_THRESHOLD || !_shouldApplyCA()) {
    return gS;
  }

  vec2 dirUV = lg_norm2(refractionDisplacement + vec2(LG_EPS, LG_EPS));
  float caPixels = clamp(dispLenPx * (1.5 * ca), 0.0, 6.0);
  float shortSide = max(1.0, min(sizePx.x, sizePx.y));
  vec2  caUV      = dirUV * (caPixels / shortSide);

  #if LG_USE_EXPLICIT_LOD
    float lodBias = clamp(LG_LOD_BIAS_SCALE * caPixels / 2.0, 0.0, 3.5);
    #define SAMPLE_GAUSS_AT(_uv) textureLod(backgroundTexture, clamp((_uv), vec2(0.0), vec2(1.0)), lodBias)
  #else
    #define SAMPLE_GAUSS_AT(_uv) applyGaussian1D_Impeller(backgroundTexture, (_uv))
  #endif

  float r = SAMPLE_GAUSS_AT(uvBase + caUV).r;
  float b = SAMPLE_GAUSS_AT(uvBase - caUV).b;

  #undef SAMPLE_GAUSS_AT

  float mixAmt = clamp(ca, 0.0, 1.0);
  float outR = mix(gS.r, r, mixAmt);
  float outG = gS.g;
  float outB = mix(gS.b, b, mixAmt);

  return vec4(outR, outG, outB, gS.a);
}

// ────────────────────────────────────────────────────────────────────────────
// Lighting
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
  float facing   = abs(dot(nxy, L));
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
  vec3 adjustedColor = (lightness > 1.0)
                       ? mix(saturatedColor, vec3(1.0), lightness - 1.0)
                       : saturatedColor * lightness;
  return clamp(adjustedColor, 0.0, 1.0);
}

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
// Glow helpers: Maske & lokaler Zusatz-Blur (isotrop, kleiner Kernel)
// ────────────────────────────────────────────────────────────────────────────
float glowTouchMask(vec2 pPx, float insideOnly, float sd){
  float inMask = (insideOnly >= 0.5) ? step(sd, 0.0) : 1.0;
  float n = uTouchCount_f;
  if (!(n > 0.5)) return 0.0;

  float m = 0.0;
  for (int i=0; i<8; ++i){
    if (i >= int(n)) break;
    vec4 tp = uTouches[i];
    float d = length(pPx - tp.xy);
    float inner = tp.z;
    float outer = tp.z + max(tp.w, 1e-3);
    float mi = smoothstep(outer, inner, d);

    // NEU: pro-Touch Glow-Multiplikator (0..1)
    float s = clamp(uTouchGlowStrengths[i], 0.0, 1.0);
    mi *= s;

    m = max(m, mi);
  }
  return m * inMask;
}

// schneller 2D-Gaussian-Approx (9 Samples) um *zusätzlichen* lokalen Blur zu simulieren
vec4 gaussianApprox9(sampler2D tex, vec2 uv, float sigmaPx, vec2 sizePx){
  if (sigmaPx <= 0.01) return texScreen(tex, uv);
  // einfache, isotrope 3x3-Gewichtung
  vec2 px = 1.0 / sizePx;
  float s = clamp(sigmaPx, 0.0, 6.0);
  // Gewichte grob normalisiert
  float w0 = 0.227027; // center
  float w1 = 0.194594;
  float w2 = 0.121621;

  vec4 c  = texScreen(tex, uv) * w0;
  c += texScreen(tex, uv + vec2(px.x, 0.0)) * w1;
  c += texScreen(tex, uv - vec2(px.x, 0.0)) * w1;
  c += texScreen(tex, uv + vec2(0.0, px.y)) * w1;
  c += texScreen(tex, uv - vec2(0.0, px.y)) * w1;

  c += texScreen(tex, uv + vec2(px.x, px.y)) * w2;
  c += texScreen(tex, uv + vec2(-px.x, px.y)) * w2;
  c += texScreen(tex, uv + vec2(px.x, -px.y)) * w2;
  c += texScreen(tex, uv + vec2(-px.x, -px.y)) * w2;

  // skaliere Effizienz grob mit sigma (linearer Mix mit original)
  float t = clamp((s - 1.0) / 5.0, 0.0, 1.0);
  return mix(texScreen(tex, uv), c, t);
}

// ────────────────────────────────────────────────────────────────────────────
// PUBLIC API
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
  vec4 refractColorBase = calculateRefraction(
    screenUV, normal, sd, height, thickness,
    refractiveIndex, chromaticAberration,
    uSizePx, backgroundTexture, refractionDisplacement,
    rimWidthPx, rimSharpness, lightDirection, lightIntensity
  );

  // Sparkle am Rand
  refractColorBase.rgb = applyWhiteFringe(refractColorBase.rgb, normal, sd, rimWidthPx, rimSharpness);

  vec3 lighting = calculateLighting(
    screenUV, normal, sd, thickness, height,
    lightDirection, lightIntensity, ambientStrength,
    backgroundColor.rgb, rimWidthPx, rimSharpness
  );

  // Standard-Pipeline (ohne Glow-Override)
  vec4 coloredBase = applyGlassColor(refractColorBase, glassColor);
  coloredBase.rgb += lighting;
  coloredBase.rgb  = applySaturationLightness(coloredBase.rgb, saturation, lightness);

  // ───────────── Glow-Region mit Style-Overrides ─────────────
  float gStrength  = uGlowParams.x;
  float gPower     = max(uGlowParams.y, 0.0001);
  float gTintMode  = uGlowParams.z;
  float gInside    = uGlowParams.w;

  // Flags & Override-Werte
  float hasL = uGlowFlags.x;
  float hasS = uGlowFlags.y;
  float hasB = uGlowFlags.z;
  float hasG = uGlowFlags.w;

  float oLight = uGlowOverrides.x;   // Ziel-Lightness
  float oSatu  = uGlowOverrides.y;   // Ziel-Saturation
  float oBlur  = uGlowOverrides.z;   // Ziel-Blur (Sigma px)
  float oMix   = clamp(uGlowOverrides.w, 0.0, 1.0); // Max-Blend (GlowStyle.mix)

  vec2 uvBase = screenUV + refractionDisplacement; // Basis-UV nach Refraction

  vec4 outColor = coloredBase;

  if (gStrength > 0.0001 && uTouchCount_f > 0.5){
    vec2 pPx = screenUV * uSizePx;
    float maskRaw = glowTouchMask(pPx, gInside, sd);
    if (maskRaw > 0.0){
      // Mask shaping: power & strength & mix
      float shaped = pow(clamp(maskRaw, 0.0, 1.0), gPower) * gStrength * oMix;
      shaped = clamp(shaped, 0.0, 1.0);

      // Ziel-Parameter bestimmen (fallback auf global)
      float tLight = (hasL > 0.5) ? oLight : lightness;
      float tSatu  = (hasS > 0.5) ? oSatu  : saturation;
      vec4 tGlass  = (hasG > 0.5) ? uGlowGlass : glassColor;

      // Parametrischer Mix zwischen globalen Parametern und Zielwerten.
      float effLight = mix(lightness, tLight, shaped);
      float effSatu  = mix(saturation, tSatu, shaped);
      vec4  effGlass = mix(glassColor, tGlass, shaped);

      // Optionaler lokaler Zusatz-Blur über dem globalen Blur
      float extraSigma = 0.0;
      if (hasB > 0.5) {
        // oBlur ist "Ziel-Gesamtblur": ziehe den globalen ab → Extra
        extraSigma = max(oBlur - uGlobalBlurSigma, 0.0); // uGlobalBlurSigma = Basis-Sigma (Host setzen!)
      }

      // Ausgangs-Refraktfarbe ggf. lokal stärker blur’en
      vec4 refractLocal = refractColorBase;
      if (extraSigma > 0.01){
        refractLocal = gaussianApprox9(backgroundTexture, uvBase, extraSigma, uSize);
      }

      // Re-Coloring mit effektiven Parametern
      vec4 coloredLocal = applyGlassColor(refractLocal, effGlass);
      coloredLocal.rgb += lighting;
      coloredLocal.rgb  = applySaturationLightness(coloredLocal.rgb, effSatu, effLight);

      // Zusatz-Tint gemäß tintMode (white / background / fixed uGlowColor)
      vec3 tint;
      if (gTintMode < 0.5) {
        tint = vec3(1.0);
      } else if (gTintMode < 1.5) {
        tint = getHighlightColor(backgroundColor.rgb, 1.0);
      } else {
        tint = uGlowColor.rgb;
      }
      vec4 tintGlass = vec4(tint, clamp(uGlowColor.a, 0.0, 1.0) * shaped);
      coloredLocal = applyGlassColor(coloredLocal, tintGlass);

      // In die Basisausgabe einblenden
      outColor = mix(coloredBase, coloredLocal, shaped);
    }
  }

  // Rand-Alpha leicht anheben
  RimMasks rm = rimMasksInner(sd, rimWidthPx, rimSharpness);
  float edgeAlphaGain = mix(0.20, 0.45, clamp(rimWidthPx/64.0, 0.0, 1.0));
  float mixA = clamp(max(foregroundAlpha, rm.band * edgeAlphaGain), 0.0, 1.0);

  return mix(backgroundColor, outColor, mixA);
}

// Optional: Normalen-Debug
vec4 debugNormals(vec4 originalColor, vec3 normal, bool enableDebug) {
  if (enableDebug) {
    vec3 normalColor = (normal + 1.0) * 0.5;
    return mix(originalColor, vec4(normalColor, 1.0), 0.99);
  }
  return originalColor;
}

#endif // LIQUID_GLASS_SHARED_GLSL
