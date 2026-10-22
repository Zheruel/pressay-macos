#include "PressayNative.h"
#include "vendor/transcribe.h"
#include "vendor/nemo_asr.h"
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <memory>

struct pressay_asr {
    void *library = nullptr;
    transcribe_model *model = nullptr;
    transcribe_session *session = nullptr;
    nemo_speech_asr_recognizer *orukeet = nullptr;
    std::string text;
    template<class T> T symbol(const char *name) {
        auto p = dlsym(library, name);
        if (!p) throw std::runtime_error(std::string("Missing runtime symbol: ") + name);
        return reinterpret_cast<T>(p);
    }
    ~pressay_asr() {
        if (session) symbol<decltype(&transcribe_session_free)>("transcribe_session_free")(session);
        if (model) symbol<decltype(&transcribe_model_free)>("transcribe_model_free")(model);
        if (orukeet) symbol<decltype(&nemo_speech_asr_destroy)>("nemo_speech_asr_destroy")(orukeet);
        // ggml owns process-global backend state; the process is the lifetime
        // boundary. Do not dlclose code while its backend threads may exist.
    }
};
static void message(char *out, size_t n, const char *text) {
    if (n) std::snprintf(out, n, "%s", text);
}
#define CALL(name) h->symbol<decltype(&name)>(#name)
pressay_asr *pressay_asr_load(const char *library, const char *model, int is_orukeet,
                             char *error, size_t error_size) {
    try {
        auto h = std::make_unique<pressay_asr>();
        h->library = dlopen(library, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        if (!h->library) throw std::runtime_error(dlerror());
        if (is_orukeet) {
            nemo_speech_asr_backend_config backend{};
            backend.size = sizeof(backend); backend.gpu = 0;
            nemo_speech_asr_model_config config{};
            config.size = sizeof(config); config.path = model;
            nemo_speech_asr_recognizer_config params{};
            params.size = sizeof(params); params.backend = &backend; params.model = &config;
            if (CALL(nemo_speech_asr_create)(&params, &h->orukeet) != NEMO_SPEECH_ASR_OK)
                throw std::runtime_error(CALL(nemo_speech_asr_last_error)());
        } else {
            if (std::strcmp(CALL(transcribe_version)(), TRANSCRIBE_VERSION) != 0)
                throw std::runtime_error("Incompatible transcription runtime");
            transcribe_model_load_params params;
            CALL(transcribe_model_load_params_init)(&params);
            if (CALL(transcribe_model_load_file)(model, &params, &h->model) != TRANSCRIBE_OK)
                throw std::runtime_error("Could not load transcription model");
            transcribe_session_params session;
            CALL(transcribe_session_params_init)(&session);
            if (CALL(transcribe_session_init)(h->model, &session, &h->session) != TRANSCRIBE_OK)
                throw std::runtime_error("Could not create transcription session");
        }
        return h.release();
    } catch (const std::exception &e) { message(error, error_size, e.what()); return nullptr; }
}
int pressay_asr_run(pressay_asr *h, const float *pcm, size_t count, const char **text,
                    char *error, size_t error_size) {
    *text = nullptr;
    try {
        if (h->orukeet) {
            auto options = CALL(nemo_speech_asr_recognition_options_default)();
            options.enable_word_time_offsets = true;
            options.enable_automatic_punctuation = true;
            options.interim_results = true;
            nemo_speech_asr_result *result = nullptr;
            auto status = CALL(nemo_speech_asr_recognize_f32)(h->orukeet, &options, pcm, count, 16000, &result);
            if (status != NEMO_SPEECH_ASR_OK) {
                if (result) CALL(nemo_speech_asr_result_destroy)(result);
                throw std::runtime_error(CALL(nemo_speech_asr_last_error)());
            }
            const char *value = CALL(nemo_speech_asr_result_transcript)(result, 0);
            h->text = value ? value : "";
            CALL(nemo_speech_asr_result_destroy)(result);
        } else {
            transcribe_run_params params;
            CALL(transcribe_run_params_init)(&params);
            params.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
            params.language = "en";
            // Deliberately leave vocabulary/prompt unset: the full glossary
            // degraded MOSS accuracy in the held-out benchmark.
            auto status = CALL(transcribe_run)(h->session, pcm, static_cast<int>(count), &params);
            const char *value = CALL(transcribe_full_text)(h->session);
            h->text = value ? value : "";
            *text = h->text.c_str();
            if (status != TRANSCRIBE_OK) {
                message(error, error_size, CALL(transcribe_status_string)(status));
                return status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED || status == TRANSCRIBE_ERR_OUTPUT_REPETITION ? 2 : 1;
            }
        }
        *text = h->text.c_str();
        return 0;
    } catch (const std::exception &e) { message(error, error_size, e.what()); return 1; }
}
void pressay_asr_free(pressay_asr *h) { delete h; }
