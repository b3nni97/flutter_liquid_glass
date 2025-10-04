// Gaussian 1D Backdrop Blur (Impeller)
// Pass direction and kernel are provided via uniforms. This shader is intended
// to be used with ImageFilter.shader (runtime effect) and performs a single
// separable Gaussian pass along either the X or Y axis.

#include <flutter/runtime_effect.glsl>
precision mediump float;
precision mediump int;

// 1) Populated by the engine (required for ImageFilter.shader).
//    Logical device size (in device pixels) of the filtered content.
uniform vec2 u_size;

// 2) Blur direction: (1, 0) = horizontal pass, (0, 1) = vertical pass.
uniform vec2 u_dir;

// 3) Number of packed samples (after kernel compaction/lerp on the host).
//    The host provides a normalized kernel; this value controls the loop bound.
uniform float u_sample_count;

// 4) Tile mode for sampling outside [0, 1]^2 UVs:
//    0 = clamp, 1 = repeat, 2 = mirror, 3 = decal (transparent outside).
uniform float u_tile_mode;

// 5) Packed kernel samples. For each entry:
//    - x: sample offset in "pixels" along u_dir (host space, not UV)
//    - z: normalized sample weight
//    y and w are unused (reserved for alignment/extension).
uniform vec4 u_samples[50];

// 6) Input texture provided by the engine as the first sampler2D.
//    This is the source image for the backdrop filter.
uniform sampler2D u_texture_input;

// Applies the selected tile mode to the given UV coordinates.
vec2 tile_uv(vec2 uv) {
  if (u_tile_mode < 0.5) {
    // Clamp-to-edge with a small epsilon to avoid out-of-range sampling.
    vec2 eps = 0.5 / u_size;
    return clamp(uv, eps, 1.0 - eps);
  } else if (u_tile_mode < 1.5) {
    // Repeat.
    return fract(uv);
  } else if (u_tile_mode < 2.5) {
    // Mirror repeat.
    vec2 m = mod(uv, 2.0);
    return mix(m, 2.0 - m, step(1.0, m));
  } else {
    // Decal: leave UVs unchanged; out-of-bounds becomes transparent later.
    return uv;
  }
}

// Samples the input texture with the configured tile mode, handling decal OOB.
vec4 sample_uv(vec2 uv) {
  if (u_tile_mode >= 2.5) {
    // Decal: outside [0, 1] → transparent.
    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
      return vec4(0.0);
    }
  }
  return texture(u_texture_input, tile_uv(uv));
}

out vec4 frag_color;

void main() {
  vec2 inv_size = 1.0 / u_size;
  vec2 uv = FlutterFragCoord().xy * inv_size;

  // OpenGLES has inverted Y coordinates; flip to match texture space.
  #ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
  #endif

  // Early-out if no kernel is active.
  if (u_sample_count < 0.5) {
    frag_color = sample_uv(uv);
    return;
  }

  // Step vector in UV units for a "1 pixel" move along the chosen axis.
  vec2 step_vec = vec2(u_dir.x * inv_size.x, u_dir.y * inv_size.y);

  vec4 sum = vec4(0.0);

  // Iterate up to the maximum kernel size but terminate early using
  // u_sample_count. Weights are pre-normalized on the host.
  for (int i = 0; i < 50; i++) {
    if (float(i) >= u_sample_count) break;
    float t = u_samples[i].x; // offset along axis (in pixels)
    float w = u_samples[i].z; // normalized weight
    sum += w * sample_uv(uv + step_vec * t);
  }

  // No division required; the host provided normalized weights.
  frag_color = sum;
}
