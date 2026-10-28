#include <metal_stdlib>
using namespace metal;
struct Projection { float4 x; float4 y; float4 z; float4 meta; uint4 info; };
struct Params { uint width; uint height; uint count; uint startRow; };
kernel void stitch(device const uchar4 *pixels [[buffer(0)]], device const Projection *frames [[buffer(1)]], device uchar4 *output [[buffer(2)]], constant Params &p [[buffer(3)]], uint2 tid [[thread_position_in_grid]]) {
    uint2 pos = uint2(tid.x, tid.y+p.startRow);
    if (pos.x >= p.width || pos.y >= p.height) return;
    float yaw = (float(pos.x)+0.5f)/p.width*2*M_PI_F-M_PI_F;
    float pitch = M_PI_F/2-(float(pos.y)+0.5f)/p.height*M_PI_F;
    float3 d = float3(sin(yaw)*cos(pitch), sin(pitch), -cos(yaw)*cos(pitch));
    float3 color = 0; float total = 0;
    for (uint i=0; i<p.count; ++i) {
        Projection f = frames[i];
        float depth = -dot(f.z.xyz,d); if (depth <= 0) continue;
        float2 q = float2(dot(f.x.xyz,d)/depth*f.x.w+f.meta.x, -dot(f.y.xyz,d)/depth*f.y.w+f.meta.y);
        float2 edge = min(q/f.meta.zw, 1-q/f.meta.zw); float e = min(edge.x,edge.y); if (e <= 0.04f) continue;
        uint2 a = uint2(clamp(q, float2(0), f.meta.zw-2)); float2 t = clamp(q-float2(a),0.0f,1.0f);
        uint offset = uint(f.info.x)+a.y*uint(f.meta.z)+a.x;
        float3 c = mix(mix(float3(pixels[offset].xyz),float3(pixels[offset+1].xyz),t.x),mix(float3(pixels[offset+uint(f.meta.z)].xyz),float3(pixels[offset+uint(f.meta.z)+1].xyz),t.x),t.y)/255;
        color += c*f.z.w*e*e; total += e*e;
    }
    output[pos.y*p.width+pos.x] = total > 0 ? uchar4(uchar3(clamp(color/total,0.0f,1.0f)*255),255) : uchar4(0);
}
