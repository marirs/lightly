#include "gpu.h"
#include <algorithm>
#include <cstdint>
#include <jni.h>
#include <android/hardware_buffer_jni.h>
#include <vector>
static thread_local bool usedGpu = false;
using std::max;
using std::min;
static jbyte *acquire(JNIEnv *e, jbyteArray a) { return a ? e->GetByteArrayElements(a, nullptr) : nullptr; }
static jfloat *acquire(JNIEnv *e, jfloatArray a) {
    return a ? e->GetFloatArrayElements(a, nullptr) : nullptr;
}
static jdouble *acquire(JNIEnv *e, jdoubleArray a) {
    return a ? e->GetDoubleArrayElements(a, nullptr) : nullptr;
}
static void release(JNIEnv *e, jbyteArray a, jbyte *p, int mode) { e->ReleaseByteArrayElements(a, p, mode); }
static void release(JNIEnv *e, jfloatArray a, jfloat *p, int mode) {
    e->ReleaseFloatArrayElements(a, p, mode);
}
static void release(JNIEnv *e, jdoubleArray a, jdouble *p, int mode) {
    e->ReleaseDoubleArrayElements(a, p, mode);
}
template <class A, class T> struct Array {
    JNIEnv *e;
    A a;
    T *p;
    int mode;
    Array(JNIEnv *e, A a, int mode = JNI_ABORT) : e(e), a(a), p(acquire(e, a)), mode(mode) {}
    ~Array() {
        if (p)
            release(e, a, p, mode);
    }
};
using Bytes = Array<jbyteArray, jbyte>;
using Floats = Array<jfloatArray, jfloat>;
using Doubles = Array<jdoubleArray, jdouble>;

extern "C" JNIEXPORT jbyteArray JNICALL Java_com_lightlylabs_lightly_develop_NativeKernels_finishNative(
    JNIEnv *e, jobject, jbyteArray src, jint w, jint h, jdoubleArray parameters, jbyteArray leakImage,
    jbyteArray inkImage, jdoubleArray matrices, jlong generation) {
#ifdef __ANDROID__
    usedGpu = false;
    Bytes source(e, src), leak(e, leakImage), ink(e, inkImage);
    Doubles p(e, parameters), matrix(e, matrices);
    if (e->ExceptionCheck())
        return nullptr;
    std::vector<int8_t> output;
    if (gpuFinish((uint8_t *)source.p, w, h, p.p, e->GetArrayLength(parameters), (uint8_t *)leak.p,
                  (uint8_t *)ink.p, matrix.p, generation, output)) {
        usedGpu = true;
        jbyteArray result = e->NewByteArray(w * h * 4);
        if (result)
            e->SetByteArrayRegion(result, 0, w * h * 4, output.data());
        return result;
    }
#endif
    return nullptr;
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_lightlylabs_lightly_develop_NativeKernels_developNative(
    JNIEnv *e, jobject, jbyteArray src, jint w, jint h, jfloatArray at, jint an, jfloatArray lt, jint ln,
    jfloat strength, jboolean lab, jdoubleArray parameters, jdoubleArray matrices, jdoubleArray spatial, jlong generation, jbyteArray leakBytes, jbyteArray inkBytes) {
#ifdef __ANDROID__
    usedGpu = false;
    Bytes source(e, src), leak(e, leakBytes), ink(e, inkBytes);
    Floats a(e, at), look(e, lt);
    Doubles p(e, parameters), m(e, matrices), config(e, spatial);
    if (e->ExceptionCheck())
        return nullptr;
    std::vector<int8_t> output;
    if (gpuDevelop((uint8_t *)source.p, w, h, a.p, an, look.p, ln, strength, lab, p.p, e->GetArrayLength(parameters),
                   m.p, config.p, e->GetArrayLength(spatial), generation, output, nullptr, nullptr, {}, (uint8_t *)leak.p, (uint8_t *)ink.p)) {
        usedGpu = true;
        jbyteArray result = e->NewByteArray(w * h * 4);
        if (result)
            e->SetByteArrayRegion(result, 0, w * h * 4, output.data());
        return result;
    }
#endif
    return nullptr;
}

extern "C" JNIEXPORT jboolean JNICALL Java_com_lightlylabs_lightly_develop_NativeKernels_gpuReady(JNIEnv *,
                                                                                                  jobject) {
#ifdef __ANDROID__
    return gpuReady();
#else
    return false;
#endif
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_lightlylabs_lightly_develop_NativeKernels_lastUsedGpu(JNIEnv *, jobject) {
    return usedGpu;
}

extern "C" JNIEXPORT void JNICALL Java_com_lightlylabs_lightly_develop_NativeKernels_profileNext(JNIEnv *,
                                                                                                 jobject) {
    gpuProfileNext();
}

extern "C" JNIEXPORT jobject JNICALL Java_com_lightlylabs_lightly_develop_NativeKernels_finishHardwareNative(
    JNIEnv *e, jobject, jbyteArray src, jobject inputBuffer, jint w, jint h, jdoubleArray parameters,
    jbyteArray leakImage, jbyteArray inkImage, jdoubleArray matrices, jlong generation) {
    usedGpu=false;
    Bytes source(e,src), leak(e,leakImage), ink(e,inkImage);
    Doubles p(e,parameters), matrix(e,matrices);
    if(e->ExceptionCheck()) return nullptr;
    AHardwareBuffer *input=inputBuffer ? AHardwareBuffer_fromHardwareBuffer(e,inputBuffer) : nullptr;
    AHardwareBuffer *output=nullptr;
    std::vector<int8_t> unused;
    if(!gpuFinish((uint8_t *)source.p,w,h,p.p,e->GetArrayLength(parameters),(uint8_t *)leak.p,
        (uint8_t *)ink.p,matrix.p,generation,unused,input,&output)) return nullptr;
    usedGpu=true;
    jobject result=AHardwareBuffer_toHardwareBuffer(e,output);
    AHardwareBuffer_release(output);
    return result;
}
extern "C" JNIEXPORT jobject JNICALL Java_com_lightlylabs_lightly_develop_NativeKernels_developHardwareNative(
    JNIEnv *e, jobject, jbyteArray src, jobject inputBuffer, jint w, jint h, jfloatArray at, jint an,
    jfloatArray lt, jint ln, jfloat strength, jboolean lab, jdoubleArray parameters,
    jdoubleArray matrices, jdoubleArray spatial, jlong generation, jbyteArray leakBytes, jbyteArray inkBytes) {
    usedGpu=false;
    Bytes source(e,nullptr), leak(e,leakBytes), ink(e,inkBytes); source.a=src; Floats a(e,at),look(e,lt);
    Doubles p(e,parameters),m(e,matrices),config(e,spatial);
    if(e->ExceptionCheck()) return nullptr;
    AHardwareBuffer *input=inputBuffer ? AHardwareBuffer_fromHardwareBuffer(e,inputBuffer) : nullptr;
    AHardwareBuffer *output=nullptr;
    std::vector<int8_t> unused;
    if(!gpuDevelop((uint8_t *)source.p,w,h,a.p,an,look.p,ln,strength,lab,p.p,e->GetArrayLength(parameters),
        m.p,config.p,e->GetArrayLength(spatial),generation,unused,input,&output,[&]() -> const uint8_t * { source.p=acquire(e,src); return reinterpret_cast<const uint8_t *>(source.p); }, (uint8_t *)leak.p, (uint8_t *)ink.p)) return nullptr;
    usedGpu=true;
    jobject result=AHardwareBuffer_toHardwareBuffer(e,output);
    AHardwareBuffer_release(output);
    return result;
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_lightlylabs_lightly_develop_NativeKernels_readHardwareNative(
    JNIEnv *e,jobject,jobject buffer,jint w,jint h) {
    AHardwareBuffer *surface=AHardwareBuffer_fromHardwareBuffer(e,buffer);
    std::vector<int8_t> output;
    if(!gpuReadSurface(surface,w,h,output)) return nullptr;
    jbyteArray result=e->NewByteArray(w*h*4);
    if(result) e->SetByteArrayRegion(result,0,w*h*4,output.data());
    return result;
}
