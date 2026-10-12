# Remove's threaded XNNPACK delegate (xnnpack_threads.c). No third-party code: it calls the XNNPACK C API that the
# LiteRT 1.4.2 runtime (libtensorflowlite_jni.so) already exports, looked up at run time with dlsym.
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := lightly_xnnpack
LOCAL_SRC_FILES := xnnpack_threads.c
LOCAL_CFLAGS := -Wall -Werror -O2
LOCAL_LDLIBS := -ldl
include $(BUILD_SHARED_LIBRARY)
