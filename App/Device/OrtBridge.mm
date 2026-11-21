#import "OrtBridge.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

struct PalmOrtSession {
    Ort::Env environment{ORT_LOGGING_LEVEL_WARNING, "PalmAnnotate"};
    Ort::SessionOptions options;
    Ort::Session session{nullptr};
    Ort::AllocatorWithDefaultOptions allocator;
    std::string inputName;
    std::string outputName;

    explicit PalmOrtSession(const char *model) {
        options.SetIntraOpNumThreads(2);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        session = Ort::Session(environment, model, options);
        inputName = session.GetInputNameAllocated(0, allocator).get();
        outputName = session.GetOutputNameAllocated(0, allocator).get();
    }
};

PalmOrtSession *PalmOrtCreate(const char *model, char *error, size_t errorCapacity) {
    try {
        return new PalmOrtSession(model);
    } catch (const std::exception &exception) {
        std::snprintf(error, errorCapacity, "%s", exception.what());
        return nullptr;
    }
}

void PalmOrtRelease(PalmOrtSession *session) { delete session; }

float *PalmOrtRun(PalmOrtSession *session, float *input, int64_t side,
                  int64_t *shape, size_t *count, char *error, size_t errorCapacity) {
    try {
        const auto info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        const int64_t inputShape[] = {1, 3, side, side};
        auto tensor = Ort::Value::CreateTensor<float>(info, input, 3 * side * side, inputShape, 4);
        const char *inputs[] = {session->inputName.c_str()};
        const char *outputs[] = {session->outputName.c_str()};
        auto result = session->session.Run(Ort::RunOptions{nullptr}, inputs, &tensor, 1, outputs, 1);
        const auto type = result[0].GetTensorTypeAndShapeInfo();
        const auto actualShape = type.GetShape();
        if (actualShape.size() != 3 || type.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
            throw std::runtime_error("Unexpected ONNX detector output.");
        }
        *count = type.GetElementCount();
        for (size_t i = 0; i < 3; i++) shape[i] = actualShape[i];
        auto *buffer = static_cast<float *>(std::malloc(*count * sizeof(float)));
        if (!buffer) throw std::bad_alloc();
        std::memcpy(buffer, result[0].GetTensorData<float>(), *count * sizeof(float));
        return buffer;
    } catch (const std::exception &exception) {
        std::snprintf(error, errorCapacity, "%s", exception.what());
        return nullptr;
    }
}

void PalmOrtFreeOutput(float *output) { std::free(output); }
