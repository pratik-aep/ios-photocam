#include <metal_stdlib>
using namespace metal;
struct Projection { float4 x; float4 y; float4 z; float4 meta; uint4 info; };
struct Params { uint width; uint height; uint count; uint startRow; };
// Must match LowPass.factor, Reprojection.seamSharpness and Reprojection.lowSharpness on the CPU.
constant float LOW_FACTOR = 8;
constant float SEAM_SHARPNESS = 400;
constant float LOW_SHARPNESS = 60;
float3 lowSample(device const float4 *lows, Projection f, float2 q) {
    float2 l = clamp((q+0.5f)/LOW_FACTOR-0.5f, float2(0), float2(f.info.zw)-1);
    uint2 a = uint2(l), b = min(a+1, f.info.zw-1); float2 t = l-float2(a);
    uint o = f.info.y, w = f.info.z;
    return mix(mix(lows[o+a.y*w+a.x].xyz, lows[o+a.y*w+b.x].xyz, t.x), mix(lows[o+b.y*w+a.x].xyz, lows[o+b.y*w+b.x].xyz, t.x), t.y);
}
kernel void stitch(device const uchar4 *pixels [[buffer(0)]], device const Projection *frames [[buffer(1)]], device uchar4 *output [[buffer(2)]], constant Params &p [[buffer(3)]], device const float4 *lows [[buffer(4)]], uint2 tid [[thread_position_in_grid]]) {
    uint2 pos = uint2(tid.x, tid.y+p.startRow);
    if (pos.x >= p.width || pos.y >= p.height) return;
    float yaw = (float(pos.x)+0.5f)/p.width*2*M_PI_F-M_PI_F;
    float pitch = M_PI_F/2-(float(pos.y)+0.5f)/p.height*M_PI_F;
    float3 d = float3(sin(yaw)*cos(pitch), sin(pitch), -cos(yaw)*cos(pitch));
    // Two-band blend: soft low-band handover, narrow detail seam, both favouring the most central frame (see Reprojection.pixel).
    float3 low = 0, detail = 0; float lowTotal = 0, detailTotal = 0, best = -1;
    for (uint i=0; i<p.count; ++i) {
        Projection f = frames[i];
        float depth = -dot(f.z.xyz,d); if (depth <= 0) continue;
        float2 q = float2(dot(f.x.xyz,d)/depth*f.x.w+f.meta.x, -dot(f.y.xyz,d)/depth*f.y.w+f.meta.y);
        float2 edge = min(q/f.meta.zw, 1-q/f.meta.zw); float e = min(edge.x,edge.y); if (e <= 0.04f) continue;
        uint2 a = uint2(clamp(q, float2(0), f.meta.zw-2)); float2 t = clamp(q-float2(a),0.0f,1.0f);
        uint offset = uint(f.info.x)+a.y*uint(f.meta.z)+a.x;
        float3 c = mix(mix(float3(pixels[offset].xyz),float3(pixels[offset+1].xyz),t.x),mix(float3(pixels[offset+uint(f.meta.z)].xyz),float3(pixels[offset+uint(f.meta.z)+1].xyz),t.x),t.y)/255;
        float3 base = lowSample(lows, f, q);
        if (e > best) { float s = exp(SEAM_SHARPNESS*(best-e)), sl = exp(LOW_SHARPNESS*(best-e)); detail *= s; detailTotal *= s; low *= sl; lowTotal *= sl; best = e; }
        float ramp = min(1.0f, (e-0.04f)*25), w = exp(SEAM_SHARPNESS*(e-best))*ramp, wl = exp(LOW_SHARPNESS*(e-best))*ramp;
        low += base*f.z.w*wl; lowTotal += wl;
        detail += (c-base)*f.z.w*w; detailTotal += w;
    }
    output[pos.y*p.width+pos.x] = lowTotal > 0 ? uchar4(uchar3(clamp(low/lowTotal+detail/detailTotal,0.0f,1.0f)*255),255) : uchar4(0);
}
