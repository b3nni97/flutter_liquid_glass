#version 460 core
#include <flutter/runtime_effect.glsl>

precision mediump float;
precision mediump int;

// Viewport dimensions in physical pixels.
uniform vec2 uViewSize;

// Optical configuration.
// z: Thickness of the shape.
// w: Blend factor for the SDF.
uniform vec4 uOpticalProperties;

// Color adjustment settings.
// y: Number of active shapes.
uniform vec2 uColorAdjustment;

// Shape geometry data packed into a float array.
// Capacity allows for up to 8 shapes with 7 attributes each.
#define MAX_SHAPES 8
uniform float uShapeData[MAX_SHAPES * 7];

// Blur configuration header.
// x: Direction X component.
// y: Direction Y component.
// z: Sample count.
// w: Tile mode.
uniform vec4 uBlurConfiguration;

// Gaussian blur kernel samples.
// x: Offset.
// z: Weight.
uniform vec4 uBlurKernel[24];

// Background texture sampler.
uniform sampler2D uBackgroundTexture;

// Output fragment color.
out vec4 fragColor;

// Maps optical property z to thickness for the SDF include.
#define uThickness (uOpticalProperties.z)

// Maps optical property w to blend factor for the SDF include.
#define uBlend (uOpticalProperties.w)

// Maps color adjustment y to shape count for the SDF include.
#define uNumShapes (uColorAdjustment.y)

// Samples the background texture with clamp-to-edge protection.
// Prevents edge artifacts by applying a half-pixel padding based on view size.
vec4 sampleTextureSafe(vec2 uv) {
  vec2 epsilon = vec2(0.5) / max(uViewSize, vec2(1.0));
  vec2 clampedUV = clamp(uv, epsilon, vec2(1.0) - epsilon);
  return texture(uBackgroundTexture, clampedUV);
}

// Applies a 1D Gaussian blur along the configured direction.
// Aggregates weighted samples based on the provided kernel and configuration.
vec4 applyDirectionalBlur(vec2 baseUV) {
  float sampleCount = uBlurConfiguration.z;
  
  if (sampleCount <= 0.5) {
    return sampleTextureSafe(baseUV);
  }

  vec2 inverseSize = vec2(1.0) / max(uViewSize, vec2(1.0));
  vec2 directionStep = vec2(
    uBlurConfiguration.x * inverseSize.x, 
    uBlurConfiguration.y * inverseSize.y
  );

  int count = int(sampleCount + 0.5);
  vec4 accumulatedColor = vec4(0.0);

  for (int i = 0; i < 24; ++i) {
    if (i >= count) {
      break;
    }
    float offset = uBlurKernel[i].x;
    float weight = uBlurKernel[i].z;
    accumulatedColor += weight * sampleTextureSafe(baseUV + directionStep * offset);
  }

  return accumulatedColor;
}

#include "lg_union_sdf.glsl"

// Resolves the texture coordinates relative to the screen size.
// Handles coordinate flipping for OpenGL ES targets if necessary.
vec2 resolveTextureCoordinates(vec2 screenPosition) {
  vec2 inverseSize = vec2(1.0) / max(uViewSize, vec2(1.0));
  vec2 uv = screenPosition * inverseSize;

  #ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
  #endif

  return uv;
}

void main() {
  vec2 screenPosition = FlutterFragCoord().xy;
  vec2 uv = resolveTextureCoordinates(screenPosition);
  
  // The SDF index variable required by the fast calculation signature.
  int shapeIndex;
  float signedDistance = sceneSDF_withIndex_fast(screenPosition, shapeIndex);
  float alphaMask = lg_foreground_alpha(signedDistance);

  vec4 sourceColor = sampleTextureSafe(uv);

  if (alphaMask < 0.001) {
    fragColor = sourceColor;
    return;
  }

  vec4 blurredColor = applyDirectionalBlur(uv);
  fragColor = mix(sourceColor, blurredColor, alphaMask);
}