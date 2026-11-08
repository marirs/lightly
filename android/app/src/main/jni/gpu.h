#pragma once
#include <cstdint>
#include <vector>
#include <functional>
#ifdef __ANDROID__
#include <android/hardware_buffer.h>
bool gpuFinish(const uint8_t *source, int w, int h, const double *params, int paramCount, const uint8_t *leak,
               const uint8_t *ink, const double *matrices, int64_t generation, std::vector<int8_t> &output, AHardwareBuffer *inputSurface = nullptr, AHardwareBuffer **outputSurface = nullptr);
bool gpuDevelop(const uint8_t *source, int w, int h, const float *autoLut, int autoSize, const float *look,
                int lookSize, float strength, bool lab, const double *params, int paramCount, const double *matrices,
                const double *spatial, int spatialCount, int64_t generation, std::vector<int8_t> &output, AHardwareBuffer *inputSurface = nullptr, AHardwareBuffer **outputSurface = nullptr, const std::function<const uint8_t *()> &loadSource = {}, const uint8_t *leak = nullptr, const uint8_t *ink = nullptr);
bool gpuReadSurface(AHardwareBuffer *surface, int width, int height, std::vector<int8_t> &output);
bool gpuReady();
void gpuProfileNext();
#endif
