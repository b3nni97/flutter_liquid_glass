// Copyright 2025, Tim Lehmann for whynotmake.it
//
// Alternative liquid glass shader with different normal calculation approach
// This demonstrates how the shared rendering pipeline makes it easy to create variants

#version 320 es
precision highp float;

#define DEBUG_NORMALS 0
#define DEBUG_BLUR_MATTE 0

#include <flutter/runtime_effect.glsl>

// ============================================================================
// Größen (Screen) und Foreground-Bounds
// ============================================================================
layout(location = 0)  uniform float uSizeW;
layout(location = 1)  uniform float uSizeH;
vec2 uSize = vec2(uSizeW, uSizeH);

layout(location = 2)  uniform float uForegroundSizeW;
layout(location = 3)  uniform float uForegroundSizeH;
vec2 uForegroundSize = vec2(uForegroundSizeW, uForegroundSizeH);

// ============================================================================
// Material-/Licht-/Physik-Parameter
// ============================================================================
layout(location = 4)  uniform float uChromaticAberration;

layout(location = 5)  uniform float uGlassColorR;
layout(location = 6)  uniform float uGlassColorG;
layout(location = 7)  uniform float uGlassColorB;
layout(location = 8)  uniform float uGlassColorA;
vec4 uGlassColor = vec4(uGlassColorR, uGlassColorG, uGlassColorB, uGlassColorA);

layout(location = 9)  uniform float uLightAngle;
layout(location = 10) uniform float uLightIntensity;
layout(location = 11) uniform float uAmbientStrength;
layout(location = 12) uniform float uThickness;
layout(location = 13) uniform float uRefractiveIndex;

layout(location = 14) uniform float uOffsetX;
layout(location = 15) uniform float uOffsetY;
vec2 uOffset = vec2(uOffsetX, uOffsetY);

// Farbanpassung
layout(location = 16) uniform float uSaturation;  // =1.0
layout(location = 17) uniform float uLightness;   // =1.0

// Legacy-Blur-Uniforms (werden von renderLiquidGlass ignoriert, API-kompatibel)
layout(location = 18) uniform float uGaussianBlur;
layout(location = 19) uniform float uKawaseSteps;

// ============================================================================
// Impeller-Blur Uniforms (EXAKT wie gaussian_1d_blur.frag erwartet)
// Diese Symbole werden von shared.glsl (applyGaussian1D_Impeller) verwendet!
// ============================================================================
layout(location = 20) uniform float u_size_x;        // device-px Breite
layout(location = 21) uniform float u_size_y;        // device-px Höhe
layout(location = 22) uniform float u_dir_x;         // 1,0=H  |  0,1=V
layout(location = 23) uniform float u_dir_y;
layout(location = 24) uniform float u_sample_count;  // Anzahl gepackter Samples
layout(location = 25) uniform float u_tile_mode;     // 0=clamp,1=repeat,2=mirror,3=decal
layout(location = 26) uniform vec4  u_samples[50];   // vec4(tPx, 0, w, 0)

// ============================================================================
// Texturen
// ============================================================================
uniform sampler2D uBackgroundTexture;
uniform sampler2D uForegroundTexture;
uniform sampler2D uForegroundBlurredTexture;

layout(location = 0) out vec4 fragColor;

// ============================================================================
// shared.glsl erst NACH den Uniforms inkludieren (wichtige Reihenfolge!)
// ============================================================================
#include "shared.glsl"

// ============================================================================
// Hilfsfunktionen (dein Arbitrary-Ansatz beibehalten)
// ============================================================================
float approximateSDF(float blurredAlpha, float thickness) {
    float normalizedDistance = smoothstep(0.0, 1.0, blurredAlpha);
    return -normalizedDistance * thickness;
}

vec2 findShapeCenter(vec2 currentUV) {
    vec2 texelSize = 2.0 / uForegroundSize;
    vec2 centerSum = vec2(0.0);
    float totalAlpha = 0.0;

    int sampleRadius = 10;
    for (int y = -sampleRadius; y <= sampleRadius; y++) {
        for (int x = -sampleRadius; x <= sampleRadius; x++) {
            vec2 sampleUV = currentUV + vec2(float(x), float(y)) * texelSize;
            if (sampleUV.x >= 0.0 && sampleUV.x <= 1.0 && sampleUV.y >= 0.0 && sampleUV.y <= 1.0) {
                float alpha = texture(uForegroundTexture, sampleUV).a;
                if (alpha > 0.1) {
                    centerSum += sampleUV * alpha;
                    totalAlpha += alpha;
                }
            }
        }
    }
    return (totalAlpha > 0.0) ? (centerSum / totalAlpha) : currentUV;
}

vec2 calculateGradient(sampler2D tex, vec2 uv, vec2 texelSize) {
    vec2 gradient = vec2(0.0);
    float totalWeight = 0.0;

    for (float scale = 1.0; scale <= 4.0; scale *= 2.0) {
        float weight = 1.0 / scale;
        vec2 d = texelSize * scale;

        float tl = texture(tex, uv - d).a;
        float tm = texture(tex, uv - vec2(0.0, d.y)).a;
        float tr = texture(tex, uv + vec2(d.x, -d.y)).a;
        float ml = texture(tex, uv - vec2(d.x, 0.0)).a;
        float mr = texture(tex, uv + vec2(d.x, 0.0)).a;
        float bl = texture(tex, uv + vec2(-d.x, d.y)).a;
        float bm = texture(tex, uv + vec2(0.0, d.y)).a;
        float br = texture(tex, uv + d).a;

        float sobelX = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl);
        float sobelY = (bl + 2.0 * bm + br) - (tl + 2.0 * tm + tr);

        gradient += vec2(sobelX, sobelY) * weight;
        totalWeight += weight;
    }
    return (gradient / totalWeight) * 0.125;
}

vec3 getReconstructedNormal(vec2 p, float thickness) {
    vec2 uv = p / uForegroundSize;

    if (texture(uForegroundTexture, uv).a < 0.01) {
        return vec3(0.0, 0.0, 1.0);
    }

    vec2 shapeCenter = findShapeCenter(uv);
    vec2 centerToPoint = uv - shapeCenter;

    if (length(centerToPoint) < 0.001) {
        return vec3(0.0, 0.0, 1.0);
    }

    vec2 outwardDirection = normalize(centerToPoint);

    float blurredAlpha = texture(uForegroundBlurredTexture, uv).a;
    float edgeDistance = smoothstep(0.0, 1.0, blurredAlpha);

    float normalExponent = 0.2;
    float normalZ = pow(edgeDistance, normalExponent);
    float xyScale = sqrt(max(0.0, 1.0 - normalZ * normalZ));

    return normalize(vec3(outwardDirection * xyScale, normalZ));
}

vec3 getNormal(vec2 p, float thickness) {
    return getReconstructedNormal(p, thickness);
}

// ============================================================================
// MAIN
// ============================================================================
void main() {
    // screenUV in Gerätepixel-Basis (wie bei liquid_glass.frag) + GLES Flip
    vec2 screenUV = FlutterFragCoord().xy / vec2(u_size_x, u_size_y);
#ifdef IMPELLER_TARGET_OPENGLES
    screenUV.y = 1.0 - screenUV.y;
#endif

    // Layer-lokale UVs für die Matte
    vec2 layerLocalCoord = FlutterFragCoord().xy - uOffset;
    vec2 layerUV = layerLocalCoord / uForegroundSize;

    // Außerhalb der Matte → Hintergrund
    if (layerUV.x < 0.0 || layerUV.x > 1.0 || layerUV.y < 0.0 || layerUV.y > 1.0) {
        fragColor = texture(uBackgroundTexture, screenUV);
        return;
    }

    vec4 foregroundColor = texture(uForegroundTexture, layerUV);
    if (foregroundColor.a < 0.001) {
        fragColor = texture(uBackgroundTexture, screenUV);
        return;
    }

    // "SDF" aus der geblurrten Alpha ableiten
    vec4 blurred = texture(uForegroundBlurredTexture, layerUV);
    float sd = approximateSDF(blurred.a, uThickness);

    // Normale rekonstruieren
    vec3 normal = getNormal(layerLocalCoord, uThickness);

    // Glas-Rendering (Blur erfolgt in shared.glsl über Impeller-Uniforms)
    fragColor = renderLiquidGlass(
        screenUV,
        FlutterFragCoord().xy,
        vec2(u_size_x, u_size_y),
        sd,
        uThickness,
        uRefractiveIndex,
        uChromaticAberration,
        uGlassColor,
        uLightAngle,
        uLightIntensity,
        uAmbientStrength,
        uBackgroundTexture,
        normal,
        foregroundColor.a,
        /*gaussianBlurSigmaPx*/ uGaussianBlur,  // ignoriert, API-kompatibel
        /*kawaseSteps*/          uKawaseSteps,  // ignoriert, API-kompatibel
        uSaturation,
        uLightness
    );

#if DEBUG_NORMALS
    fragColor = debugNormals(fragColor, normal, true);
#endif

#if DEBUG_BLUR_MATTE
    fragColor = mix(fragColor, blurred, 0.99);
#endif
}
