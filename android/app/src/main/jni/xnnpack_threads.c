/*
 * An XNNPACK delegate with a real thread pool, for Edit › Remove (2026-10-12).
 *
 * Why: on the motorola edge 60, LiteRT 1.4.2's Java API applies XNNPACK single-threaded whatever
 * Interpreter.Options.setNumThreads says (one busy thread, its worker threads never scheduled), so LaMa's
 * 231 GMAC took ~16 s on one core. The runtime exports the XNNPACK C API (TfLiteXNNPackDelegateOptionsDefault,
 * TfLiteXNNPackDelegateCreate, TfLiteXNNPackDelegateDelete); creating the delegate through it with num_threads
 * set and handing it to Interpreter.Options.addDelegate runs the same kernels on several cores.
 *
 * The symbols are looked up with dlsym, so nothing links against the AAR: a runtime without them returns 0 and
 * the caller keeps LiteRT's default delegate.
 */
#include <dlfcn.h>
#include <jni.h>
#include <stdint.h>

/*
 * TfLiteXNNPackDelegateOptions begins with `int32_t num_threads` in every LiteRT/TFLite release; the rest of the
 * struct is opaque here. The buffer is larger than any release's struct, so the by-value return of
 * TfLiteXNNPackDelegateOptionsDefault (returned through a caller-provided buffer on every Android ABI, the struct
 * being larger than two registers) always fits, and TfLiteXNNPackDelegateCreate reads only its own fields.
 */
typedef struct {
    int32_t num_threads;
    int32_t field_at_4;      /* LiteRT 1.4.2: 0 by default (a thread strategy); not touched */
    uint32_t flags_at_8;     /* LiteRT 1.4.2: the `flags` bitfield, QS8 | QU8 (3) by default */
    unsigned char opaque_rest[1012];
} __attribute__((aligned(16))) XnnpackOptionsBuffer;

/* The default flags LiteRT 1.4.2 puts at offset 8 (TFLITE_XNNPACK_DELEGATE_FLAG_QS8 | _QU8). Seen anywhere else, the
 * layout is not the one this file knows, and extra flags are not applied. */
#define EXPECTED_DEFAULT_FLAGS 3u

typedef XnnpackOptionsBuffer (*OptionsDefaultFunction)(void);
typedef void *(*CreateFunction)(const XnnpackOptionsBuffer *);
typedef void (*DeleteFunction)(void *);

static void *runtime_symbol(const char *name) {
    /* The Java Interpreter class has loaded the runtime already; this takes another reference, never released. */
    void *runtime = dlopen("libtensorflowlite_jni.so", RTLD_NOW);
    return runtime == NULL ? NULL : dlsym(runtime, name);
}

JNIEXPORT jlong JNICALL
Java_com_lightlylabs_lightly_editor_ThreadedXnnpackDelegate_nativeCreate(JNIEnv *env, jclass type, jint threads, jint extra_flags) {
    (void) env;
    (void) type;
    OptionsDefaultFunction options_default = (OptionsDefaultFunction) runtime_symbol("TfLiteXNNPackDelegateOptionsDefault");
    CreateFunction create = (CreateFunction) runtime_symbol("TfLiteXNNPackDelegateCreate");
    if (options_default == NULL || create == NULL || threads < 1) return 0;
    XnnpackOptionsBuffer options = options_default();
    options.num_threads = threads;
    if (extra_flags != 0) {
        if (options.flags_at_8 != EXPECTED_DEFAULT_FLAGS) return -1;
        options.flags_at_8 |= (uint32_t) extra_flags;
    }
    return (jlong) (intptr_t) create(&options);
}

JNIEXPORT void JNICALL
Java_com_lightlylabs_lightly_editor_ThreadedXnnpackDelegate_nativeDelete(JNIEnv *env, jclass type, jlong handle) {
    (void) env;
    (void) type;
    DeleteFunction delete_delegate = (DeleteFunction) runtime_symbol("TfLiteXNNPackDelegateDelete");
    if (delete_delegate != NULL && handle != 0) delete_delegate((void *) (intptr_t) handle);
}
