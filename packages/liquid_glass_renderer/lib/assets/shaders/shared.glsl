// ======================== shared.glsl (LIBRARY ONLY) ========================
#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

// ---------- Config ----------
#ifndef TAU
#define TAU 6.28318530718
#endif
#ifndef SAMPLER_CLAMP
#define SAMPLER_CLAMP 1   // 1 = clamp 0..1, 0 = mirror
#endif
#ifndef MAX_VSAMPLES
#define MAX_VSAMPLES 64
#endif

// ---------- Small utils ----------
float hash12(vec2 p){
  vec3 q = fract(vec3(p.xyx) * 0.1031);
  q += dot(q, q.yzx + 33.33);
  return fract((q.x + q.y) * q.z);
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

// ---------- tiling helpers ----------
float mirror1(float x){ float m = mod(x, 2.0); return (m <= 1.0) ? m : 2.0 - m; }
vec2  mirror01(vec2 uv){ return vec2(mirror1(uv.x), mirror1(uv.y)); }

#if SAMPLER_CLAMP
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, clamp(uv, vec2(0.0), vec2(1.0))); }
#else
  vec4 texScreen(sampler2D t, vec2 uv){ return texture(t, mirror01(uv)); }
#endif

// ---------- Impeller-Identisches Tiling (für Gaussian 1D) ----------
// HINWEIS: Die hier verwendeten Uniforms (u_size_x, u_size_y, u_dir_*, u_samples, …)
// müssen im Host-Shader (liquid_glass.frag) VOR dem include deklariert sein.
vec2 tile_uv_mode(vec2 uv, vec2 size, float mode){
  if (mode < 0.5) {
    // clamp-with-epsilon wie Impeller
    vec2 eps = 0.5 / size;
    return clamp(uv, eps, vec2(1.0) - eps);
  } else if (mode < 1.5) {
    return fract(uv);
  } else if (mode < 2.5) {
    vec2 m = mod(uv, 2.0);
    return mix(m, 2.0 - m, step(1.0, m));
  } else {
    // decal: uv bleibt roh, OOB wird separat 0
    return uv;
  }
}
vec4 sample_uv_mode(sampler2D tex, vec2 uv, vec2 size, float mode){
  if (mode >= 2.5) {
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
      return vec4(0.0);
    }
  }
  return texture(tex, tile_uv_mode(uv, size, mode));
}

// ────────────────────────────────────────────────────────────────────────────
//  EXAKTER Gaussian 1D nach Impeller (liest Impeller-Uniforms)
// ────────────────────────────────────────────────────────────────────────────
vec4 applyGaussian1D_Impeller(sampler2D tex, vec2 baseUV){
  // im Host deklariert:
  //   uniform float u_size_x, u_size_y;
  //   uniform float u_dir_x,  u_dir_y;
  //   uniform float u_sample_count, u_tile_mode;
  //   uniform vec4  u_samples[50];

  vec2 pixel    = vec2(1.0 / uSize.x, 1.0 / uSize.y);
  vec2 step_vec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);

  vec4 sum  = vec4(0.0);
  float wsum = 0.0;

  float nRaw = u_sample_count;
  if ((nRaw == nRaw) && (nRaw > 0.5)) {
    int nS = int(nRaw + 0.5);
    for (int i = 0; i < 50; ++i) {
      if (i >= nS) break;
      float t = u_samples[i].x;  // Offset in Pixeln entlang der Achse
      float w = u_samples[i].z;  // Gewicht
      if (!(w > 1e-6)) continue;

      vec2 uvOff = baseUV + step_vec * t;
      vec4 s = sample_uv_mode(tex, uvOff, uSize, u_tile_mode);
      sum  += w * s;
      wsum += w;
    }
  }

  if (wsum > 1e-6) return sum / wsum;

  // Fallback (clamp with epsilon)
  vec2 eps = vec2(0.5 / uSize.x, 0.5 / uSize.y);
  return texture(tex, clamp(baseUV, eps, vec2(1.0) - eps));
}

// ────────────────────────────────────────────────────────────────────────────
// Lighting / Color (seine Versionen)
// ────────────────────────────────────────────────────────────────────────────

// Determine highlight color with gradual transition from colored to white
vec3 getHighlightColor(vec3 backgroundColor, float targetBrightness) {
  float luminance = dot(backgroundColor, vec3(0.299, 0.587, 0.114));

  float maxC = max(max(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float minC = min(min(backgroundColor.r, backgroundColor.g), backgroundColor.b);
  float saturation = maxC > 0.0 ? (maxC - minC) / maxC : 0.0;

  vec3 coloredHighlight = vec3(targetBrightness);
  if (luminance > 0.001) {
    vec3 normalizedBackground = backgroundColor / luminance;
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

// Inverted dispersion for „red refracts more than blue“
float calculateDispersiveIndex(float baseIndex, float chromaticAberration, float wavelength) {
  if (chromaticAberration < 0.001) return baseIndex;
  float wavelengthSq   = wavelength * wavelength;
  float wavelengthQuad = wavelengthSq * wavelengthSq;
  float B = chromaticAberration * 0.08  * (baseIndex - 1.0);
  float C = chromaticAberration * 0.003 * (baseIndex - 1.0);
  return baseIndex - B / wavelengthSq - C / wavelengthQuad;
}

// Seine Lighting (mit vec2 lightDirection und rationalem Rim-Falloff)
vec3 calculateLighting(
  vec2 uv, vec3 normal, float sd, float thickness, float height,
  vec2 lightDirection, float lightIntensity, float ambientStrength,
  vec3 backgroundColor
){
  float normalizedHeight = (thickness > 0.0) ? (height / thickness) : 0.0;
  float shape = smoothstep(0.0, 0.9, 1.0 - normalizedHeight);
  if (shape < 0.01) return vec3(0.0);

  float thicknessFactor = smoothstep(5.0, 7.0, thickness);
  if (thicknessFactor < 0.01) return vec3(0.0);

  float rimWidth  = 1.5;
  float k = 0.89;
  float x = sd / rimWidth;
  float rimFactor = 1.0 / (1.0 + k * x * x);
  if (rimFactor < 0.01 || lightIntensity < 0.01) return vec3(0.0);

  vec2 L = lightDirection;
  vec2 nxy = normalize(normal.xy);

  float mainL = max(0.0, dot(nxy,  L));
  float oppL  = max(0.0, dot(nxy, -L));
  float total = mainL + oppL * 0.8;

  vec3 hl            = getHighlightColor(backgroundColor, 0.7);
  vec3 directionalRim = hl * (total * total) * lightIntensity * 2.0;
  vec3 ambientRim     = getHighlightColor(backgroundColor, 0.4) * ambientStrength;

  return (directionalRim + ambientRim) * rimFactor * thicknessFactor * shape;
}

// ────────────────────────────────────────────────────────────────────────────
// Refraction + Chromatic Aberration (Variante A) mit Impeller-Blur
// ────────────────────────────────────────────────────────────────────────────
vec4 calculateRefraction(
  vec2 screenUV, vec3 normal, float height, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec2 sizePx, sampler2D backgroundTexture,
  out vec2 refractionDisplacement
){
  // 1) Refraktion -> Displacement
  vec3 incident = vec3(0.0, 0.0, -1.0);
  float n       = max(refractiveIndex, 1.0001);
  vec3 refr     = refract(incident, normal, 1.0 / n);
  float baseH   = thickness * 8.0;
  float refrL   = (height + baseH) / max(0.001, abs(refr.z));

  vec2 dispPx = refr.xy * refrL;                 // in Pixeln
  refractionDisplacement = dispPx / sizePx;      // in UV
  vec2 uvBase = screenUV + refractionDisplacement;

  // 2) Einmal Gaussian (G + A)
  vec4 gS = applyGaussian1D_Impeller(backgroundTexture, uvBase);

  // 3) CA: streng skalierbar, und komplett aus bei sehr kleinen Werten
  float ca = max(chromaticAberration, 0.0);
  if (ca < 1e-4) {
    // exakte "keine CA" Ausgabe
    return gS;
  }

  // Richtung in UV; wenn Disp sehr klein -> CA verschwindet automatisch
  float dispLenPx = length(dispPx);
  vec2 dirUV = normalize(refractionDisplacement + 1e-12);

  // Offsetgröße rein proportional zu CA und Displänge
  // Skala anpassen: 1.5 ist ein guter Start; clamp gegen Ausreißer
  float caPixels = clamp(dispLenPx * (1.5 * ca), 0.0, 6.0);
  // in UV umrechnen (Nutzung der kürzeren Bildkante verhindert Übertreibung)
  float shortSide = max(1.0, min(sizePx.x, sizePx.y));
  vec2  caUV      = dirUV * (caPixels / shortSide);

  // R vor / B zurück, günstige 3-Tap-Glättung
  vec2 uvR = uvBase + caUV;
  vec2 uvB = uvBase - caUV;

  vec3 r0 = texture(backgroundTexture, uvR).rgb;
  vec3 r1 = texture(backgroundTexture, uvR - 0.5*caUV).rgb;
  vec3 r2 = texture(backgroundTexture, uvR + 0.5*caUV).rgb;
  float r = (r0.r + r1.r + r2.r) / 3.0;

  vec3 b0 = texture(backgroundTexture, uvB).rgb;
  vec3 b1 = texture(backgroundTexture, uvB - 0.5*caUV).rgb;
  vec3 b2 = texture(backgroundTexture, uvB + 0.5*caUV).rgb;
  float b = (b0.b + b1.b + b2.b) / 3.0;

  // 4) R/B nur anteilig beimischen → bei ca=0 exakt gS.rgb
  float mixAmt = clamp(ca, 0.0, 1.0);
  float outR = mix(gS.r, r, mixAmt);
  float outG = gS.g;    // Referenz (geblurter G)
  float outB = mix(gS.b, b, mixAmt);

  return vec4(outR, outG, outB, gS.a);
}



// Apply saturation and lightness adjustments to a color
vec3 applySaturationLightness(vec3 color, float saturation, float lightness){
  // Luminanz
  float luminance = dot(color, vec3(0.299, 0.587, 0.114));

  // Sättigung anwenden (1.0 = keine Änderung)
  vec3 saturatedColor = mix(vec3(luminance), color, saturation);

  // Lightness anwenden (1.0 = keine Änderung)
  vec3 adjustedColor;
  if (lightness > 1.0) {
    // aufhellen: Richtung Weiß
    adjustedColor = mix(saturatedColor, vec3(1.0), lightness - 1.0);
  } else {
    // abdunkeln: Richtung Schwarz
    adjustedColor = saturatedColor * lightness;
  }

  return clamp(adjustedColor, 0.0, 1.0);
}

// Apply glass color tinting to the liquid color
vec4 applyGlassColor(vec4 liquidColor, vec4 glassColor){
  vec4 finalColor = liquidColor;

  if (glassColor.a > 0.0) {
    float glassLuminance = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));

    if (glassLuminance < 0.5) {
      // dunkle Tönung -> Multiplizieren
      vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
      finalColor.rgb = mix(liquidColor.rgb, darkened, glassColor.a);
    } else {
      // helle Tönung -> Screen
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
// PUBLIC API – ohne gaussian/kawase Parameter, mit vec2 lightDirection
// ────────────────────────────────────────────────────────────────────────────
vec4 renderLiquidGlass(
  vec2 screenUV, vec2 p, vec2 uSizePx,
  float sd, float thickness,
  float refractiveIndex, float chromaticAberration,
  vec4  glassColor, vec2 lightDirection, float lightIntensity, float ambientStrength,
  sampler2D backgroundTexture, vec3 normal, float foregroundAlpha,
  float saturation, float lightness
){
  if (foregroundAlpha < 0.001) {
    return texScreen(backgroundTexture, screenUV);
  }
  if (thickness < 0.01) {
    return texScreen(backgroundTexture, screenUV);
  }

  float height = getHeight(sd, thickness);

  vec2 refractionDisplacement;
  vec4 refractColor = calculateRefraction(
    screenUV, normal, height, thickness, refractiveIndex, chromaticAberration,
    uSizePx, backgroundTexture, refractionDisplacement
  );

  vec4 backgroundColor = texScreen(backgroundTexture, screenUV);
  vec3 lighting = calculateLighting(
    screenUV, normal, sd, thickness, height,
    lightDirection, lightIntensity, ambientStrength,
    backgroundColor.rgb
  );

  // seine Tints/Adjustments
  vec4 finalColor = applyGlassColor(refractColor, glassColor);
  finalColor.rgb += lighting;
  finalColor.rgb  = applySaturationLightness(finalColor.rgb, saturation, lightness);

  return mix(backgroundColor, finalColor, foregroundAlpha);
}

#endif // LIQUID_GLASS_SHARED_GLSL
