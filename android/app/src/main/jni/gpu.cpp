#include "gpu.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <algorithm>
#include <android/log.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <deque>
#include <utility>
#include <dlfcn.h>
#include <unistd.h>
#include <time.h>
#include <android/performance_hint.h>

namespace {
// Optional API 36 graphics-workload hints. Report the actual end-to-end
// render duration; do not substitute wall time for a GPU execution timestamp.
struct GraphicsHintApi {
    void *library=dlopen("libandroid.so",RTLD_NOW|RTLD_LOCAL);
#define HINT(name,type) using name##Type=type; name##Type name##Fn=library?reinterpret_cast<name##Type>(dlsym(library,#name)):nullptr
    HINT(APerformanceHint_getManager,APerformanceHintManager*(*)());
    HINT(ASessionCreationConfig_create,ASessionCreationConfig*(*)());
    HINT(ASessionCreationConfig_release,void(*)(ASessionCreationConfig*));
    HINT(ASessionCreationConfig_setTids,void(*)(ASessionCreationConfig*,const pid_t*,size_t));
    HINT(ASessionCreationConfig_setTargetWorkDurationNanos,void(*)(ASessionCreationConfig*,int64_t));
    HINT(ASessionCreationConfig_setGraphicsPipeline,void(*)(ASessionCreationConfig*,bool));
    HINT(APerformanceHint_createSessionUsingConfig,int(*)(APerformanceHintManager*,ASessionCreationConfig*,APerformanceHintSession**));
    HINT(APerformanceHint_closeSession,void(*)(APerformanceHintSession*));
    HINT(APerformanceHint_reportActualWorkDuration,int(*)(APerformanceHintSession*,int64_t));
    HINT(APerformanceHint_notifyWorkloadIncrease,int(*)(APerformanceHintSession*,bool,bool,const char*));
#undef HINT
    bool ready()const{return APerformanceHint_getManagerFn&&ASessionCreationConfig_createFn&&ASessionCreationConfig_releaseFn&&ASessionCreationConfig_setTidsFn&&ASessionCreationConfig_setTargetWorkDurationNanosFn&&ASessionCreationConfig_setGraphicsPipelineFn&&APerformanceHint_createSessionUsingConfigFn&&APerformanceHint_closeSessionFn&&APerformanceHint_reportActualWorkDurationFn;}
};
GraphicsHintApi &graphicsApi(){static auto *api=new GraphicsHintApi;return *api;}
int64_t monotonicNanos(){timespec t{};clock_gettime(CLOCK_MONOTONIC,&t);return int64_t(t.tv_sec)*1000000000LL+t.tv_nsec;}
struct GraphicsHintSession {
    APerformanceHintSession *session=nullptr;int64_t previousEnd=0;bool reportedError=false;
    GraphicsHintSession(){
        auto &api=graphicsApi();if(!api.ready()){__android_log_print(ANDROID_LOG_INFO,"LightlyGpu","Graphics hint API unavailable");return;}
        auto *manager=api.APerformanceHint_getManagerFn();if(!manager)return;
        auto *config=api.ASessionCreationConfig_createFn();const pid_t tid=gettid();
        api.ASessionCreationConfig_setTidsFn(config,&tid,1);
        api.ASessionCreationConfig_setTargetWorkDurationNanosFn(config,16666667);
        api.ASessionCreationConfig_setGraphicsPipelineFn(config,true);
        int status=api.APerformanceHint_createSessionUsingConfigFn(manager,config,&session);
        api.ASessionCreationConfig_releaseFn(config);
        if(status!=0&&session){api.APerformanceHint_closeSessionFn(session);session=nullptr;}
        __android_log_print(ANDROID_LOG_INFO,"LightlyGpu","Graphics hint status=%d active=%d thread=%d",status,session!=nullptr,tid);
    }
    ~GraphicsHintSession(){if(session)graphicsApi().APerformanceHint_closeSessionFn(session);}
};
struct GraphicsWork {
    GraphicsHintSession *hint=nullptr;int64_t start=0;
    GraphicsWork(){thread_local GraphicsHintSession local;if(!local.session)return;hint=&local;start=monotonicNanos();auto &api=graphicsApi();if(start-local.previousEnd>250000000&&api.APerformanceHint_notifyWorkloadIncreaseFn)api.APerformanceHint_notifyWorkloadIncreaseFn(local.session,true,true,"photo preview");}
    ~GraphicsWork(){if(!hint)return;hint->previousEnd=monotonicNanos();int status=graphicsApi().APerformanceHint_reportActualWorkDurationFn(hint->session,hint->previousEnd-start);if(status!=0&&!hint->reportedError){hint->reportedError=true;__android_log_print(ANDROID_LOG_WARN,"LightlyGpu","Graphics hint report=%d",status);}}
};

std::atomic<bool> profileNext{false};
const char *header = R"GLSL(#version 310 es
precision highp float;
precision highp int;
layout(local_size_x = 64) in;
layout(std430, binding = 0) restrict readonly buffer Input { float data[]; };
layout(std430, binding = 1) restrict writeonly buffer Output { uint result[]; };
uniform int width, height;
float safeAngle(float y,float x){return x==0. && y==0.?0.:atan(y,x);}
float clip(float x) { return clamp(x, 0., 1.); }
float smoothRamp(float a, float b, float x) {
    float t = clip((x - a) / (b - a));
    return t * t * (3. - 2. * t);
}
float linear(float x) { return x <= .04045 ? x / 12.92 : pow((x + .055) / 1.055, 2.4); }
float encoded(float x) {
    x = max(x, 0.);
    return x <= .0031308 ? x * 12.92 : 1.055 * pow(x, 1. / 2.4) - .055;
}
vec3 toLinear(vec3 x) { return vec3(linear(x.r), linear(x.g), linear(x.b)); }
vec3 toEncoded(vec3 x) { return vec3(encoded(x.r), encoded(x.g), encoded(x.b)); }
vec3 lab(vec3 v) {
    vec3 q = vec3(dot(vec3(.4122214708, .5363325363, .0514459929), v),
                  dot(vec3(.2119034982, .6806995451, .1073969566), v),
                  dot(vec3(.0883024619, .2817188376, .6299787005), v));
    q = pow(max(q, vec3(1e-7)), vec3(1. / 3.));
    return vec3(dot(vec3(.2104542553, .7936177850, -.0040720468), q),
                dot(vec3(1.9779984951, -2.4285922050, .4505937099), q),
                dot(vec3(.0259040371, .7827717662, -.8086757660), q));
}

)GLSL";
const char *finishSource = R"GLSL(
layout(std430, binding = 2) restrict readonly buffer Working { float work[]; };
layout(std430, binding = 3) restrict buffer Fields { float fieldData[]; };
layout(rgba8, binding = 0) writeonly uniform highp image2D outputImage;
uniform highp sampler2D sourceImage;
uniform int paramsOffset, matrixOffset, sourceOffset, fieldOffset[4], leakOffset, inkOffset,
    asLab, resident, fieldOnly, writeSurface, quantizeInput;
uniform int noiseOffset[8], sampleOffset[8];
uniform int samplesDirty;
float p(int i) { return data[paramsOffset + i]; }
uniform vec3 lmsToRgbRows[3], labToLmsRows[3];
vec3 linearFromLab(vec3 v) {
    vec3 q = vec3(dot(labToLmsRows[0], v), dot(labToLmsRows[1], v), dot(labToLmsRows[2], v));
    q = q * q * q;
    return clamp(vec3(dot(lmsToRgbRows[0], q), dot(lmsToRgbRows[1], q), dot(lmsToRgbRows[2], q)), 0., 1.);
}
vec3 fromLab(vec3 v) { return toEncoded(linearFromLab(v)); }
float pixel(int offset, int w, int h, int channels, int c, ivec2 pos, bool outside, float fallback) {
    if (outside && (pos.x < 0 || pos.y < 0 || pos.x >= w || pos.y >= h))
        return fallback;
    pos = clamp(pos, ivec2(0), ivec2(w - 1, h - 1));
    return data[offset + (pos.y * w + pos.x) * channels + c];
}
float sampleImage(int offset, int w, int h, int channels, int c, vec2 uv, bool outside, float fallback) {
    vec2 pos = uv - .5;
    ivec2 q = ivec2(floor(pos));
    vec2 f = fract(pos);
    float a = mix(pixel(offset, w, h, channels, c, q, outside, fallback),
                  pixel(offset, w, h, channels, c, q + ivec2(1, 0), outside, fallback), f.x);
    float b = mix(pixel(offset, w, h, channels, c, q + ivec2(0, 1), outside, fallback),
                  pixel(offset, w, h, channels, c, q + ivec2(1, 1), outside, fallback), f.x);
    return mix(a, b, f.y);
}
vec3 prism(float degrees) {
    float h = mod(degrees, 360.) / 60., l = .64, ch = 1. - abs(2. * l - 1.),
          x = ch * (1. - abs(mod(h, 2.) - 1.)), m = l - ch / 2.;
    vec3 v;
    if (h < 1.)
        v = vec3(ch, x, 0);
    else if (h < 2.)
        v = vec3(x, ch, 0);
    else if (h < 3.)
        v = vec3(0, ch, x);
    else if (h < 4.)
        v = vec3(0, x, ch);
    else if (h < 5.)
        v = vec3(x, 0, ch);
    else
        v = vec3(ch, 0, x);
    return v + m;
}

uint hash32(uint x) {
    x ^= x >> 16;
    x *= 0x7FEB352Du;
    x ^= x >> 15;
    x *= 0x846CA68Bu;
    return x ^ (x >> 16);
}
float gaussian(uint seed, uint layer, int row, int col) {
    uint base = hash32(seed ^ hash32(layer));
    uint h1 = hash32(base ^ hash32((uint(row) * 0x9E3779B1u) ^ hash32(uint(col))));
    uint h2 = hash32(h1 ^ 0x85EBCA6Bu);
    float u1 = (float(h1 >> 8) + .5) / 16777216., u2 = (float(h2 >> 8) + .5) / 16777216.;
    return sqrt(-2. * log(u1)) * cos(6.283185307179586 * u2);
}
float noiseSample(int offset, uint seed, uint layer, int rows, int cols, vec2 pixel, vec2 extent) {
    vec2 pos = clamp((pixel + .5) * vec2(cols, rows) / extent - .5, vec2(0), vec2(cols - 1, rows - 1));
    ivec2 q = ivec2(pos), q1 = min(q + 1, ivec2(cols - 1, rows - 1));
    vec2 f = pos - vec2(q);
    return mix(mix(fieldData[offset + q.y * cols + q.x], fieldData[offset + q.y * cols + q1.x], f.x),
               mix(fieldData[offset + q1.y * cols + q.x], fieldData[offset + q1.y * cols + q1.x], f.x), f.y);
}
float field(int pass, int x, int y) {
    int k = 64 + int(p(9)) * 3 + pass * 8;
    if (p(32 + pass * 5) == 1.) {
        vec2 v = vec2(width > 1 ? -1. + 2. * float(x) / float(width - 1) : -1.,
                      height > 1 ? -1. + 2. * float(y) / float(height - 1) : -1.);
        float roundness = p(k + 2);
        if (roundness > 0.)
            v.x *= 1. + roundness * (float(width) / float(height) - 1.);
        float power = 2. + max(0., -roundness) * 6.;
        float radius = pow(pow(abs(v.x), power) + pow(abs(v.y), power), 1. / power) / pow(2., 1. / power);
        float center = .25 + .65 * p(k), band = .05 + .6 * p(k + 1);
        return smoothRamp(center - band * .5, center + band * .5, radius);
    }
    uint seed = uint(p(k + 6)) | (uint(p(k + 7)) << 16);
    int samples = int(p(k + 4));
    float rough = p(k + 5), norm = sqrt((1. - rough) * (1. - rough) + rough * rough);
    int index=y*width+x;
    float fineSum=0.,coarseSum=0.;
    if(samplesDirty!=0) {
        for (int j = 0; j < samples; j++)
            for (int i = 0; i < samples; i++) {
                vec2 pixel = vec2(x * samples + i, y * samples + j),
                     extent = vec2(width, height) * float(samples);
                fineSum += noiseSample(noiseOffset[pass*2], seed, 0u, int(p(k)), int(p(k + 1)), pixel, extent) / (2. / 3.);
                coarseSum += noiseSample(noiseOffset[pass*2+1], seed, 1u, int(p(k + 2)), int(p(k + 3)), pixel, extent) / (2. / 3.);
            }
        fineSum/=float(samples*samples);coarseSum/=float(samples*samples);
        fieldData[sampleOffset[pass*2]+index]=fineSum;
        fieldData[sampleOffset[pass*2+1]+index]=coarseSum;
    } else {
        fineSum=fieldData[sampleOffset[pass*2]+index];
        coarseSum=fieldData[sampleOffset[pass*2+1]+index];
    }
    return ((1.-rough)*fineSum+rough*coarseSum)/norm;
}
void main() {
    int i = int(gl_GlobalInvocationID.x), n = width * height;
    if (i >= n)
        return;
    int x = i % width, y = i / width;
    if (fieldOnly != 0) {
        for (int pass = 0; pass < 4; pass++)
            if (p(32 + pass * 5) != 0.)
                fieldData[fieldOffset[pass] + i] = field(pass, x, y);
        return;
    }
    vec3 rgb;
    if (resident == 3) {
        rgb = texelFetch(sourceImage, ivec2(x,y), 0).rgb;
    } else if (resident == 2) {
        rgb = unpackUnorm4x8(floatBitsToUint(work[i])).rgb;
    } else if (resident != 0) {
        rgb = vec3(work[i], work[n + i], work[2 * n + i]);
        if (asLab != 0)
            rgb = fromLab(rgb);
    } else
        rgb = vec3(data[sourceOffset + i * 4], data[sourceOffset + i * 4 + 1],
                   data[sourceOffset + i * 4 + 2]);
    if(quantizeInput != 0) rgb=floor(clamp(rgb*255.+.5,0.,255.))/255.;
    if (p(10) != 0. && inkOffset >= 0) {
        vec2 d = vec2(x, y) + .5 - vec2(p(11), p(12));
        vec2 uv =
            vec2(p(14) * d.x + p(15) * d.y, -p(15) * d.x + p(14) * d.y) / p(13) + vec2(p(20), p(21)) * .5;
        float value = sampleImage(inkOffset, int(p(20)), int(p(21)), 1, 0, uv, true, p(10) == 1. ? 0. : 1.);
        if (p(10) == 1.)
            rgb = rgb * value + vec3(p(16), p(17), p(18)) * (1. - value);
        else
            rgb *= 1. - p(19) * (1. - value);
    }
    if (p(0) != 0.) {
        float theta = radians(p(4)), cs = cos(theta), sn = sin(theta);
        vec2 center = vec2(p(2) * float(width), p(3) * float(height)) / 100.;
        vec3 light = vec3(0);
        bool covered = false;
        if (p(0) == 5. && leakOffset >= 0) {
            float scale = max(float(width) / p(5), float(height) / p(6));
            vec2 d = vec2(x, y) + .5 - center;
            vec2 uv = vec2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) / scale + vec2(p(5), p(6)) * .5;
            if (all(greaterThanEqual(uv, vec2(0))) && all(lessThanEqual(uv, vec2(p(5), p(6))))) {
                vec2 f = uv / vec2(p(5), p(6));
                float fade =
                    smoothRamp(0., .08, min(f.x, 1. - f.x)) * smoothRamp(0., .08, min(f.y, 1. - f.y));
                for (int c = 0; c < 3; c++)
                    light[c] = sampleImage(leakOffset, int(p(5)), int(p(6)), 4, c, uv, false, 0.) * fade *
                               p(1) / 100.;
                covered = true;
            }
        } else if (p(0) != 5.) {
            vec2 d = vec2(x, y) + .5 - vec2(width, height) * .5;
            d = vec2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) + vec2(width, height) * .5 - center;
            float farthest = max(length(max(center, vec2(width, height) - center)), 1.);
            float t = length(d) / farthest;
            if (t < .55) {
                vec3 core = vec3(255, 150, 70) / 255., ring = vec3(255, 90, 60) / 255.;
                if (p(0) == 2.) {
                    core = vec3(255, 176, 64) / 255.;
                    ring = vec3(230, 120, 40) / 255.;
                } else if (p(0) == 3.) {
                    core = vec3(255, 140, 160) / 255.;
                    ring = vec3(220, 90, 120) / 255.;
                } else if (p(0) == 4.) {
                    float angle = degrees(safeAngle(d.y, d.x));
                    core = prism(angle);
                    ring = prism(angle + 40.);
                }
                if (t <= .30)
                    light = mix(core * min(p(1) / 130., 1.), ring * min(p(1) / 400., 1.), t / .30);
                else
                    light = ring * min(p(1) / 400., 1.) * (1. - (t - .30) / (.55 - .30));
                covered = true;
            }
        }
        if (covered)
            rgb = clamp(p(0) == 5. ? 1. - (1. - rgb) * (1. - light) : rgb + light * (1. - rgb), 0., 1.);
    }
    int picks = int(p(9));
    if (picks > 0) {
        vec3 v = toLinear(rgb), o = lab(v);
        float saturation = length(o.yz) / max(o.x, .05), angle = mod(degrees(safeAngle(o.z, o.y)), 360.),
              keep = 0.;
        for (int j = 0; j < picks; j++) {
            vec3 pick = vec3(p(64 + j * 3), p(65 + j * 3), p(66 + j * 3));
            float sat = length(pick.yz) / max(pick.x, .05),
                  hue = mod(degrees(safeAngle(pick.z, pick.y)), 360.), match;
            if (sat < .04)
                match = 1. - smoothRamp(.04, .08, saturation);
            else {
                float distance = abs(mod(angle - hue + 180., 360.) - 180.), window = 6. + .5 * p(7),
                      ratio = saturation / sat, start = .65 - .0055 * p(7);
                match = clip((window - distance) / (.5 * window)) *
                        smoothRamp(start, start + .25, min(ratio, 1. / max(ratio, 1e-6)));
            }
            keep = max(keep, match);
        }
        float fullness = keep + (1. - keep) * (1. - p(8) / 100.), luma = dot(v, vec3(.2126, .7152, .0722));
        rgb = toEncoded(luma + (v - luma) * fullness);
    }
    bool linearValid = false;
    vec3 linearRgb = vec3(0);
    for (int pass = 0; pass < 4; pass++) {
        int k = 32 + pass * 5;
        float kind = p(k);
        if (kind == 0.)
            continue;
        float value = fieldData[fieldOffset[pass] + i], amount = p(k + 1), gainK = p(k + 2);
        if (kind == 1.) {
            int style = int(p(k + 3));
            if (style == 3) {
                if (linearValid) rgb = toEncoded(linearRgb);
                linearValid = false;
                float target = amount < 0. ? 0. : 1., weight = clip(abs(amount) * gainK * value);
                rgb = clamp(rgb * (1. - weight) + target * weight, 0., 1.);
            } else if (style == 2) {
                vec3 o = lab(linearValid ? linearRgb : toLinear(rgb));
                o.x = clip(o.x * pow(max(1. + gainK * amount * value, 0.), 1. / 3.));
                linearRgb = linearFromLab(o); linearValid = true;
            } else {
                vec3 v = linearValid ? linearRgb : toLinear(rgb);
                float gain = 1. + gainK * amount * value;
                if (amount < 0. && p(k + 4) != 0.) {
                    float luma = clip(dot(v, vec3(.2126, .7152, .0722)));
                    gain = 1. + (gain - 1.) * (1. - p(k + 4) * smoothRamp(.35, .9, luma));
                }
                linearRgb = clamp(v * max(gain, 0.), 0., 1.); linearValid = true;
            }
        } else {
            vec3 o = lab(linearValid ? linearRgb : toLinear(rgb));
            float l = o.x, target = clip(l + gainK * amount * value * (4. * l * (1. - l) + .2)),
                  ratio = target / max(l, 1e-6);
            linearRgb = linearFromLab(vec3(target, o.yz * ratio)); linearValid = true;
        }
    }
    if (linearValid) rgb = toEncoded(linearRgb);
    uvec3 bytes = uvec3(clamp(rgb * 255. + .5, 0., 255.)) & uvec3(255u);
    uint alpha = p(63)==1. ? 255u : resident == 3 ? uint(texelFetch(sourceImage, ivec2(x,y), 0).a * 255. + .5) : resident == 2 ? (floatBitsToUint(work[i]) >> 24) : uint(data[sourceOffset + i * 4 + 3] * 255. + .5);
    if (writeSurface != 0) imageStore(outputImage, ivec2(x,y), vec4(vec3(bytes),float(alpha)) / 255.);
    else result[i] = bytes.r | (bytes.g << 8) | (bytes.b << 16) | (alpha << 24);
}
)GLSL";
const char *globalSource = R"GLSL(
uniform int autoSize, lookSize, asLab, sourceOffset, cacheOperation;
uniform float lookStrength;
layout(std430, binding = 2) restrict readonly buffer ColourCache { float colourCache[]; };
uniform highp sampler3D autoTable, lookTable;
vec3 lut(vec3 rgb, highp sampler3D table, int n) {
    if (n < 2)
        return rgb;
    vec3 pos = clamp(rgb, 0., 1.) * float(n - 1);
    ivec3 lo = min(ivec3(pos), ivec3(n - 2));
    vec3 f = pos - vec3(lo);
    vec3 c00 = mix(texelFetch(table, lo, 0).rgb, texelFetch(table, lo + ivec3(1, 0, 0), 0).rgb, f.r),
         c10 = mix(texelFetch(table, lo + ivec3(0, 1, 0), 0).rgb,
                   texelFetch(table, lo + ivec3(1, 1, 0), 0).rgb, f.r),
         c01 = mix(texelFetch(table, lo + ivec3(0, 0, 1), 0).rgb,
                   texelFetch(table, lo + ivec3(1, 0, 1), 0).rgb, f.r),
         c11 = mix(texelFetch(table, lo + ivec3(0, 1, 1), 0).rgb,
                   texelFetch(table, lo + ivec3(1, 1, 1), 0).rgb, f.r);
    return mix(mix(c00, c10, f.g), mix(c01, c11, f.g), f.b);
}
void main() {
    int i = int(gl_GlobalInvocationID.x), n = width * height;
    if (i >= n)
        return;
    vec3 rgb;
    if (cacheOperation == 0) {
        vec3 source = vec3(data[sourceOffset + i * 4], data[sourceOffset + i * 4 + 1], data[sourceOffset + i * 4 + 2]);
        vec3 base = lut(source, autoTable, autoSize);
        if (lookSize >= 2) base = clamp(base, 0., 1.);
        rgb = lut(base, lookTable, lookSize);
        result[i] = floatBitsToUint(base.r);
        result[n + i] = floatBitsToUint(base.g);
        result[2 * n + i] = floatBitsToUint(base.b);
        result[3 * n + i] = floatBitsToUint(rgb.r);
        result[4 * n + i] = floatBitsToUint(rgb.g);
        result[5 * n + i] = floatBitsToUint(rgb.b);
        return;
    }
    vec3 base = vec3(colourCache[i], colourCache[n + i], colourCache[2 * n + i]);
    vec3 graded = vec3(colourCache[3 * n + i], colourCache[4 * n + i], colourCache[5 * n + i]);
    rgb = mix(base, graded, lookStrength);
    if (asLab != 0)
        rgb = lab(toLinear(rgb));
    result[i] = floatBitsToUint(rgb.r);
    result[n + i] = floatBitsToUint(rgb.g);
    result[2 * n + i] = floatBitsToUint(rgb.b);
}
)GLSL";
const char *spatialSource =
    R"GLSL(#version 310 es
precision highp float;
precision highp int;
layout(local_size_x = 64) in;
uniform float kernel[256];
layout(std430, binding = 1) restrict buffer Planes { float plane[]; };
layout(std430, binding = 2) restrict buffer Auxiliary { float aux[]; };
uniform int width, height, bw, bh, factor, channel, kernelOffset,
    sourceBase, targetBase, blurBase;
#ifdef FIXED_SIZE
const int sourceKind=FIXED_DIRECTION, blurFinish=FIXED_FINISH;
#else
uniform int sourceKind, blurFinish;
#endif
#ifdef FIXED_SIZE
const int operation = 1, kernelSize = FIXED_SIZE, direction = FIXED_DIRECTION;
#else
uniform int operation, kernelSize, direction;
#endif
uniform float detailScale, weight, clarity, textureAmount, threshold, edgeScale, edgeMask, sharpen;
float ramp(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0., 1.);
    return t * t * (3. - 2. * t);
}
int mirror(int x, int n) {
    if (n == 1)
        return 0;
    int period = 2 * (n - 1);
    x = x % period;
    if (x < 0)
        x += period;
    return x < n ? x : period - x;
}
void main() {
    int i=int(gl_GlobalInvocationID.x), n=width*height;
    int w=sourceKind==3?bw:width,h=sourceKind==3?bh:height;
    int x=i%width,y=i/width;
    if(operation==0){
        if(i>=bw*bh)return;
        x=i%bw;y=i/bw;
        float sum=0.;int count=0;
        for(int sy=y*factor;sy<min(height,(y+1)*factor);sy++)for(int sx=x*factor;sx<min(width,(x+1)*factor);sx++){sum+=plane[sy*width+sx];count++;}
        aux[y*bw+x]=sum/float(count);return;
    }
    if(operation==6){
        if(i>=n)return;
        int r=kernelSize/2;
        bool interior=direction==0?(x>=r&&x+r<width):(y>=r&&y+r<height);
        int stride=direction==0?1:width;
        vec2 sum=vec2(0);
        for(int j=0;j<kernelSize;j++){
            int k=interior?i+(j-r)*stride:
                (direction==0?y*width+mirror(x+j-r,width):mirror(y+j-r,height)*width+x);
            vec2 value=direction==0?vec2(plane[n+k],plane[2*n+k]):vec2(aux[sourceBase+k],aux[sourceBase+n+k]);
            sum+=kernel[j]*value;
        }
        if(direction==0){aux[targetBase+i]=sum.x;aux[targetBase+n+i]=sum.y;}
        else {vec2 original=vec2(plane[n+i],plane[2*n+i]);sum=original+(sum-original)*weight;plane[n+i]=sum.x;plane[2*n+i]=sum.y;}
        return;
    }
    if(operation==1){
        if(i>=w*h)return;
        x=i%w;y=i/w;
        int r=kernelSize/2;
        bool interior=direction==0?(x>=r&&x+r<w):(y>=r&&y+r<h);
        int stride=direction==0?1:w;
        float sum=0.;
#ifdef FIXED_SIZE
        int centre = sourceBase + i;
        sum = kernel[r] * (sourceKind == 0 ? plane[centre] : aux[centre]);
        for (int j = 1; j <= r; j++) {
            int lo = interior ? i-j*stride : (direction==0 ? y*w+mirror(x-j,w) : mirror(y-j,h)*w+x);
            int hi = interior ? i+j*stride : (direction==0 ? y*w+mirror(x+j,w) : mirror(y+j,h)*w+x);
            float pair = sourceKind == 0 ? plane[sourceBase+lo]+plane[sourceBase+hi] : aux[sourceBase+lo]+aux[sourceBase+hi];
            sum += kernel[r+j] * pair;
        }
#else
        if(interior){
            int start=sourceBase+i-r*stride;
            if(sourceKind==0){
                for(int j=0;j<kernelSize;j++)sum+=kernel[j]*plane[start+j*stride];
            }else{
                for(int j=0;j<kernelSize;j++)sum+=kernel[j]*aux[start+j*stride];
            }
        }else{
            for(int j=0;j<kernelSize;j++){
                int sx=direction==0?mirror(x+j-r,w):x,sy=direction==1?mirror(y+j-r,h):y,k=sourceBase+sy*w+sx;
                sum+=kernel[j]*(sourceKind==0?plane[k]:aux[k]);
            }
        }
#endif
        if (blurFinish == 0) aux[targetBase+i]=sum;
        else {
            float v = plane[i], outv = v;
            if (blurFinish == 2) {
                float d = sum - v;
                outv = v + d * weight * (1. - ramp(0., detailScale, abs(d)));
            } else if (blurFinish == 4) {
                if (clarity != 0.) {
                    vec2 p = clamp((vec2(x, y) + .5) / float(factor) - .5, vec2(0), vec2(bw - 1, bh - 1));
                    ivec2 q = ivec2(p), q1 = min(q + 1, ivec2(bw - 1, bh - 1));
                    vec2 f = p - vec2(q);
                    float base = mix(mix(aux[q.y * bw + q.x], aux[q.y * bw + q1.x], f.x),
                                     mix(aux[q1.y * bw + q.x], aux[q1.y * bw + q1.x], f.x), f.y);
                    outv += clarity * 4. * v * (1. - v) * (v - base);
                }
                outv += textureAmount * (v - sum);
            } else if (blurFinish == 5) {
                float detail = v - sum;
                detail = detail * abs(detail) / (abs(detail) + threshold + 1e-12);
                outv = v + sharpen * detail;
            }
            plane[i] = clamp(outv, 0., 1.);
        }
        return;
    }
    if(x>=width||y>=height)return;
    int k = channel * n + i;
    float v = plane[k];
    if (operation == 2) {
        float d = aux[blurBase + i] - v;
        plane[k] = clamp(v + d * weight * (1. - ramp(0., detailScale, abs(d))), 0., 1.);
    } else if (operation == 3) {
        plane[k] = v + (aux[blurBase + i] - v) * weight;
    } else if (operation == 4) {
        float outv = v;
        if (clarity != 0.) {
            vec2 p = clamp((vec2(x, y) + .5) / float(factor) - .5, vec2(0), vec2(bw - 1, bh - 1));
            ivec2 q = ivec2(p), q1 = min(q + 1, ivec2(bw - 1, bh - 1));
            vec2 f = p - vec2(q);
            float base = mix(mix(aux[q.y * bw + q.x], aux[q.y * bw + q1.x], f.x),
                             mix(aux[q1.y * bw + q.x], aux[q1.y * bw + q1.x], f.x), f.y);
            outv += clarity * 4. * v * (1. - v) * (v - base);
        }
        if (textureAmount != 0.)
            outv += textureAmount * (v - aux[blurBase + i]);
        plane[i] = clamp(outv, 0., 1.);
    } else if (operation == 5) {
        float detail = v - aux[blurBase + i];
        detail = detail * abs(detail) / (abs(detail) + threshold + 1e-12);
        if (edgeMask != 0.) {
            float gx = width == 1       ? 0.
                       : x == 0         ? aux[blurBase + i + 1] - aux[blurBase + i]
                       : x == width - 1 ? aux[blurBase + i] - aux[blurBase + i - 1]
                                        : (aux[blurBase + i + 1] - aux[blurBase + i - 1]) * .5;
            float gy = height == 1 ? 0.
                       : y == 0    ? aux[blurBase + i + width] - aux[blurBase + i]
                       : y == height - 1
                           ? aux[blurBase + i] - aux[blurBase + i - width]
                           : (aux[blurBase + i + width] - aux[blurBase + i - width]) * .5;
            detail *= ramp(0., edgeMask, length(vec2(gx, gy)) * edgeScale);
        }
        plane[i] = clamp(v + sharpen * detail, 0., 1.);
    }
}

)GLSL";
const char *horizontalScalarSource=R"GLSL(
precision highp float;
precision highp int;
layout(local_size_x=64) in;
layout(std430,binding=1) restrict readonly buffer Planes { float plane[]; };
layout(std430,binding=2) restrict writeonly buffer Auxiliary { float aux[]; };
uniform int width,height,sourceBase,targetBase;
uniform float kernel[FIXED_SIZE];
int mirror(int x,int n) {
    if(n==1)return 0;int period=2*(n-1);x=x%period;if(x<0)x+=period;return x<n?x:period-x;
}
void main() {
    int i=int(gl_GlobalInvocationID.x);if(i>=width*height)return;
    int x=i%width,y=i/width;const int r=FIXED_SIZE/2;
    bool interior=x>=r && x+r<width;
    float sum=kernel[r]*plane[sourceBase+i];
    for(int j=1;j<=r;j++) {
        int lo=interior?i-j:y*width+mirror(x-j,width);
        int hi=interior?i+j:y*width+mirror(x+j,width);
        sum+=kernel[r+j]*(plane[sourceBase+lo]+plane[sourceBase+hi]);
    }
    aux[targetBase+i]=sum;
}
)GLSL";
const char *chromaSource = R"GLSL(
precision highp float;
precision highp int;
layout(local_size_x = GROUP_W, local_size_y = GROUP_H) in;
#if DIRECTION == 0
layout(std430, binding = 1) restrict readonly buffer Planes { float plane[]; };
layout(std430, binding = 2) restrict writeonly buffer Auxiliary { float aux[]; };
#else
layout(std430, binding = 1) restrict buffer Planes { float plane[]; };
layout(std430, binding = 2) restrict readonly buffer Auxiliary { float aux[]; };
#endif
uniform int width, height, sourceBase, targetBase;
const int kernelSize = KERNEL_SIZE;
uniform float kernel[KERNEL_SIZE], weight;
shared vec2 tile[TILE_SIZE];
int reflectEdge(int v, int size) {
    if (v >= 0 && v < size) return v;
    if (size == 1) return 0;
    int period = 2 * (size - 1);
    v = v % period;
    if (v < 0) v += period;
    return v < size ? v : period - v;
}
void main() {
    int lx = int(gl_LocalInvocationID.x), ly = int(gl_LocalInvocationID.y);
    int gx = int(gl_WorkGroupID.x) * GROUP_W, gy = int(gl_WorkGroupID.y) * GROUP_H;
    int tw = DIRECTION == 0 ? GROUP_W + kernelSize - 1 : GROUP_W;
    int th = DIRECTION == 0 ? GROUP_H : GROUP_H + kernelSize - 1;
    int radius = kernelSize / 2, n = width * height;
    for (int j = ly * GROUP_W + lx; j < tw * th; j += GROUP_W * GROUP_H) {
        int x = reflectEdge(gx + j % tw - (DIRECTION == 0 ? radius : 0), width);
        int y = reflectEdge(gy + j / tw - (DIRECTION == 1 ? radius : 0), height);
        int i = y * width + x;
#if DIRECTION == 0
        tile[j] = vec2(plane[n + i], plane[2 * n + i]);
#else
        tile[j] = vec2(aux[sourceBase + i], aux[sourceBase + n + i]);
#endif
    }
    barrier();
    int x = gx + lx, y = gy + ly;
    if (x >= width || y >= height) return;
    int offset = ly * tw + lx, stride = DIRECTION == 0 ? 1 : tw;
    int centre = offset + radius * stride;
    vec2 sum = kernel[radius] * tile[centre];
    for (int j = 1; j <= radius; j++)
        sum += kernel[radius + j] * (tile[centre - j * stride] + tile[centre + j * stride]);
    int i = y * width + x;
#if DIRECTION == 0
    aux[targetBase + i] = sum.x; aux[targetBase + n + i] = sum.y;
#else
    {
        vec2 original = vec2(plane[n + i], plane[2 * n + i]);
        sum = original + (sum - original) * weight;
        plane[n + i] = sum.x; plane[2 * n + i] = sum.y;
    }
#endif
}
)GLSL";
// A completed preview can be shared directly with Android's bitmap compositor.
// The Java HardwareBuffer owns the allocation after detach(); temporary GL imports
// are released after the dispatch has completed.
struct SharedImage {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLImageKHR image = EGL_NO_IMAGE_KHR;
    GLuint texture = 0;
    AHardwareBuffer *buffer = nullptr;
    bool owns = false;
    bool import(EGLDisplay d, AHardwareBuffer *b) {
        display = d; buffer = b;
        auto client = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
        auto create = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
        auto target = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
        if (!client || !create || !target) { __android_log_print(ANDROID_LOG_ERROR,"LightlyGpu","AHB missing EGL entry points"); return false; }
        EGLint attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
        image = create(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, client(buffer), attrs);
        if (image == EGL_NO_IMAGE_KHR) { __android_log_print(ANDROID_LOG_ERROR,"LightlyGpu","AHB EGL image %x",eglGetError()); return false; }
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        // Image load/store requires immutable texture storage on stricter GLES drivers.
        // OES_EGL_image alone creates a mutable target on those devices.
        auto storage=reinterpret_cast<PFNGLEGLIMAGETARGETTEXSTORAGEEXTPROC>(eglGetProcAddress("glEGLImageTargetTexStorageEXT"));
        const char *extensions=reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS));
        if(storage && extensions && std::strstr(extensions,"GL_EXT_EGL_image_storage")) storage(GL_TEXTURE_2D,image,nullptr);
        else target(GL_TEXTURE_2D, image);
        GLenum error=glGetError(); if(error) __android_log_print(ANDROID_LOG_ERROR,"LightlyGpu","AHB import GL %x",error); return error==GL_NO_ERROR;
    }
    bool allocate(EGLDisplay d, int w, int h) {
        AHardwareBuffer_Desc desc{};
        desc.width=w; desc.height=h; desc.layers=1; desc.format=AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
        desc.usage=AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT | AHARDWAREBUFFER_USAGE_CPU_READ_RARELY;
        AHardwareBuffer *allocated = nullptr;
        int result=AHardwareBuffer_allocate(&desc,&allocated);
        if(result!=0) { __android_log_print(ANDROID_LOG_ERROR,"LightlyGpu","AHB allocate %d",result);return false; }
        owns=true;
        return import(d, allocated);
    }
    AHardwareBuffer *detach() { owns=false; return buffer; }
    ~SharedImage() {
        if (texture) glDeleteTextures(1, &texture);
        if (image != EGL_NO_IMAGE_KHR) {
            auto destroy = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
            if (destroy) destroy(display, image);
        }
        if (owns && buffer) AHardwareBuffer_release(buffer);
    }
};
struct Compute {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLConfig config{};
    bool schedulingSelected=false, boundedBatches=true;
    GLuint finish = 0, global = 0, blend[2]={}, spatial = 0, chroma[2][13] = {}, scalarBlur[2][13][6] = {}, buffers[15] = {},
           textures[2] = {0, 0}, dummyImage = 0;
    GLuint noiseProgram=0;
    struct NoiseCache { std::vector<int64_t> key; GLint offsets[8]={}, samples[8]={}; bool samplesDirty=false; } noiseCaches[2];
    bool failed = false;
    int chromaRows = 8;
    size_t packedSourceBytes = 4;
    std::mutex mutex;
    bool current() {
        if (failed)
            return false;
        if (context == EGL_NO_CONTEXT) {
            display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
            EGLint major, minor;
            if (!eglInitialize(display, &major, &minor))
                return fail();
            EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                              EGL_NONE};
            EGLint count;
            if (!eglChooseConfig(display, attrs, &config, 1, &count) || !count)
                return fail();
            // Start at normal priority, then select the driver scheduling policy
            // before allocating any image or shader resources.
            const char *extensions=eglQueryString(display,EGL_EXTENSIONS);
            if(extensions && std::strstr(extensions,"EGL_IMG_context_priority")) {
                EGLint priority[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_CONTEXT_PRIORITY_LEVEL_IMG,EGL_CONTEXT_PRIORITY_MEDIUM_IMG,EGL_NONE};
                context=eglCreateContext(display,config,EGL_NO_CONTEXT,priority);
            }
            if (context == EGL_NO_CONTEXT) {
                EGLint ctx[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
                context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctx);
            }
            EGLint surf[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
            surface = eglCreatePbufferSurface(display, config, surf);
        }
        if (!eglMakeCurrent(display, surface, surface, context))
            return fail();
        if (!schedulingSelected) {
            const char *extensions=eglQueryString(display,EGL_EXTENSIONS);
            // Prefer a low-priority compute queue so UI composition can run first.
            // Drivers without this extension keep the bounded normal-priority fallback.
            if (extensions && std::strstr(extensions,"EGL_IMG_context_priority")) {
                EGLint attrs[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_CONTEXT_PRIORITY_LEVEL_IMG,EGL_CONTEXT_PRIORITY_LOW_IMG,EGL_NONE};
                EGLContext low=eglCreateContext(display,config,EGL_NO_CONTEXT,attrs);
                if(low!=EGL_NO_CONTEXT) {
                    EGLContext original=context;
                    if(eglMakeCurrent(display,surface,surface,low)) {
                        context=low;eglDestroyContext(display,original);boundedBatches=false;
                    } else {
                        eglDestroyContext(display,low);
                        if(!eglMakeCurrent(display,surface,surface,original))return fail();
                    }
                }
            }
            schedulingSelected=true;
            __android_log_print(ANDROID_LOG_INFO,"LightlyGpu","scheduling %s",boundedBatches?"bounded normal":"continuous low");
        }
        if (!finish) {
            GLint maxGroup=0;glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS,&maxGroup);
            chromaRows=maxGroup>=256?16:8;
            finish = program(finishSource);
            global = program(globalSource);
            for(int lab=0;lab<2;lab++) {
                std::string body=globalSource;
                const std::string declaration="uniform int autoSize, lookSize, asLab, sourceOffset, cacheOperation;";
                body.replace(body.find(declaration),declaration.size(),"uniform int autoSize,lookSize,sourceOffset; const int cacheOperation=1,asLab="+std::to_string(lab)+";");
                blend[lab]=program(body.c_str());
            }
            spatial = standaloneProgram(spatialSource);
            if (!finish || !global || !blend[0] || !blend[1] || !spatial)
                return fail();
            glGenBuffers(15, buffers);
            glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[12]);
            glBufferData(GL_SHADER_STORAGE_BUFFER, 4, nullptr, GL_DYNAMIC_DRAW);
            glGenTextures(2, textures);
            glGenTextures(1, &dummyImage);
            glBindTexture(GL_TEXTURE_2D, dummyImage);
            glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 1, 1);
        }
        return true;
    }
    bool fail() {
        failed = true;
        __android_log_print(ANDROID_LOG_ERROR, "LightlyGpu",
                            "GPU unavailable, using CPU reference (EGL %x GL %x)", eglGetError(),
                            glGetError());
        return false;
    }
    void release() {
        if (display != EGL_NO_DISPLAY)
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    // Compile only structural effect choices; amounts and geometry remain uniforms.
    // This removes inactive colour-space/overlay paths without approximating a pixel.
    std::deque<std::pair<std::string,GLuint>> finishingVariants;
    GLuint finishingProgram(const double *params, int resident, bool asLab, bool surface, bool quantize=false) {
        std::string body = finishSource;
        auto replace = [&](const std::string &from, const std::string &to) {
            size_t at=0;
            while ((at=body.find(from,at))!=std::string::npos) { body.replace(at,from.size(),to);at+=to.size(); }
        };
        std::string constants = "float p(int i) { ";
        std::string key=std::to_string(resident)+":"+std::to_string(asLab)+":"+std::to_string(surface)+":"+std::to_string(quantize);
        for(int index : {0,9,10,32,35,37,40,42,45,47,50,63}) {
            int value=static_cast<int>(params[index]);
            constants += "if(i=="+std::to_string(index)+") return "+std::to_string(value)+".; ";
            key += ":"+std::to_string(value);
        }
        for(const auto &entry:finishingVariants) if(entry.first==key)return entry.second;
        constants += "return data[paramsOffset + i]; }";
        replace("float p(int i) { return data[paramsOffset + i]; }", constants);
        replace("asLab, resident, fieldOnly, writeSurface, quantizeInput;", "fieldOnly;\nconst int quantizeInput="+std::to_string(quantize)+", asLab="+std::to_string(asLab)+", resident="+
            std::to_string(resident)+", writeSurface="+std::to_string(surface)+";");
        // Fixed pass indices let the compiler eliminate all inactive finishing layers.
        const std::string marker="    for (int pass = 0; pass < 4; pass++) {";
        size_t start=body.find(marker), opening=body.find('{',start), end=opening+1;
        int depth=1;
        for(;depth && end<body.size();end++) { if(body[end]=='{')depth++;else if(body[end]=='}')depth--; }
        if(start!=std::string::npos && depth==0) {
            std::string inner=body.substr(opening+1,end-opening-2), unrolled;
            // The source loop's continue becomes a conditional block for each fixed pass.
            const std::string skip="        if (kind == 0.)\n            continue;";
            auto skipAt=inner.find(skip);
            if(skipAt!=std::string::npos) inner.replace(skipAt,skip.size(),"        if (kind != 0.) {");
            for(int pass=0;pass<4;pass++)unrolled+="{ const int pass="+std::to_string(pass)+";"+inner+"} }\n";
            body.replace(start,end-start,unrolled);
        }
        GLuint compiled=program(body.c_str());
        if(!compiled)return finish;
        if(finishingVariants.size()>=32) { glDeleteProgram(finishingVariants.front().second);finishingVariants.pop_front(); }
        finishingVariants.emplace_back(key,compiled);
        return compiled;
    }
    // Generate the deterministic Gaussian cells once, then sample them. Computing
    // log/cos/hash for every repeated bilinear neighbour made size/roughness drags expensive.
    bool prepareFields(int slot,int width,int height,const double *params,bool &dirty) {
        auto &cache=noiseCaches[slot==13?0:1];
        std::vector<int64_t> key{width,height};
        int rows[8]={},cols[8]={};uint32_t seeds[8]={};
        GLint offsets[8]={},sampleOffsets[8]={};int total=width*height*4;
        for(int pass=0;pass<4;pass++) if(params[32+pass*5]==2.) {
            sampleOffsets[pass*2]=total;total+=width*height;
            sampleOffsets[pass*2+1]=total;total+=width*height;
        }
        for(int pass=0;pass<4;pass++) {
            int k=64+int(params[9])*3+pass*8;
            bool grain=params[32+pass*5]==2.;
            key.push_back(grain?int(params[k+4]):0);
            uint32_t seed=uint32_t(params[k+6])|(uint32_t(params[k+7])<<16);
            for(int layer=0;layer<2;layer++) {
                int i=pass*2+layer;
                rows[i]=grain?int(params[k+layer*2]):0;cols[i]=grain?int(params[k+layer*2+1]):0;seeds[i]=grain?seed:0;
                offsets[i]=total;total+=rows[i]*cols[i];
                key.push_back(rows[i]);key.push_back(cols[i]);key.push_back(seeds[i]);
            }
        }
        cache.samplesDirty=key!=cache.key;
        if(!cache.samplesDirty)return true;
        if(!noiseProgram) {
            std::string common=finishSource;
            size_t start=common.find("uint hash32"),end=common.find("float noiseSample",start);
            std::string shader="#version 310 es\nprecision highp float; precision highp int;\nlayout(local_size_x=64) in;\nlayout(std430,binding=3) restrict writeonly buffer Noise {float noise[];};\nuniform int rows,cols,base; uniform uint seed,layer;\n"+common.substr(start,end-start)+
                "void main(){int i=int(gl_GlobalInvocationID.x);if(i>=rows*cols)return;noise[base+i]=gaussian(seed,layer,i/cols,i%cols);}";
            noiseProgram=standaloneProgram(shader.c_str());
            if(!noiseProgram)return false;
        }
        glBindBuffer(GL_SHADER_STORAGE_BUFFER,buffers[slot]);
        glBufferData(GL_SHADER_STORAGE_BUFFER,static_cast<GLsizeiptr>(total)*4,nullptr,GL_DYNAMIC_DRAW);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER,3,buffers[slot]);
        glUseProgram(noiseProgram);
        for(int i=0;i<8;i++) if(rows[i]>0 && cols[i]>0) {
            integer(noiseProgram,"rows",rows[i]);integer(noiseProgram,"cols",cols[i]);integer(noiseProgram,"base",offsets[i]);
            glUniform1ui(glGetUniformLocation(noiseProgram,"seed"),seeds[i]);
            glUniform1ui(glGetUniformLocation(noiseProgram,"layer"),i%2);
            glDispatchCompute((rows[i]*cols[i]+63)/64,1,1);
        }
        glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
        if(glGetError()!=GL_NO_ERROR)return false;
        cache.key=std::move(key);std::copy(offsets,offsets+8,cache.offsets);
        std::copy(sampleOffsets,sampleOffsets+8,cache.samples);dirty=true;
        return true;
    }
    GLuint blurProgram(int direction, int size, int finish) {
        GLuint &cached = scalarBlur[direction][size / 2][finish];
        if (!cached && direction==0) {
            cached=standaloneProgram(("#version 310 es\n#define FIXED_SIZE "+std::to_string(size)+"\n"+horizontalScalarSource).c_str());
        }
        if (!cached) {
            std::string body = spatialSource;
            const size_t line = body.find('\n');
            body.insert(line + 1, "#define FIXED_SIZE " + std::to_string(size) +
                "\n#define FIXED_DIRECTION " + std::to_string(direction) + "\n#define FIXED_FINISH " + std::to_string(finish) + "\n");
            cached = standaloneProgram(body.c_str());
        }
        return cached;
    }
    GLuint chromaProgram(int direction, int size) {
        GLuint &cached = chroma[direction][size / 2];
        if (!cached) {
            std::string defines = "#version 310 es\n#define KERNEL_SIZE " + std::to_string(size) + "\n";
            defines += direction == 0
                ? "#define GROUP_W 128\n#define GROUP_H 1\n#define DIRECTION 0\n#define TILE_SIZE 152\n"
                : "#define GROUP_W 16\n#define GROUP_H "+std::to_string(chromaRows)+"\n#define DIRECTION 1\n#define TILE_SIZE 640\n";
            std::string body=chromaSource;
            const std::string loop="    for (int j = 1; j <= radius; j++)\n        sum += kernel[radius + j] * (tile[centre - j * stride] + tile[centre + j * stride]);";
            std::string taps;
            for(int j=1;j<=size/2;j++) taps+="    sum += kernel["+std::to_string(size/2+j)+"] * (tile[centre - "+std::to_string(j)+" * stride] + tile[centre + "+std::to_string(j)+" * stride]);\n";
            auto at=body.find(loop);if(at!=std::string::npos)body.replace(at,loop.size(),taps);
            cached = standaloneProgram((defines + body).c_str());
        }
        return cached;
    }
    GLuint standaloneProgram(const char *body) { return compile(nullptr, body); }
    GLuint program(const char *body) { return compile(header, body); }
    GLuint compile(const char *prefix, const char *body) {
        GLuint shader = glCreateShader(GL_COMPUTE_SHADER);
        const char *parts[] = {prefix, body};
        glShaderSource(shader, prefix ? 2 : 1, prefix ? parts : parts + 1, nullptr);
        glCompileShader(shader);
        GLint ok;
        glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[4096];
            glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
            __android_log_print(ANDROID_LOG_ERROR, "LightlyGpu", "%s", log);
            glDeleteShader(shader);
            return 0;
        }
        GLuint p = glCreateProgram();
        glAttachShader(p, shader);
        glLinkProgram(p);
        glDeleteShader(shader);
        glGetProgramiv(p, GL_LINK_STATUS, &ok);
        if (!ok) {
            glDeleteProgram(p);
            return 0;
        }
        return p;
    }
    void integer(GLuint p, const char *name, int value) { glUniform1i(glGetUniformLocation(p, name), value); }
    void finishingMatrices(GLuint program, const double *matrices) {
        float rows[18];
        for (int i = 0; i < 18; ++i) rows[i] = static_cast<float>(matrices[18 + i]);
        glUniform3fv(glGetUniformLocation(program, "lmsToRgbRows"), 3, rows);
        glUniform3fv(glGetUniformLocation(program, "labToLmsRows"), 3, rows + 9);
    }
    bool run(GLuint p, const std::vector<float> &input, int w, int h, void *out, int components = 1,
             bool cached = false, bool fieldsDirty = false, bool surface = false) {
        int slot = 0;
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER,3,buffers[13]);
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[slot]);
        if (cached)
            glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, input.size() * 4, input.data());
        else
            glBufferData(GL_SHADER_STORAGE_BUFFER, input.size() * 4, input.data(), GL_STREAM_DRAW);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[slot]);
        // Every active SSBO binding must be valid, even when a uniform skips its
        // branch. Mali otherwise discards the dispatch; ordinary Effects do not use
        // Working.
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, buffers[12]);
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[slot + 1]);
        if (!cached)
            glBufferData(GL_SHADER_STORAGE_BUFFER, w * h * 4 * components, nullptr, GL_STREAM_READ);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[slot + 1]);
        integer(p, "width", w);
        integer(p, "height", h);
        { // This dispatch helper is used only for finishing images.
            if (fieldsDirty) {
                integer(p, "fieldOnly", 1);
                glDispatchCompute((w * h + 63) / 64, 1, 1);
                glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
            }
            integer(p, "fieldOnly", 0);
        }
        glDispatchCompute((w * h + 63) / 64, 1, 1);
        glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT | GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT);
        if (surface) {
            glFinish();
            GLenum error=glGetError();if(error)__android_log_print(ANDROID_LOG_ERROR,"LightlyGpu","AHB finish GL %x",error);return error==GL_NO_ERROR;
        }
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[slot + 1]);
        void *mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, w * h * 4 * components, GL_MAP_READ_BIT);
        if (!mapped)
            return fail();
        std::memcpy(out, mapped, w * h * 4 * components);
        glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
        return glGetError() == GL_NO_ERROR;
    }
};
std::vector<double> fieldKey(const double *p) {
    std::vector<double> key;
    int geometry = 64 + (int)p[9] * 3;
    for (int j = 0; j < 4; j++) {
        key.push_back(p[32 + j * 5]);
        for (int k = 0; k < 8; k++)
            key.push_back(p[geometry + j * 8 + k]);
    }
    return key;
}
Compute gpu;
struct ReleaseCurrent { ~ReleaseCurrent() { gpu.release(); } };
template <class T> int append(std::vector<float> &v, const T *data, int count, float scale = 1) {
    int offset = v.size();
    if (data) {
        v.resize(offset + count);
        for (int i = 0; i < count; i++)
            v[offset + i] = data[i] * scale;
    }
    return data ? offset : -1;
}
} // namespace
bool gpuFinish(const uint8_t *source, int w, int h, const double *params, int paramCount, const uint8_t *leak,
               const uint8_t *ink, const double *matrices, int64_t generation, std::vector<int8_t> &output, AHardwareBuffer *inputSurface, AHardwareBuffer **outputSurface) {
    static int64_t previous = -1;
    static std::vector<double> cachedGeometry;
    static int cachedSource = 0, cachedLeak = -1, cachedInk = -1;
    static GLint cachedFields[4];
    static int cachedW = 0, cachedH = 0, cachedParamCount = 0, cachedLeakBytes = -1, cachedInkBytes = -1;
    std::lock_guard<std::mutex> lock(gpu.mutex);
    ReleaseCurrent releaseCurrent;
    if (!gpu.current())
        return false;
    GraphicsWork measuredWork;
    SharedImage inputImage, targetImage;
    if (inputSurface && !inputImage.import(gpu.display, inputSurface)) return false;
    if (outputSurface && !targetImage.allocate(gpu.display,w,h)) return false;
    glBindImageTexture(0, outputSurface ? targetImage.texture : gpu.dummyImage, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
    GLuint program = gpu.finishingProgram(params,inputSurface ? 3 : 2,false,outputSurface != nullptr);
    glUseProgram(program);
    gpu.integer(program, "writeSurface", outputSurface ? 1 : 0);
    gpu.integer(program, "resident", inputSurface ? 3 : 2);
    gpu.integer(program, "quantizeInput", 0);
    if (inputSurface) {
        glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D,inputImage.texture);
        gpu.integer(program,"sourceImage",2);
    }
    int n = w * h;
    auto geometry = fieldKey(params);
    const int leakBytes = leak ? (int)(params[5] * params[6]) * 4 : -1;
    const int inkBytes = ink ? (int)(params[20] * params[21]) : -1;
    const bool reusable = previous >= 0 && cachedW == w && cachedH == h &&
        cachedParamCount == paramCount && cachedLeakBytes == leakBytes && cachedInkBytes == inkBytes;
    bool fieldsDirty = !reusable || geometry != cachedGeometry;
    if(!gpu.prepareFields(13,w,h,params,fieldsDirty))return false;
    glUseProgram(program);
    glUniform1iv(glGetUniformLocation(program,"noiseOffset"),8,gpu.noiseCaches[0].offsets);
    glUniform1iv(glGetUniformLocation(program,"sampleOffset"),8,gpu.noiseCaches[0].samples);
    gpu.integer(program,"samplesDirty",gpu.noiseCaches[0].samplesDirty?1:0);
    // Geometry reuse does not mean the packed CPU source has been allocated:
    // hardware-first frames need only its four-byte placeholder. A later identity
    // preset/removal can supply CPU pixels at the same dimensions and geometry.
    const size_t sourceBytes = static_cast<size_t>(n) * 4;
    if (!inputSurface && (!reusable || previous != generation || gpu.packedSourceBytes != sourceBytes)) {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, gpu.buffers[12]);
        if (gpu.packedSourceBytes == sourceBytes) glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, sourceBytes, source);
        else {
            glBufferData(GL_SHADER_STORAGE_BUFFER, sourceBytes, source, GL_DYNAMIC_DRAW);
            gpu.packedSourceBytes = sourceBytes;
        }
    }
    std::vector<float> input;
    input.reserve(reusable ? paramCount + 36 : n * 4 + paramCount + 36);
    gpu.integer(program, "paramsOffset", append(input, params, paramCount));
    gpu.integer(program, "matrixOffset", append(input, matrices, 36));
    gpu.finishingMatrices(program, matrices);
    if (reusable) {
        // Changing the developed pixels does not change grain/vignette geometry.
        // Retain their fields and allocation; upload only the changed image inputs.
        if (previous != generation) {
            std::vector<float> pixels;
            glBindBuffer(GL_SHADER_STORAGE_BUFFER, gpu.buffers[0]);
            if (leak) {
                pixels.clear(); append(pixels, leak, leakBytes, 1.f / 255);
                glBufferSubData(GL_SHADER_STORAGE_BUFFER, cachedLeak * sizeof(float), pixels.size() * sizeof(float), pixels.data());
            }
            if (ink) {
                pixels.clear(); append(pixels, ink, inkBytes, 1.f / 255);
                glBufferSubData(GL_SHADER_STORAGE_BUFFER, cachedInk * sizeof(float), pixels.size() * sizeof(float), pixels.data());
            }
        }
        gpu.integer(program, "sourceOffset", cachedSource);
        gpu.integer(program, "leakOffset", cachedLeak);
        gpu.integer(program, "inkOffset", cachedInk);
        glUniform1iv(glGetUniformLocation(program, "fieldOffset"), 4, cachedFields);
        gpu.integer(program, "asLab", 0);
        if (!outputSurface) output.resize(n * 4);
        bool ok = gpu.run(program, input, w, h, output.data(), 1, true, fieldsDirty, outputSurface != nullptr);
        if (ok && outputSurface) *outputSurface = targetImage.detach();
        if (ok) {
            cachedGeometry = geometry;
            previous = generation;
        } else
            previous = -1;
        return ok;
    }
    gpu.integer(program, "sourceOffset", cachedSource = 0);
    GLint offsets[4];
    for (int j = 0; j < 4; j++) {
        offsets[j] = cachedFields[j] = j*n;
    }
    glUniform1iv(glGetUniformLocation(program, "fieldOffset"), 4, offsets);
    gpu.integer(program, "leakOffset",
                cachedLeak = append(input, leak, (int)(params[5] * params[6]) * 4, 1.f / 255));
    gpu.integer(program, "inkOffset",
                cachedInk = append(input, ink, (int)(params[20] * params[21]), 1.f / 255));
    if (!outputSurface) output.resize(n * 4);
    bool ok = gpu.run(program, input, w, h, output.data(), 1, false, fieldsDirty, outputSurface != nullptr);
    if (ok && outputSurface) *outputSurface = targetImage.detach();
    previous = ok ? generation : -1;
    if (ok) {
        cachedGeometry = geometry;
        cachedW = w; cachedH = h; cachedParamCount = paramCount;
        cachedLeakBytes = leakBytes; cachedInkBytes = inkBytes;
    }
    return ok;
}
bool gpuDevelop(const uint8_t *source, int w, int h, const float *autoLut, int autoSize, const float *look,
                int lookSize, float strength, bool asLab, const double *params, int paramCount, const double *matrices,
                const double *spatial, int spatialCount, int64_t generation, std::vector<int8_t> &output, AHardwareBuffer *inputSurface, AHardwareBuffer **outputSurface, const std::function<const uint8_t *()> &loadSource, const uint8_t *leak, const uint8_t *ink) {
    auto entered = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(gpu.mutex);
    ReleaseCurrent releaseCurrent;
    for (int j = 0; j < 5; j++)
        if (spatial[10 + j] > 256)
            return false;
    if (!gpu.current())
        return false;
    std::vector<int8_t> sourceCopy;
    if (inputSurface) {
        if (!gpuReadSurface(inputSurface,w,h,sourceCopy)) return false;
        source=reinterpret_cast<const uint8_t *>(sourceCopy.data());
    }
    GraphicsWork measuredWork;
    SharedImage targetImage;
    if (outputSurface && !targetImage.allocate(gpu.display,w,h)) return false;
    glBindImageTexture(0, outputSurface ? targetImage.texture : gpu.dummyImage, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
    // Separate resident buffers: immutable photo/finishing inputs, working
    // planes, auxiliary planes, spatial constants, and packed output. No CPU
    // readback between stages.
    static int64_t previous = -1;
    static std::vector<double> cachedGeometry;
    static int sourceOffset = 0, leakOffset = -1, inkOffset = -1;
    static GLint fieldOffsets[4];
    static int allocatedN = 0, allocatedAux = 0;
    static int64_t colourGeneration = -1;
    static int colourWidth = 0, colourHeight = 0;
    static std::vector<float> cachedAuto, cachedLook;
    const size_t autoCount = autoLut ? autoSize * autoSize * autoSize * 4 : 0;
    const size_t lookCount = look ? lookSize * lookSize * lookSize * 4 : 0;
    const bool colourDirty = colourGeneration != generation || colourWidth != w || colourHeight != h ||
        cachedAuto.size() != autoCount || cachedLook.size() != lookCount ||
        (autoCount && std::memcmp(cachedAuto.data(), autoLut, autoCount * sizeof(float))) ||
        (lookCount && std::memcmp(cachedLook.data(), look, lookCount * sizeof(float)));
    auto geometry = fieldKey(params);
    bool fieldsDirty = previous != generation || geometry != cachedGeometry;
    int n = w * h, bw = spatial[15], bh = spatial[16], low = bw * bh, auxSize = 2 * low + 2 * n;
    auto bind = [&](int binding, int slot) {
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, binding, gpu.buffers[slot]);
    };
    auto upload = [&](int slot, const void *data, size_t bytes) {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, gpu.buffers[slot]);
        glBufferData(GL_SHADER_STORAGE_BUFFER, bytes, data, GL_DYNAMIC_DRAW);
    };
    std::vector<float> input;
    append(input, params, paramCount);
    append(input, matrices, 36);
    if (previous != generation) {
        if(!source && loadSource)source=loadSource();
        if(!source)return false;
        sourceOffset = append(input, source, n * 4, 1.f / 255);
        leakOffset = leak ? append(input, leak, int(params[5] * params[6]) * 4, 1.f / 255) : -1;
        inkOffset = ink ? append(input, ink, int(params[20] * params[21]), 1.f / 255) : -1;
        for (int j = 0; j < 4; j++) {
            fieldOffsets[j] = j*n;
        }
        upload(6, input.data(), input.size() * 4);
        previous = generation;
    } else {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, gpu.buffers[6]);
        glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, input.size() * 4, input.data());
    }
    if (allocatedN != n) {
        upload(7, nullptr, n * 3 * 4);
        upload(10, nullptr, n * 4);
        upload(11, nullptr, n * 6 * 4);
        allocatedN = n;
    }
    if (allocatedAux != auxSize) {
        upload(8, nullptr, auxSize * 4);
        allocatedAux = auxSize;
    }
    std::vector<float> config;
    append(config, spatial, spatialCount);
    upload(9, config.data(), config.size() * 4);
    GLuint program = gpu.global;
    glUseProgram(program);
    bind(0, 6);
    bind(1, 11);
    bind(2, 11);
    gpu.integer(program, "width", w);
    gpu.integer(program, "height", h);
    gpu.integer(program, "sourceOffset", sourceOffset);
    gpu.integer(program, "autoSize", autoSize);
    gpu.integer(program, "lookSize", lookSize);
    gpu.integer(program, "asLab", asLab ? 1 : 0);
    glUniform1f(glGetUniformLocation(program, "lookStrength"), strength);
    const float identity[] = {0, 0, 0, 1};
    for (int j = 0; colourDirty && j < 2; j++) {
        const float *pixels = j == 0 ? autoLut : look;
        int size = pixels ? (j == 0 ? autoSize : lookSize) : 1;
        glActiveTexture(GL_TEXTURE0 + j);
        glBindTexture(GL_TEXTURE_3D, gpu.textures[j]);
        glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA32F, size, size, size, 0, GL_RGBA, GL_FLOAT,
                     pixels ? pixels : identity);
        gpu.integer(program, j == 0 ? "autoTable" : "lookTable", j);
    }
    const bool profiling = profileNext.exchange(false);
    auto lastTime = std::chrono::steady_clock::now();
    if (profiling) __android_log_print(ANDROID_LOG_INFO, "LightlyGpu", "setup %.2fms",
        std::chrono::duration<double,std::milli>(lastTime-entered).count());
    int dispatchIndex = 0;
    auto dispatch = [&](int count, int rows = 0, int groupW = 16, int groupH = 8) {
        if (rows) glDispatchCompute((count + groupW - 1) / groupW, (rows + groupH - 1) / groupH, 1);
        else glDispatchCompute((count + 63) / 64, 1, 1);
        glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
        // Bound each normal-priority queue submission so UI composition can run
        // between dependent compute batches instead of waiting for the whole image.
        if (!profiling && gpu.boundedBatches && ++dispatchIndex % (n <= 1000000 ? 6 : 3) == 0) glFinish();
        if (profiling) {
            glFinish();
            auto now = std::chrono::steady_clock::now();
            __android_log_print(ANDROID_LOG_INFO, "LightlyGpu", "stage %d program %u %.2fms", dispatchIndex++,
                                program, std::chrono::duration<double, std::milli>(now - lastTime).count());
            lastTime = now;
        }
    };
    if (colourDirty) {
        gpu.integer(program, "cacheOperation", 0);
        dispatch(n);
    }
    program=gpu.blend[asLab?1:0];glUseProgram(program);
    gpu.integer(program,"width",w);gpu.integer(program,"height",h);
    glUniform1f(glGetUniformLocation(program,"lookStrength"),strength);
    bind(1, 7);
    dispatch(n);
    if (asLab) {
        program = gpu.spatial;
        glUseProgram(program);
        bind(0, 9);
        bind(1, 7);
        bind(2, 8);
        gpu.integer(program, "width", w);
        gpu.integer(program, "height", h);
        gpu.integer(program, "bw", bw);
        gpu.integer(program, "bh", bh);
        gpu.integer(program, "factor", spatial[9]);
        gpu.integer(program, "blurBase", 2 * low + n);
        auto integer = [&](const char *name, int value) { gpu.integer(program, name, value); };
        auto scalar = [&](const char *name, float value) {
            glUniform1f(glGetUniformLocation(program, name), value);
        };
        int offsets[5];
        offsets[0] = 24;
        for (int j = 1; j < 5; j++)
            offsets[j] = offsets[j - 1] + spatial[9 + j];
        auto blur = [&](int kernel, int channel, bool base, int finish = 0) {
            if (!base && spatial[10 + kernel] <= 25) {
                for (int d = 0; d < 2; d++) {
                    program = gpu.blurProgram(d, int(spatial[10 + kernel]), d == 0 ? 0 : finish);
                    if (!program) { program = gpu.spatial; glUseProgram(program); break; }
                    glUseProgram(program);
                    integer("width", w); integer("height", h); integer("bw", bw); integer("bh", bh);
                    integer("factor", spatial[9]); integer("blurFinish", d == 0 ? 0 : finish);
                    integer("sourceKind", d == 0 ? 0 : 1);
                    integer("sourceBase", d == 0 ? channel * n : 2 * low);
                    integer("targetBase", d == 0 ? 2 * low : 2 * low + n);
                    scalar("detailScale", spatial[0]); scalar("weight", spatial[1]);
                    scalar("clarity", spatial[3]); scalar("textureAmount", spatial[4]);
                    scalar("threshold", spatial[5]); scalar("sharpen", spatial[8]);
                    glUniform1fv(glGetUniformLocation(program, "kernel"), int(spatial[10 + kernel]), config.data() + offsets[kernel]);
                    dispatch(n);
                    if (d == 1) { program = gpu.spatial; glUseProgram(program); return; }
                }
            }
            integer("operation", 1);
            integer("blurFinish", 0);
            glUniform1fv(glGetUniformLocation(program, "kernel"), int(spatial[10 + kernel]),
                         config.data() + offsets[kernel]);
            integer("kernelSize", spatial[10 + kernel]);
            integer("direction", 0);
            integer("sourceKind", base ? 3 : 0);
            integer("sourceBase", base ? 0 : channel * n);
            integer("targetBase", base ? low : 2 * low);
            dispatch(base ? low : n);
            integer("direction", 1);
            integer("blurFinish", finish);
            integer("sourceKind", base ? 3 : 1);
            integer("sourceBase", base ? low : 2 * low);
            integer("targetBase", base ? 0 : 2 * low + n);
            dispatch(base ? low : n);
        };
        if (spatial[3] != 0) {
            integer("operation", 0);
            dispatch(low);
            blur(4, 0, true);
        }
        if (spatial[1] != 0) {
            scalar("detailScale", spatial[0]);
            scalar("weight", spatial[1]);
            blur(0, 0, false, 2);
        }
        if (spatial[2] != 0 && spatial[11] <= 25) {
            // Direction-specific tiles share each halo once and avoid allocating unused
            // shared memory. Both retain the reference's tap order and float precision.
            for (int direction = 0; direction < 2; direction++) {
                program = gpu.chromaProgram(direction, int(spatial[11]));
                if (!program) return false;
                glUseProgram(program);
                integer("width", w); integer("height", h);
                integer("kernelSize", spatial[11]);
                glUniform1fv(glGetUniformLocation(program, "kernel"), int(spatial[11]), config.data() + offsets[1]);
                integer("targetBase", 2 * low); integer("sourceBase", 2 * low);
                scalar("weight", spatial[2]);
                dispatch(w, h, direction == 0 ? 128 : 16, direction == 0 ? 1 : gpu.chromaRows);
            }
            program = gpu.spatial;
            glUseProgram(program);
        } else if (spatial[2] != 0) {
            // Chroma shares one kernel. Process a/b together and fuse the vertical
            // pass with its final blend; both channels retain the reference
            // accumulation order.
            integer("operation", 6);
            integer("kernelSize", spatial[11]);
            glUniform1fv(glGetUniformLocation(program, "kernel"), int(spatial[11]),
                         config.data() + offsets[1]);
            integer("direction", 0);
            integer("targetBase", 2 * low);
            dispatch(n);
            integer("direction", 1);
            integer("sourceBase", 2 * low);
            scalar("weight", spatial[2]);
            dispatch(n);
        }
        if (spatial[3] != 0 || spatial[4] != 0) {
            scalar("clarity", spatial[3]);
            scalar("textureAmount", spatial[4]);
            if (spatial[4] != 0) blur(2, 0, false, 4);
            else {
                integer("operation", 4);
                integer("channel", 0);
                dispatch(n);
            }
        }
        if (spatial[8] != 0) {
            scalar("threshold", spatial[5]);
            scalar("edgeScale", spatial[6]);
            scalar("edgeMask", spatial[7]);
            scalar("sharpen", spatial[8]);
            blur(3, 0, false, spatial[7] == 0 ? 5 : 0);
            if (spatial[7] != 0) {
                integer("operation", 5);
                integer("channel", 0);
                dispatch(n);
            }
        }
    }
    if(!gpu.prepareFields(14,w,h,params,fieldsDirty))return false;
    program = gpu.finishingProgram(params,1,asLab,outputSurface != nullptr,spatial[17]!=0);
    glUseProgram(program);
    bind(0, 6);
    bind(1, 10);
    bind(2, 7);
    bind(3, 14);
    glUniform1iv(glGetUniformLocation(program,"noiseOffset"),8,gpu.noiseCaches[1].offsets);
    glUniform1iv(glGetUniformLocation(program,"sampleOffset"),8,gpu.noiseCaches[1].samples);
    gpu.integer(program,"samplesDirty",gpu.noiseCaches[1].samplesDirty?1:0);
    gpu.integer(program, "width", w);
    gpu.integer(program, "height", h);
    gpu.integer(program, "paramsOffset", 0);
    gpu.integer(program, "matrixOffset", paramCount);
    gpu.finishingMatrices(program, matrices);
    gpu.integer(program, "sourceOffset", sourceOffset);
    gpu.integer(program, "resident", 1);
    gpu.integer(program, "quantizeInput", spatial[17]!=0);
    gpu.integer(program, "writeSurface", outputSurface ? 1 : 0);
    gpu.integer(program, "asLab", asLab ? 1 : 0);
    gpu.integer(program, "leakOffset", leakOffset);
    gpu.integer(program, "inkOffset", inkOffset);
    glUniform1iv(glGetUniformLocation(program, "fieldOffset"), 4, fieldOffsets);
    if (fieldsDirty) {
        gpu.integer(program, "fieldOnly", 1);
        dispatch(n);
    }
    gpu.integer(program, "fieldOnly", 0);
    dispatch(n);
    glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT | GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_TEXTURE_FETCH_BARRIER_BIT);
    bool ok = true;
    if (outputSurface) {
        glFinish();
    } else {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, gpu.buffers[10]);
        void *mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, n * 4, GL_MAP_READ_BIT);
        ok = mapped != nullptr;
        if (ok) {
            output.resize(n * 4);
            std::memcpy(output.data(), mapped, n * 4);
            glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
        }
    }
    ok = ok && glGetError() == GL_NO_ERROR;
    if (ok && outputSurface) *outputSurface = targetImage.detach();
    if (profiling) __android_log_print(ANDROID_LOG_INFO, "LightlyGpu", "readback/release %.2fms total %.2fms",
        std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-lastTime).count(),
        std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-entered).count());
    if (ok) {
        cachedGeometry = geometry;
        if (colourDirty) {
            cachedAuto.resize(autoCount);
            cachedLook.resize(lookCount);
            if (autoCount) std::memcpy(cachedAuto.data(), autoLut, autoCount * sizeof(float));
            if (lookCount) std::memcpy(cachedLook.data(), look, lookCount * sizeof(float));
            colourGeneration = generation;
            colourWidth = w;
            colourHeight = h;
        }
    } else {
        previous = -1;
        colourGeneration = -1;
    }
    return ok;
}

bool gpuReadSurface(AHardwareBuffer *surface, int width, int height, std::vector<int8_t> &output) {
    if (!surface) return false;
    AHardwareBuffer_Desc desc{}; AHardwareBuffer_describe(surface,&desc);
    if (desc.width != static_cast<uint32_t>(width) || desc.height != static_cast<uint32_t>(height) ||
        desc.format != AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM) return false;
    void *pixels=nullptr;
    if (AHardwareBuffer_lock(surface,AHARDWAREBUFFER_USAGE_CPU_READ_RARELY,-1,nullptr,&pixels) != 0) return false;
    output.resize(width*height*4);
    for(int y=0;y<height;y++) std::memcpy(output.data()+y*width*4,
        static_cast<const uint8_t *>(pixels)+y*desc.stride*4,width*4);
    AHardwareBuffer_unlock(surface,nullptr);
    return true;
}

bool gpuReady() {
    std::lock_guard<std::mutex> lock(gpu.mutex);
    ReleaseCurrent releaseCurrent;
    bool ok = gpu.current();
    return ok;
}

void gpuProfileNext() { profileNext = true; }
