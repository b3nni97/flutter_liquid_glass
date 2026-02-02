#ifndef LIQUID_GLASS_SHARED_GLSL
#define LIQUID_GLASS_SHARED_GLSL 1

#ifndef TAU
#define TAU 6.28318530718
#endif

#ifndef LG_CA_VIS_THRESHOLD
#define LG_CA_VIS_THRESHOLD 1e-3
#endif

#ifndef LG_CA_OPACITY
#define LG_CA_OPACITY 0.15
#endif

#ifndef LG_CA_LIGHTNESS_BOOST
#define LG_CA_LIGHTNESS_BOOST 2.0
#endif

#ifndef LG_CA_SATURATION_BOOST
#define LG_CA_SATURATION_BOOST 1.5
#endif

#ifndef LG_EPS
#define LG_EPS 1e-8
#endif

#ifndef AGSL_DISPERSION_SCALE
#define AGSL_DISPERSION_SCALE 0.4
#endif

#ifndef LG_CA_NEW_GAIN
#define LG_CA_NEW_GAIN 1.0
#endif

#ifndef LG_REFRACT_AA_RADIUS_PX
#define LG_REFRACT_AA_RADIUS_PX 0.75
#endif

#ifndef LG_REFRACT_AA_STRENGTH
#define LG_REFRACT_AA_STRENGTH 0.85
#endif

#ifndef LG_CA_AA_TAPS
#define LG_CA_AA_TAPS 8
#endif

#ifndef LG_CA_AA_RADIUS_PX
#define LG_CA_AA_RADIUS_PX 1.15
#endif

#ifndef LG_CA_AA_STRENGTH
#define LG_CA_AA_STRENGTH 0.9
#endif

#ifndef LG_CA_EDGE_FEATHER_PX
#define LG_CA_EDGE_FEATHER_PX 1.5
#endif

#ifndef GLOW_OWNER_FEATHER_PX
#define GLOW_OWNER_FEATHER_PX 1.6
#endif

#define u_dir_x        (uBlurHeader.x)
#define u_dir_y        (uBlurHeader.y)
#define u_sample_count (uBlurHeader.z)
#define u_tile_mode    (uBlurHeader.w)

struct RimMasks {
    float band;
    float core;
};

// Generates a pseudo-random float based on a 2D position.
float _hash12(vec2 position) {
    vec3 q = fract(vec3(position.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Generates a high-frequency hash for refraction jitter.
float _hashRefraction(vec2 position) {
    return fract(sin(dot(position, vec2(12.9898, 78.233))) * 43758.5453);
}

// Normalizes a vector, handling zero-length cases to avoid NaN.
vec2 _safeNormalize(vec2 v) {
    float lengthSquared = max(dot(v, v), LG_EPS);
    return v * inversesqrt(lengthSquared);
}

// Converts pixel coordinates to UV coordinates, handling OpenGL target flipping.
vec2 _uvFromPx(vec2 pixel, vec2 sizePixels) {
    vec2 uv = pixel / max(sizePixels, vec2(1.0));
    #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
    #endif
    return uv;
}

// Converts UV coordinates to pixel coordinates, handling OpenGL target flipping.
vec2 _pxFromUv(vec2 uv, vec2 sizePixels) {
    #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
    #endif
    return uv * sizePixels;
}

// Samples a texture with standard clamping to [0, 1].
vec4 _sampleTexture(sampler2D t, vec2 uv) {
    return texture(t, clamp(uv, vec2(0.0), vec2(1.0)));
}

// Simulates Nearest-Neighbor sampling for pixelated aesthetic.
vec4 _sampleNearest(sampler2D tex, vec2 uv, vec2 texSize) {
    vec2 pixel = uv * texSize;
    vec2 nearestPixel = floor(pixel) + 0.5;
    vec2 nearestUV = nearestPixel / texSize;
    return texture(tex, clamp(nearestUV, vec2(0.0), vec2(1.0)));
}

// Decodes shape geometry data from the uniform array.
void _readShapeData(int shapeIndex, out float type, out vec2 center, out vec2 size, out float cornerRadius) {
    int baseIndex = shapeIndex * 7;
    type = uShapeData[baseIndex + 0];
    center = vec2(uShapeData[baseIndex + 1], uShapeData[baseIndex + 2]);
    size = vec2(uShapeData[baseIndex + 3], uShapeData[baseIndex + 4]);
    cornerRadius = uShapeData[baseIndex + 5];
}

// Computes the signed distance for a rounded rectangle.
float _sdRoundedRect(vec2 position, vec2 center, vec2 size, float radius) {
    vec2 halfSize = max(size * 0.5, vec2(0.0));
    float clampedRadius = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    vec2 q = abs(position - center) - (halfSize - vec2(clampedRadius));
    return length(max(q, 0.0)) - clampedRadius + min(max(q.x, q.y), 0.0);
}

// Computes an approximate signed distance for an ellipse.
float _sdEllipse(vec2 position, vec2 center, vec2 size) {
    vec2 ab = max(size * 0.5, vec2(1e-4));
    vec2 d = (position - center) / ab;
    float k = length(d) - 1.0;
    return k * min(ab.x, ab.y);
}

// Computes the signed distance to a specific shape index.
float _sdShapeAt(int shapeIndex, vec2 position) {
    float type, radius;
    vec2 center, size;
    _readShapeData(shapeIndex, type, center, size, radius);
    
    if (type == 2.0) {
        return _sdEllipse(position, center, size);
    }
    return _sdRoundedRect(position, center, size, radius);
}

// Projects a point from SDF space to Screen Pixel space using the inverse transform.
vec2 _projectSdfToScreen(vec2 positionSdf) {
    mat4 inverseTransform = inverse(uTransform);
    vec4 positionScreen = inverseTransform * vec4(positionSdf, 0.0, 1.0);
    float w = max(positionScreen.w, 1e-6);
    return positionScreen.xy / w;
}

// ERSETZEN: _blurJitterRefraction
// Optimierung: Nur 1 Sample wenn Blur klein ist.
// LOGIK: Kein Half-Pixel-Offset, damit Text/Child scharf bleibt.
vec4 _blurJitterRefraction(sampler2D tex, vec2 uv, float blurAmount, vec2 sizePixels, vec2 seed) {
    // 1. Ultra-Fast Path: Fast kein Blur -> Gestochen scharf (Linear Sampling)
    if (blurAmount <= 0.1) {
        return _sampleTexture(tex, uv); 
    }
    
    vec2 pixelSize = 1.0 / sizePixels;
    
    // 2. Fast Path: Moderater Blur (< 2.0px) -> 1 Jitter Sample
    if (blurAmount < 1.0) {
        float r = _hashRefraction(seed) - 0.5; // -0.5 bis 0.5
        vec2 jitter = vec2(r, -r) * blurAmount * pixelSize;
        // Hier nutzen wir normales Sampling ohne Extra-Offset für Lesbarkeit
        return _sampleTexture(tex, uv + jitter);
    }
    
    // 3. High Quality Path: Starker Blur -> 4 Samples (Frosted Look)
    // Hier nutzen wir _sampleNearest für den "Frosted" Noise-Look bei starkem Blur,
    // oder _sampleTexture wenn du es "cremig" willst. Ich lasse es auf Nearest für Performance/Look.
    float spread = blurAmount * 0.7; 
    
    vec4 color = _sampleNearest(tex, uv + vec2(-spread, -spread) * pixelSize, sizePixels);
    color += _sampleNearest(tex, uv + vec2( spread, -spread) * pixelSize, sizePixels);
    color += _sampleNearest(tex, uv + vec2(-spread,  spread) * pixelSize, sizePixels);
    color += _sampleNearest(tex, uv + vec2( spread,  spread) * pixelSize, sizePixels);
    
    return color * 0.25;
}
// Applies a 1D Gaussian blur based on uniform samples.
vec4 _applyGaussianBlur(sampler2D tex, vec2 baseUV) {
    vec2 pixel = vec2(1.0 / uSize.x, 1.0 / uSize.y);
    vec2 stepVec = vec2(u_dir_x * pixel.x, u_dir_y * pixel.y);
    
    float sampleCountRaw = u_sample_count;
    
    // Safety clamp Epsilon (0.5px vom Rand wegbleiben)
    vec2 eps = vec2(0.5) / max(uSize, vec2(1.0));
    vec2 minUV = eps;
    vec2 maxUV = vec2(1.0) - eps;

    if (sampleCountRaw <= 0.5) {
        return texture(tex, clamp(baseUV, minUV, maxUV));
    }

    vec4 sum = vec4(0.0);
    float weightSum = 0.0;
    int sampleCount = int(sampleCountRaw + 0.5);

    // PERFORMANCE BOOST: Keine IFs mehr im Loop!
    for (int i = 0; i < 50; ++i) {
        if (i >= sampleCount) break;
        
        float t = u_samples[i].x;
        float weight = u_samples[i].z;
        
        if (weight <= 1e-6) continue;

        vec2 offsetUV = baseUV + stepVec * t;
        
        // Simples, schnelles Clamping
        vec2 clampedUV = clamp(offsetUV, minUV, maxUV);
        
        sum += weight * texture(tex, clampedUV);
        weightSum += weight;
    }

    if (weightSum > 1e-6) {
        return sum / weightSum;
    }
    return texture(tex, clamp(baseUV, minUV, maxUV));
}

// Approximates a Gaussian blur using a 9-tap kernel for glow effects.
vec4 _blurApprox9(sampler2D tex, vec2 uv, float sigmaPixels, vec2 sizePixels) {
    if (sigmaPixels <= 0.01) return _sampleTexture(tex, uv);
    
    vec2 px = 1.0 / sizePixels;
    float spread = clamp(sigmaPixels, 0.0, 6.0);
    float weightCenter = 0.227027;
    float weightNear = 0.194594;
    float weightFar = 0.121621;
    
    vec4 color = _sampleTexture(tex, uv) * weightCenter;
    color += _sampleTexture(tex, uv + vec2( px.x,  0.0)) * weightNear;
    color += _sampleTexture(tex, uv + vec2(-px.x,  0.0)) * weightNear;
    color += _sampleTexture(tex, uv + vec2( 0.0,  px.y)) * weightNear;
    color += _sampleTexture(tex, uv + vec2( 0.0, -px.y)) * weightNear;
    color += _sampleTexture(tex, uv + vec2( px.x,  px.y)) * weightFar;
    color += _sampleTexture(tex, uv + vec2(-px.x,  px.y)) * weightFar;
    color += _sampleTexture(tex, uv + vec2( px.x, -px.y)) * weightFar;
    color += _sampleTexture(tex, uv + vec2(-px.x, -px.y)) * weightFar;
    
    float t = clamp((spread - 1.0) / 5.0, 0.0, 1.0);
    return mix(_sampleTexture(tex, uv), color, t);
}

// Samples texture with multi-tap anti-aliasing for chromatic aberration.
vec4 _sampleAberrationAA(sampler2D tex, vec2 uvCenter, vec2 aberrationUV, vec2 sizePixels) {
    float lengthPixels = length(aberrationUV * sizePixels);
    if (lengthPixels < 1e-4) {
        return _sampleTexture(tex, uvCenter);
    }
    
    vec2 px = 1.0 / sizePixels;
    vec2 dir = normalize(aberrationUV + vec2(1e-6));
    float radiusPixels = float(LG_CA_AA_RADIUS_PX);
    float strength = clamp(float(LG_CA_AA_STRENGTH), 0.0, 1.0);
    
    vec2 offsetUV = dir * radiusPixels * px;
    
    vec4 c0 = _sampleTexture(tex, uvCenter);
    vec4 c1 = _sampleTexture(tex, uvCenter + offsetUV);
    vec4 c2 = _sampleTexture(tex, uvCenter - offsetUV);
    
    #if LG_CA_AA_TAPS == 2
    vec4 average = 0.5 * (c1 + c2);
    #else
    vec4 average = (c0 + c1 + c2) / 3.0;
    #endif
    
    return mix(c0, average, strength);
}

// Performs Rotated Grid Super Sampling (4 taps) along a direction.
vec4 _sampleRGSS4(sampler2D tex, vec2 uv, vec2 px, vec2 dir, float radiusPixels, float gain) {
    vec2 ortho = vec2(-dir.y, dir.x);
    vec2 o0 = vec2(0.5, 0.5);
    vec2 o1 = vec2(-0.5, 0.5);
    vec2 o2 = vec2(0.5, -0.5);
    vec2 o3 = vec2(-0.5, -0.5);
    
    vec2 a0 = (dir * (o0.x * gain) + ortho * o0.y) * radiusPixels;
    vec2 a1 = (dir * (o1.x * gain) + ortho * o1.y) * radiusPixels;
    vec2 a2 = (dir * (o2.x * gain) + ortho * o2.y) * radiusPixels;
    vec2 a3 = (dir * (o3.x * gain) + ortho * o3.y) * radiusPixels;
    
    vec4 c0 = _applyGaussianBlur(tex, uv + a0 * px);
    vec4 c1 = _applyGaussianBlur(tex, uv + a1 * px);
    vec4 c2 = _applyGaussianBlur(tex, uv + a2 * px);
    vec4 c3 = _applyGaussianBlur(tex, uv + a3 * px);
    
    return (c0 + c1 + c2 + c3) * 0.25;
}

// Applies anti-aliasing to refracted samples using RGSS4.
vec4 _sampleRefractionAA(sampler2D tex, vec2 uv, vec2 sizePixels, vec2 directionUV, float radiusPixels, float strength, float gain) {
    vec2 px = vec2(1.0 / sizePixels.x, 1.0 / sizePixels.y);
    vec2 dir = normalize(directionUV + vec2(1e-6));
    
    vec4 average = _sampleRGSS4(tex, uv, px, dir, radiusPixels, gain);
    vec4 base = _applyGaussianBlur(tex, uv);
    
    return mix(base, average, clamp(strength, 0.0, 1.0));
}

// Calculates a highlight color based on background luminance and saturation.
vec3 _computeAdaptiveHighlight(vec3 backgroundColor, float targetBrightness) {
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

    float luminanceFactor = smoothstep(0.0, 0.6, luminance);
    float saturationFactor = smoothstep(0.0, 0.4, saturation);
    float colorInfluence = luminanceFactor * saturationFactor;
    
    vec3 whiteHighlight = vec3(1.0 * targetBrightness);
    return mix(whiteHighlight, coloredHighlight, colorInfluence);
}

// Calculates the virtual height of the liquid at a given signed distance.
float _calculateLiquidHeight(float signedDistance, float thickness) {
    if (signedDistance >= 0.0 || thickness <= 0.0) return 0.0;
    if (signedDistance < -thickness) return thickness;
    
    float x = thickness + signedDistance;
    return sqrt(max(0.0, thickness * thickness - x * x));
}

// Generates masks for rim lighting logic based on signed distance derivatives.
RimMasks _calculateRimMasks(float signedDistance, float rimWidthPixels, float rimSharpness) {
    vec2 gradient = vec2(dFdx(signedDistance), dFdy(signedDistance));
    float gradientMagnitude = max(length(gradient), 1e-6);
    float widthSdf = max(rimWidthPixels, 0.0) * gradientMagnitude;
    
    float edge01 = step(signedDistance, 0.0) * smoothstep(-widthSdf, 0.0, signedDistance);
    float gamma = max(rimSharpness, 1e-3);
    
    float band = pow(edge01, 1.0 / gamma);
    float coreExponent = mix(3.0, 1.1, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    float core = pow(edge01, coreExponent / gamma);
    
    RimMasks masks;
    masks.band = band;
    masks.core = core;
    return masks;
}

// Computes Fresnel reflectance using Schlick's approximation.
float _fresnelSchlick(float cosTheta, float f0) {
    return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
}

// Blends the liquid color with the glass tint.
vec4 _blendGlassTint(vec4 liquidColor, vec4 glassColor) {
    vec4 finalColor = liquidColor;
    
    if (glassColor.a > 0.0) {
        float glassLuminance = dot(glassColor.rgb, vec3(0.299, 0.587, 0.114));
        if (glassLuminance < 0.5) {
            vec3 darkened = liquidColor.rgb * (glassColor.rgb * 2.0);
            finalColor.rgb = mix(liquidColor.rgb, darkened, glassColor.a);
        } else {
            vec3 invLiquid = vec3(1.0) - liquidColor.rgb;
            vec3 invGlass = vec3(1.0) - glassColor.rgb;
            vec3 screened = vec3(1.0) - (invLiquid * invGlass);
            finalColor.rgb = mix(liquidColor.rgb, screened, glassColor.a);
        }
        finalColor.a = liquidColor.a;
    }
    
    return finalColor;
}

// Applies saturation and lightness adjustments to a color.
vec3 _adjustColorBalance(vec3 color, float saturation, float lightness) {
    float luminance = dot(color, vec3(0.299, 0.587, 0.114));
    vec3 saturatedColor = mix(vec3(luminance), color, saturation);
    
    vec3 adjustedColor = (lightness > 1.0)
        ? mix(saturatedColor, vec3(1.0), lightness - 1.0)
        : saturatedColor * lightness;
        
    return clamp(adjustedColor, 0.0, 1.0);
}

// Applies a white fringe effect to the edges of the shape, adjusting for saturation and lightness.
vec3 _applyRimHighlight(
    vec3 baseColor, vec3 normal, float signedDistance,
    float rimWidthPixels, float rimSharpness,
    float saturation, float lightness, vec4 glassColor
) {
    RimMasks masks = _calculateRimMasks(signedDistance, rimWidthPixels, rimSharpness);
    float cosNv = clamp(abs(normal.z), 0.0, 1.0);
    float fresnel = _fresnelSchlick(cosNv, 0.04);
    
    float bandGain = mix(0.25, 0.65, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    float coreGain = mix(0.15, 0.40, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    
    float amount = masks.band * bandGain + masks.core * coreGain;
    amount *= fresnel;
    
    vec4 rimColor = _blendGlassTint(vec4(1.0), glassColor);
    rimColor.rgb = _adjustColorBalance(rimColor.rgb, saturation, lightness);
    
    return mix(baseColor, rimColor.rgb, clamp(amount, 0.0, 1.0));
}

// Computes anti-aliased coverage for the shape edge.
float _computeCoverageAA(float signedDistance) {
    float width = fwidth(signedDistance);
    return smoothstep(-width, width, -signedDistance);
}

// Blends two colors using the Hard Light blend mode.
vec3 _blendHardLight(vec3 base, vec3 blend) {
    vec3 t1 = 2.0 * base * blend;
    vec3 t2 = 1.0 - 2.0 * (1.0 - base) * (1.0 - blend);
    vec3 selection = step(0.5, blend);
    return mix(t1, t2, selection);
}

// ERSETZEN: _resolveDispersion
// Optimierung: "Simplified Real Sampling" mit "Half-Pixel AA" für Background.
vec3 _resolveDispersion(
    vec2 uvBase,
    vec2 childUVBase,
    vec2 refractionDisplacement,
    vec2 sizePixels,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    int shapeIndex,
    float aberrationStrength,
    vec4 baseColor, 
    float saturation,
    float lightness,
    vec4 glassColor
) {
    // --- Berechnung der Koordinaten (Identisch) ---
    float type, radius;
    vec2 centerSdf, sizeSdf;
    _readShapeData(shapeIndex, type, centerSdf, sizeSdf, radius);
    
    vec2 centerPx = _projectSdfToScreen(centerSdf);
    vec2 centerUV = _uvFromPx(centerPx, sizePixels);
    
    vec2 col0 = uTransform[0].xy;
    vec2 col1 = uTransform[1].xy;
    float scaleX = max(length(col0), 1e-6);
    float scaleY = max(length(col1), 1e-6);
    
    float widthScreen = sizeSdf.x / scaleX;
    float heightScreen = sizeSdf.y / scaleY;
    float minDimensionScreen = min(widthScreen, heightScreen);
    
    vec2 distUV = uvBase - centerUV;
    float dispersion = aberrationStrength * AGSL_DISPERSION_SCALE;
    vec2 minDimOverSize = vec2(minDimensionScreen / sizePixels.x, minDimensionScreen / sizePixels.y);
    vec2 distCubed = distUV * distUV * distUV;
    
    float distortMagnitude = length(refractionDisplacement);
    float boost = 1.0 + (distortMagnitude * 60.0);
    vec2 aberrationUV = (dispersion * distCubed * minDimOverSize) * boost;
    
    // --- OPTIMIERUNG: Half-Pixel Trick ---
    // Wir berechnen einen halben Pixel Offset.
    // Das zwingt die GPU, beim Samplen des Hintergrunds 4 Pixel zu mischen -> Weicheres CA.
    vec2 halfPx = (1.0 / sizePixels) * 0.5;

    vec2 uvRed = uvBase - aberrationUV + halfPx;
    vec2 uvBlue = uvBase + aberrationUV + halfPx;
    
    // Background Samples (mit Half-Pixel Weichzeichner)
    vec4 sampleRedBg = _sampleTexture(backgroundTexture, uvRed);
    vec4 sampleBlueBg = _sampleTexture(backgroundTexture, uvBlue);
    
    // Child Samples (OHNE Half-Pixel, damit Text lesbar bleibt, falls er hier auftaucht)
    vec4 sampleRedChild = _sampleTexture(childTexture, childUVBase + refractionDisplacement - aberrationUV);
    vec4 sampleBlueChild = _sampleTexture(childTexture, childUVBase + refractionDisplacement + aberrationUV);
    vec4 sampleGreenChild = _sampleTexture(childTexture, childUVBase + refractionDisplacement); 

    // --- Ab hier Standard Logik ---
    
    sampleRedBg = _blendGlassTint(sampleRedBg, glassColor);
    sampleRedBg.rgb = _adjustColorBalance(sampleRedBg.rgb, saturation, lightness);
    
    sampleBlueBg = _blendGlassTint(sampleBlueBg, glassColor);
    sampleBlueBg.rgb = _adjustColorBalance(sampleBlueBg.rgb, saturation, lightness);

    if (sampleRedChild.a <= 0.001) sampleRedChild = sampleGreenChild;
    if (sampleBlueChild.a <= 0.001) sampleBlueChild = sampleGreenChild;

    vec3 colorRed = (sampleRedChild.a > 0.001) ? sampleRedChild.rgb / sampleRedChild.a : sampleRedChild.rgb;
    vec3 colorBlue = (sampleBlueChild.a > 0.001) ? sampleBlueChild.rgb / sampleBlueChild.a : sampleBlueChild.rgb;
    
    vec3 hardLightRed = _blendHardLight(sampleRedBg.rgb, colorRed);
    float redComponent = mix(sampleRedBg.r, hardLightRed.r, sampleRedChild.a);

    vec3 hardLightBlue = _blendHardLight(sampleBlueBg.rgb, colorBlue);
    float blueComponent = mix(sampleBlueBg.b, hardLightBlue.b, sampleBlueChild.a);

    float greenComponent = baseColor.g; 

    vec3 spectralNew = vec3(redComponent, greenComponent, blueComponent);
    vec3 diff = spectralNew - baseColor.rgb;
    diff *= float(LG_CA_LIGHTNESS_BOOST) * float(LG_CA_NEW_GAIN);
    
    float luminanceNew = dot(diff, vec3(0.299, 0.587, 0.114));
    return mix(vec3(luminanceNew), diff, float(LG_CA_SATURATION_BOOST));
}

// Calculates refraction, including anti-aliasing and chromatic aberration.
vec4 _calculateRefractionLayer(
    vec2 screenUV, vec3 normal, float signedDistance, float height, float thickness,
    float refractiveIndex, float chromaticAberration,
    vec2 sizePixels, sampler2D backgroundTexture,
    sampler2D childTexture,
    vec2 childUVBase,
    out vec2 outRefractionDisplacement,
    out vec4 outRawTexture,
    float rimWidthPixels, float rimSharpness,
    vec2 lightDirection, float lightIntensity,
    int shapeIndex,
    float saturation,
    float lightness,
    vec4 glassColor, vec3 lighting
) {
    vec3 incident = vec3(0.0, 0.0, -1.0);
    float n = max(refractiveIndex, 1.0001);
    vec3 refractVec = refract(incident, normal, 1.0 / n);
    
    float baseHeight = thickness * 8.0;
    float refractLength = (height + baseHeight) / max(0.001, abs(refractVec.z));
    
    RimMasks masks = _calculateRimMasks(signedDistance, rimWidthPixels, rimSharpness);
    vec2 nXy = _safeNormalize(normal.xy);
    float facing = abs(dot(nXy, lightDirection));
    float lightMask = pow(facing, 0.7) * clamp(lightIntensity, 0.0, 1.0);
    float boost = 1.0 + 0.4 * (masks.band * lightMask);
    
    vec2 displacementPixels = refractVec.xy * (refractLength * boost);
    outRefractionDisplacement = displacementPixels / sizePixels;
    
    vec2 uvBase = screenUV + outRefractionDisplacement;
    vec2 uvChild = childUVBase + outRefractionDisplacement;

    float stretch = length(fwidth(displacementPixels));
    float blurRadius = clamp(stretch * 0.45, 0.0, 6.0);

    // 1. Base Background Sample
    vec4 backgroundSample = _applyGaussianBlur(backgroundTexture, uvBase);
    
    outRawTexture = backgroundSample;

    backgroundSample = _blendGlassTint(backgroundSample, glassColor);
    backgroundSample.rgb += lighting;
    backgroundSample.rgb = _adjustColorBalance(backgroundSample.rgb, saturation, lightness);
    
    // 2. Child Sample & Blend (immer notwendig)
    vec4 childSample = _blurJitterRefraction(childTexture, uvChild, blurRadius, sizePixels, uvChild);
    
    vec3 childRGB = (childSample.a > 0.001) ? childSample.rgb / childSample.a : childSample.rgb;
    vec3 blended = _blendHardLight(backgroundSample.rgb, childRGB);
    
    backgroundSample.rgb = mix(backgroundSample.rgb, blended, childSample.a);
    
    // -------------------------------------------------------------------------
    // PERFORMANCE OPTIMIZATION: Aggressive Early Exit
    // -------------------------------------------------------------------------
    float ca = max(chromaticAberration, 0.0);
    
    // Wenn CA sehr klein ist (< 0.5%), lohnt sich der teure Multi-Sample Aufwand nicht.
    // Wir geben einfach das bisher berechnete Ergebnis zurück.
    if (ca <= 0.005) {
        return vec4(clamp(backgroundSample.rgb, 0.0, 1.0), backgroundSample.a);
    }

    // -------------------------------------------------------------------------
    // High Quality Path (Chromatische Aberration & Extra AA)
    // -------------------------------------------------------------------------

    vec2 dirRefUV = displacementPixels / sizePixels;
    
    // Teures Extra-AA Sampling
    vec4 baseAA = _sampleRefractionAA(
        backgroundTexture, uvBase, sizePixels, dirRefUV,
        float(LG_REFRACT_AA_RADIUS_PX),
        float(LG_REFRACT_AA_STRENGTH),
        1.4 
    );
    
    baseAA = _blendGlassTint(baseAA, glassColor);
    baseAA.rgb += lighting;
    baseAA.rgb = _adjustColorBalance(baseAA.rgb, saturation, lightness);
    
    vec3 blendedAA = _blendHardLight(baseAA.rgb, childRGB);
    backgroundSample = vec4(mix(baseAA.rgb, blendedAA, childSample.a), baseAA.a);

    // Teure Dispersion Calculation
    vec3 diffNew = _resolveDispersion(
        uvBase, childUVBase, outRefractionDisplacement, sizePixels,
        backgroundTexture, childTexture, shapeIndex, ca, backgroundSample,
        saturation, lightness, glassColor
    );

    float caMixNew = clamp(float(LG_CA_OPACITY), 0.0, 1.0);
    float edgeAA = smoothstep(-float(LG_CA_EDGE_FEATHER_PX) * fwidth(signedDistance), 0.0, -signedDistance);
    caMixNew *= edgeAA;
    
    vec3 finalRGB = clamp(backgroundSample.rgb + diffNew * caMixNew, 0.0, 1.0);
    return vec4(finalRGB, backgroundSample.a);
}

// Calculates total lighting based on normal, rim effects, and ambient light.
vec3 _calculateTotalLighting(
    vec2 uv, vec3 normal, float signedDistance, float thickness, float height,
    vec2 lightDirection, float lightIntensity, float ambientStrength,
    vec3 backgroundColor, float rimWidthPixels, float rimSharpness
) {
    float thicknessFactor = smoothstep(5.0, 7.0, thickness);
    if (thicknessFactor < 0.01 || lightIntensity < 0.01) return vec3(0.0);
    
    RimMasks masks = _calculateRimMasks(signedDistance, rimWidthPixels, rimSharpness);
    vec2 nXy = _safeNormalize(normal.xy);
    
    float facing = abs(dot(nXy, lightDirection));
    float lightMask = pow(facing, 0.7);
    float rimMask = masks.band * lightMask;
    
    if (rimMask < 1e-3) return vec3(0.0);
    
    float mainLight = max(0.0, dot(nXy, lightDirection));
    float oppositeLight = max(0.0, dot(nXy, -lightDirection));
    float totalLight = mainLight + oppositeLight * 0.8;
    
    vec3 highlight = _computeAdaptiveHighlight(backgroundColor, 0.7);
    vec3 directionalRim = highlight * (totalLight * totalLight) * lightIntensity * 2.0;
    vec3 ambientRim = _computeAdaptiveHighlight(backgroundColor, 0.4) * ambientStrength;
    
    vec3 lighting = (directionalRim + ambientRim);
    float whitePull = 0.55;
    float coreGain = mix(0.16, 0.36, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    
    vec3 towardWhite = mix(lighting, vec3(1.0), whitePull);
    lighting = mix(lighting, towardWhite, masks.core * coreGain);
    
    return lighting * rimMask * thicknessFactor;
}

// Computes the mask for touch-based glow interactions.
float _computeTouchGlowMask(vec2 positionPixels, vec2 positionSdf, float insideOnly, float sdUnion, int shapeIndex) {
    float count = uTouchCount_f;
    if (count <= 0.5 || shapeIndex < 0) return 0.0;
    
    float outMask = 0.0;
    for (int i = 0; i < 8; ++i) {
        if (i >= int(count)) break;
        
        int owner = int(floor(uTouchOwners[i] + 0.5));
        int targetShape = (owner >= 0) ? owner : shapeIndex;
        
        float sdOwner = _sdShapeAt(targetShape, positionSdf);
        float widthAa = max(fwidth(sdOwner), 1e-6) * GLOW_OWNER_FEATHER_PX;
        float inShape = smoothstep(0.0, widthAa, -sdOwner);
        
        if (inShape <= 1e-5) continue;
        
        vec4 touchParams = uTouches[i];
        float dist = length(positionPixels - touchParams.xy);
        float inner = touchParams.z;
        float outer = touchParams.z + max(touchParams.w, 1e-3);
        float radial = smoothstep(outer, inner, dist);
        float strength = clamp(uTouchGlowStrengths[i], 0.0, 1.0);
        
        outMask = max(outMask, radial * inShape * strength);
    }
    return outMask;
}

// Applies dynamic glow effects based on touch input and overrides.
vec4 _applyInteractiveGlow(
    vec4 coloredBase,
    vec4 refractColorBase,
    vec2 screenUV,
    vec2 refractionDisplacement,
    vec2 childUVBase,
    vec2 position,
    float signedDistance,
    int shapeIndex,
    vec2 uSizePx,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    vec3 lighting,
    float lightness,
    float saturation,
    vec3 backgroundColor
) {
    if (shapeIndex < 0 || uTouchCount_f <= 0.5) return coloredBase;

    int baseIndex = shapeIndex * 4;
    
    vec4 data0 = uShapeGlowData[baseIndex + 0]; // RGB=Color, W=ColorAlpha
    vec4 data1 = uShapeGlowData[baseIndex + 1]; // X=Power, Y=Mix, Z=Blur, W=Inside
    vec4 data2 = uShapeGlowData[baseIndex + 2]; // X=Light, Y=Sat, Z=TintMode, W=Strength
    vec4 data3 = uShapeGlowData[baseIndex + 3]; // RGBA=GlowGlassOverride

    float glowStrength = data2.w;
    
    if (glowStrength <= 0.0001) {
        return coloredBase;
    }
    
    float glowInside = data1.w;
    float maskRaw = _computeTouchGlowMask(position, position, glowInside, signedDistance, shapeIndex);
    
    if (maskRaw <= 0.0) {
        return coloredBase;
    }
    
    float glowPower = max(data1.x, 0.0001);
    float glowMix = clamp(data1.y, 0.0, 1.0);
    
    float shaped = pow(clamp(maskRaw, 0.0, 1.0), glowPower) * glowStrength * glowMix;
    shaped = clamp(shaped, 0.0, 1.0);

    float tLight = data2.x;
    float tSat = data2.y;
    vec4 tGlass = data3;

    float effectiveLight = (tLight > -0.5) ? mix(lightness, tLight, shaped) : lightness;
    float effectiveSat = (tSat > -0.5)  ? mix(saturation, tSat, shaped) : saturation;
    vec4 effectiveGlass = mix(uGlassColor, tGlass, shaped);

    vec4 refractLocal = refractColorBase;
    float tBlur = data1.z;
    float extraSigma = (tBlur > -0.5) ? max(tBlur - uGlobalBlurSigma, 0.0) : 0.0;
    
    if (extraSigma > 0.01) {
        vec2 uvBase = screenUV + refractionDisplacement;
        refractLocal = _blurApprox9(backgroundTexture, uvBase, extraSigma, uSizePx);
        vec4 childColor = _sampleTexture(childTexture, childUVBase + refractionDisplacement);
        refractLocal = mix(refractLocal, childColor, childColor.a);
    }

    vec4 coloredLocal = _blendGlassTint(refractLocal, effectiveGlass);
    coloredLocal.rgb += lighting;
    coloredLocal.rgb = _adjustColorBalance(coloredLocal.rgb, effectiveSat, effectiveLight);

    float glowTintMode = data2.z;
    float colorAlpha = data0.w;

    vec3 tint;
    if (glowTintMode < 0.5) {
        tint = vec3(1.0);
    } else if (glowTintMode < 1.5) {
        tint = _computeAdaptiveHighlight(backgroundColor, 1.0);
    } else {
        tint = data0.rgb;
    }
    
    vec4 tintGlass = vec4(tint, shaped * colorAlpha); 
    coloredLocal = _blendGlassTint(coloredLocal, tintGlass);
    
    return mix(coloredBase, coloredLocal, shaped);
}

// Main rendering function for the Liquid Glass effect.
vec4 renderLiquidGlass(
    vec2 screenUV,
    vec2 childUVBase,
    vec2 position, vec2 uSizePx,
    float signedDistance, float thickness,
    float refractiveIndex, float chromaticAberration,
    vec4 glassColor, vec2 lightDirection, float lightIntensity, float ambientStrength,
    sampler2D backgroundTexture,
    sampler2D childTexture,
    vec3 normal, float foregroundAlpha,
    float saturation, float lightness, float rimWidthPixels, float rimSharpness,
    int shapeIndex
) {
    vec4 backgroundColor = _sampleTexture(backgroundTexture, screenUV);
    
    if (foregroundAlpha < 0.001 || thickness < 0.01) {
        return backgroundColor;
    }

    float height = _calculateLiquidHeight(signedDistance, thickness);
    
    vec3 lighting = _calculateTotalLighting(
        screenUV, normal, signedDistance, thickness, height,
        lightDirection, lightIntensity, ambientStrength,
        backgroundColor.rgb, rimWidthPixels, rimSharpness
    );

    vec2 refractionDisplacement;
    vec4 rawRefractionTexture;
    
    vec4 refractColorBase = _calculateRefractionLayer(
        screenUV, normal, signedDistance, height, thickness,
        refractiveIndex, chromaticAberration,
        uSizePx, backgroundTexture,
        childTexture, childUVBase,
        refractionDisplacement, rawRefractionTexture,
        rimWidthPixels, rimSharpness, lightDirection, lightIntensity,
        shapeIndex,
        saturation, lightness, glassColor, lighting
    );

    refractColorBase.rgb = _applyRimHighlight(
        refractColorBase.rgb, normal, signedDistance,
        rimWidthPixels, rimSharpness, saturation, lightness, glassColor
    );

    vec4 outColor = _applyInteractiveGlow(
        refractColorBase, rawRefractionTexture, screenUV, refractionDisplacement, childUVBase,
        position, signedDistance, shapeIndex, uSizePx, backgroundTexture, childTexture,
        lighting, lightness, saturation, backgroundColor.rgb
    );

    float coverage = _computeCoverageAA(signedDistance);
    float baseAlpha = foregroundAlpha * coverage;
    
    RimMasks masks = _calculateRimMasks(signedDistance, rimWidthPixels, rimSharpness);
    float edgeAlphaGain = mix(0.20, 0.45, clamp(rimWidthPixels / 64.0, 0.0, 1.0));
    float rimAlpha = masks.band * edgeAlphaGain;
    float mixAlpha = clamp(max(baseAlpha, rimAlpha), 0.0, 1.0);

    return mix(backgroundColor, outColor, mixAlpha);
}

#endif