#version 320 es

precision mediump float;
precision mediump int;

#include <flutter/runtime_effect.glsl>

// -----------------------------------------------------------------------------
// Uniform Layouts
// -----------------------------------------------------------------------------

// Basic Props
layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform vec4 uGlassColor;
layout(location = 2) uniform vec4 uOpticalProps;
layout(location = 3) uniform vec4 uLightConfig;
layout(location = 4) uniform vec2 uColorAdjust;
layout(location = 5) uniform vec2 uLightDirection;
layout(location = 6) uniform mat4 uTransform;
layout(location = 10) uniform vec2 uRimParams;

// Shapes
#define MAX_SHAPES 16
layout(location = 11) uniform float uShapeData[MAX_SHAPES * 7];

// Blur
layout(location = 123) uniform vec4 uBlurHeader;
layout(location = 124) uniform vec4 u_samples[50];

// Touches
#define MAX_TOUCHES 8
layout(location = 324) uniform float uTouchCount_f;
layout(location = 325) uniform vec4 uTouches[MAX_TOUCHES];
layout(location = 333) uniform float uTouchOwners[MAX_TOUCHES];

// --- Glow & Overrides ---
layout(location = 341) uniform float uGlobalBlurSigma;
layout(location = 342) uniform float uTouchGlowStrengths[MAX_TOUCHES];
layout(location = 350) uniform vec4 uShapeGlowData[MAX_SHAPES * 4];

// --- Projection & Environment ---
layout(location = 414) uniform vec2 uBgScale;
layout(location = 416) uniform vec2 uNormalParams;
layout(location = 418) uniform vec4 uChildProjection;
layout(location = 422) uniform vec2 uChildSize;

uniform sampler2D uBackgroundTexture;
uniform sampler2D uBackgroundChildTexture;

layout(location = 0) out vec4 fragColor;

// -----------------------------------------------------------------------------
// Optimization: Zero-Cost Macros instead of Variables
// -----------------------------------------------------------------------------
// Dies spart Register, da keine neuen Variablen angelegt werden müssen.

#define uRefractiveIndex      uOpticalProps.x
#define uChromaticAberration  uOpticalProps.y
#define uThickness            uOpticalProps.z
#define uBlend                uOpticalProps.w

#define uLightIntensity       uLightConfig.y
#define uAmbientStrength      uLightConfig.z
#define uSaturation           uLightConfig.w

#define uLightness            uColorAdjust.x
#define uNumShapes            uColorAdjust.y

#define rimWidthPx            uRimParams.x
#define rimSharpness          uRimParams.y

#define uNormalPlateauWidth   uNormalParams.x
#define uNormalSoftness       uNormalParams.y

#include "shared.glsl"
#include "lg_union_sdf.glsl"

#ifndef AGSL_AA_WIDTH_PX
#define AGSL_AA_WIDTH_PX 1.0
#endif

// -----------------------------------------------------------------------------
// Helper Functions
// -----------------------------------------------------------------------------

vec2 _computeSdfGradient(float dist) {
    return vec2(dFdx(dist), dFdy(dist));
}

vec3 _computeSurfaceNormal(float dist, vec2 grad, float thickness, float plateauWidth, float softness) {
    // Optimierung: max(..., 1e-6) verhindert Division durch Null ohne Branching
    float fullRange = thickness + plateauWidth;
    float t = max(fullRange + dist, 0.0) / max(fullRange, 1.0e-6);
    
    // Pow ist teuer, aber hier notwendig für den Look. 
    // Wenn softness oft 1.0 ist, könnte man optimieren, aber so ist es sicher.
    float nCos = pow(t, softness);
    float nSin = sqrt(max(0.0, 1.0 - nCos * nCos));
    return normalize(vec3(grad * nCos, nSin));
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

void main() {
    // 1. Coordinate Setup (Minimal set for SDF)
    vec2 pScreen = FlutterFragCoord().xy;
    
    // Optimierung: Multiplikation ist schneller als Division. Inverse berechnen.
    // max(..., 1.0) schützt vor Division durch Null.
    vec2 invSize = vec2(1.0) / max(uSize, vec2(1.0)); 
    vec2 screenUV = pScreen * invSize;

    #ifdef IMPELLER_TARGET_OPENGLES
    screenUV.y = 1.0 - screenUV.y;
    #endif

    // Transform berechnen
    // Hinweis: vec4 Konstruktor ist billig, Matrix-Mult ist hier notwendig.
    vec2 p = (uTransform * vec4(pScreen, 0.0, 1.0)).xy;

    // 2. SDF Calculation (Expensive Loop)
    int idx;
    float sdUnion = sceneSDF_withIndex_fast(p, idx);

    // 3. Alpha Calculation
    // AGSL_AA_WIDTH_PX ist Konstante, cast ist free.
    float foregroundAlpha = smoothstep(
        0.0,
        float(AGSL_AA_WIDTH_PX),
        clamp(-sdUnion, 0.0, float(AGSL_AA_WIDTH_PX))
    );

    // -------------------------------------------------------------------------
    // EARLY EXIT
    // -------------------------------------------------------------------------
    if (foregroundAlpha < 0.01) {
        fragColor = _sampleTexture(uBackgroundTexture, screenUV);
        return;
    }

    // -------------------------------------------------------------------------
    // HEAVY LIFTING (Nur ausführen, wenn wir wirklich Glas rendern)
    // -------------------------------------------------------------------------

    // Child Coordinates (Erst hier berechnen)
    vec2 invChildSize = vec2(1.0) / max(uChildSize, vec2(1.0));
    vec2 childUV = pScreen * invChildSize;
    
    #ifdef IMPELLER_TARGET_OPENGLES
    childUV.y = 1.0 - childUV.y;
    #endif

    // --- Dynamic Background Scaling ---
    vec2 targetScale = max(uBgScale, vec2(1.0e-4));
    float scaleRampWidth = max(uNormalSoftness, 1.0);
    
    // Scale Weight Berechnung
    float scaleWeight = smoothstep(0.0, scaleRampWidth, -sdUnion);
    vec2 dynamicS = mix(vec2(1.0), targetScale, scaleWeight);

    // Center Berechnung für den aktiven Shape
    // Indexzugriff auf Uniform-Arrays ist in ES 3.0+ schnell, aber wir machen es nur 1x.
    int baseIdx = idx * 7;
    float cx = uShapeData[baseIdx + 1];
    float cy = uShapeData[baseIdx + 2];

    vec2 centerScreenPx = _projectSdfToScreen(vec2(cx, cy));
    vec2 centerUV = centerScreenPx * invSize;

    #ifdef IMPELLER_TARGET_OPENGLES
    centerUV.y = 1.0 - centerUV.y;
    #endif

    // Apply Scaling
    vec2 scaledUV = centerUV + (screenUV - centerUV) / dynamicS;
    vec2 childUVRaw = uChildProjection.xy + childUV;

    // Normal Calculation
    // Gradienten basieren auf Screen-Space, müssen also hier berechnet werden
    vec2 gradient = _computeSdfGradient(sdUnion);
    vec3 normal = _computeSurfaceNormal(sdUnion, gradient, uThickness, uNormalPlateauWidth, uNormalSoftness);

    // 4. Final Composite
    fragColor = renderLiquidGlass(
        scaledUV, 
        childUVRaw,
        p,
        uSize,
        sdUnion,
        uThickness,
        uRefractiveIndex,
        uChromaticAberration,
        uGlassColor,
        uLightDirection,
        uLightIntensity,
        uAmbientStrength,
        uBackgroundTexture,
        uBackgroundChildTexture,
        normal,
        foregroundAlpha,
        uSaturation,
        uLightness,
        rimWidthPx,
        rimSharpness,
        idx
    );
}