#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle — no vertex buffer, just 3 NDC positions.
vertex VertexOut vertexPassthrough(uint vid [[vertex_id]]) {
    const float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0),
    };
    const float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0),
    };
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texCoords[vid];
    return out;
}

// Fragment: lerp(pixelColor, backgroundColor, mask) using nearest-neighbour
// sampling so each mask cell renders as a sharp pixel block.
//
//   mask = 1  (intact)  → backgroundColor   (whatever the user picked / random)
//   mask = 0  (wiped)   → pixelColor        (defaults to transparent → desktop visible)
//
// Setting bg=transparent + pixel=color flips the mode: starts transparent,
// fills with color as the user "dirties" the screen.
fragment float4 fragmentWipe(
    VertexOut           in          [[stage_in]],
    texture2d<float>    maskTex     [[texture(0)]],
    constant float4&    bgColor     [[buffer(0)]],
    constant float4&    pixelColor  [[buffer(1)]]
) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float mask = maskTex.sample(s, in.texCoord).r;
    return mix(pixelColor, bgColor, mask);
}
