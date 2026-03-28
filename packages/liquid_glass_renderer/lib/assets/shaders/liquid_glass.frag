#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;
precision mediump int;

/// The dimensions of the drawing area in physical pixels.
uniform vec2 uSize;

/// The base color of the glass material.
uniform vec4 uGlassColor;

/// Optical properties packed into a single vector.
/// x: Refractive Index
/// y: Chromatic Aberration
/// z: Thickness
/// w: Blend factor
uniform vec4 uOpticalProps;

/// Lighting configuration packed into a single vector.
/// x: (Unused)
/// y: Light Intensity
/// z: Ambient Strength
/// w: Saturation
uniform vec4 uLightConfig;

/// Color adjustment parameters.
/// x: Lightness
/// y: Number of Shapes
uniform vec2 uColorAdjust;

/// Direction of the primary light source.
uniform vec2 uLightDirection;

/// Transformation matrix for converting screen coordinates to local space.
uniform mat4 uTransform;

/// Parameters for rim lighting.
/// x: Rim Width (px)
/// y: Rim Sharpness
uniform vec2 uRimParams;

#define MAX_SHAPES 8

/// Serialized shape data.
uniform float uShapeData[MAX_SHAPES * 7];

/// Settings for blur headers.
uniform vec4 uBlurHeader;

/// Samples used for blur calculations.
uniform vec4 u_samples[24];

#define MAX_TOUCHES 4

/// The number of active touches as a float.
uniform float uTouchCount_f;

/// Active touch positions and data.
uniform vec4 uTouches[MAX_TOUCHES];

/// Owner IDs for the active touches.
uniform float uTouchOwners[MAX_TOUCHES];

/// Global blur sigma value.
uniform float uGlobalBlurSigma;

/// Glow strengths for each touch.
uniform float uTouchGlowStrengths[MAX_TOUCHES];

/// Glow data per shape.
uniform vec4 uShapeGlowData[MAX_SHAPES * 4];

/// Scale factor for the background texture.
uniform vec2 uBgScale;

/// Parameters for normal calculation.
/// x: Plateau Width
/// y: Softness
uniform vec2 uNormalParams;

/// Projection parameters for the child texture.
uniform vec4 uChildProjection;

/// Size of the child texture.
uniform vec2 uChildSize;

/// Key color used for chroma keying or masking.
uniform vec3 uKeyColor;

/// The global opacity applied to the glass effect (0.0 to 1.0).
uniform float uOpacity;

/// The background scene texture.
uniform sampler2D uBackgroundTexture;

/// The texture of the child widget.
uniform sampler2D uBackgroundChildTexture;

/// Output fragment color.
out vec4 fragColor;

// Property Accessors
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

/// Calculates the gradient of the signed distance field using hardware derivatives.
vec2 _calculateSdfGradient(float dist) {
    return vec2(dFdx(dist), dFdy(dist));
}

/// Computes the surface normal based on the SDF gradient and shape properties.
vec3 _calculateSurfaceNormal(float dist, vec2 grad, float thickness, float plateauWidth, float softness) {
    float fullRange = thickness + plateauWidth;
    float t = max(fullRange + dist, 0.0) / max(fullRange, 1.0e-6);
    float nCos = pow(t, softness);
    float nSin = sqrt(max(0.0, 1.0 - nCos * nCos));
    return normalize(vec3(grad * nCos, nSin));
}

/// Normalizes screen coordinates to UV space [0, 1].
vec2 _normalizeUV(vec2 screenPos, vec2 size) {
    vec2 invSize = vec2(1.0) / max(size, vec2(1.0));
    return screenPos * invSize;
}

/// Flips the Y-coordinate if running on an OpenGL ES target.
vec2 _correctUVForTarget(vec2 uv) {
    #ifdef IMPELLER_TARGET_OPENGLES
    return vec2(uv.x, 1.0 - uv.y);
    #endif
    return uv;
}

/// Calculates the alpha value for the foreground shape based on SDF distance.
/// Uses fwidth() for transformation-stable anti-aliasing.
float _calculateForegroundAlpha(float distance) {
    float w = fwidth(distance);
    float aaWidth = max(w, 1e-4);
    return smoothstep(aaWidth, -aaWidth, distance);
}

/// Computes the dynamic scaling factor applied to the background refraction.
vec2 _calculateDynamicScale(float distance, float softness, vec2 targetScale) {
    float rampWidth = max(softness, 1.0);
    float scaleWeight = smoothstep(0.0, rampWidth, -distance);
    return mix(vec2(1.0), max(targetScale, vec2(1.0e-4)), scaleWeight);
}

/// Computes the distorted UV coordinates based on the shape's center and refraction scale.
vec2 _calculateDistortedUV(int shapeIndex, vec2 screenUV, vec2 scale, vec2 size) {
    int baseIdx = shapeIndex * 7;
    float cx = uShapeData[baseIdx + 1];
    float cy = uShapeData[baseIdx + 2];
    
    vec2 centerScreenPx = _projectSdfToScreen(vec2(cx, cy));
    vec2 centerUV = _correctUVForTarget(_normalizeUV(centerScreenPx, size));
    
    return centerUV + (screenUV - centerUV) / scale;
}

void main() {
    vec2 pScreen = FlutterFragCoord().xy;
    vec2 screenUV = _correctUVForTarget(_normalizeUV(pScreen, uSize));
    
    vec2 localPoint = (uTransform * vec4(pScreen, 0.0, 1.0)).xy;

    int shapeIndex;
    float sdUnion = sceneSDF_withIndex_fast(localPoint, shapeIndex);
    
    float foregroundAlpha = _calculateForegroundAlpha(sdUnion);

    if (foregroundAlpha < 0.01) {
        fragColor = _sampleTexture(uBackgroundTexture, screenUV);
        return;
    }

    vec2 childUV = _correctUVForTarget(_normalizeUV(pScreen, uChildSize));
    vec2 childUVRaw = uChildProjection.xy + childUV;

    vec2 dynamicScale = _calculateDynamicScale(sdUnion, uNormalSoftness, uBgScale);
    vec2 scaledUV = _calculateDistortedUV(shapeIndex, screenUV, dynamicScale, uSize);

    vec2 gradient = _calculateSdfGradient(sdUnion);
    vec3 normal = _calculateSurfaceNormal(sdUnion, gradient, uThickness, uNormalPlateauWidth, uNormalSoftness);

    fragColor = renderLiquidGlass(
        scaledUV, 
        childUVRaw,
        localPoint,
        uSize,
        sdUnion,
        uThickness,
        uRefractiveIndex,
        uChromaticAberration,
        uGlassColor,
        uLightDirection,
        uLightIntensity,
        uAmbientStrength,
        uKeyColor,
        uBackgroundTexture,
        uBackgroundChildTexture,
        normal,
        foregroundAlpha,
        uSaturation,
        uLightness,
        rimWidthPx,
        rimSharpness,
        shapeIndex,
        uOpacity
    );
}