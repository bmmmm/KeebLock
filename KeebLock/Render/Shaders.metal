#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle — no vertex buffer, just 3 NDC positions.
// texCoord [0,1] with (0,0) at top-left to match Metal texture convention.
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

// Fragment: sample mask (r = 1 unwiped, 0 wiped), output bgColor × mask as alpha.
fragment float4 fragmentWipe(
    VertexOut           in       [[stage_in]],
    texture2d<float>    maskTex  [[texture(0)]],
    constant float4&    bgColor  [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float mask = maskTex.sample(s, in.texCoord).r;
    return float4(bgColor.rgb, bgColor.a * mask);
}

// Compute: zero out mask pixels inside disc around `center` (mask-texture coords).
kernel void clearDisc(
    texture2d<float, access::read_write> mask   [[texture(0)]],
    constant float2&                     center [[buffer(0)]],
    constant float&                      radius [[buffer(1)]],
    uint2                                gid    [[thread_position_in_grid]]
) {
    const uint w = mask.get_width();
    const uint h = mask.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 pos = float2(gid);
    if (length(pos - center) <= radius) {
        mask.write(float4(0.0), gid);
    }
}
