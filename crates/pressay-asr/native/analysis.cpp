// Analysis adapter for the pinned transcribe.cpp 0.4 ABI. No C++ exception crosses FFI.
#include "transcribe.h"
#include "transcribe/vad.h"
#include "transcribe/diarize.h"
#include "transcribe/sortformer.h"
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <dlfcn.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <memory>
#include <vector>
#include <cmath>
// Keep the runtime a process-local plugin, including on Windows. Only load an
// absolute application-owned path; dependencies resolve beside the plugin or
// from Windows system directories, never the current working directory.
static void *open_library(const char *path) {
#ifdef _WIN32
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (!count) throw std::runtime_error("Invalid runtime path");
    std::vector<wchar_t> wide(static_cast<size_t>(count));
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide.data(), count);
    auto library = LoadLibraryExW(wide.data(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!library) throw std::runtime_error("Could not load transcription runtime (Windows error "
        + std::to_string(GetLastError()) + ")");
    return reinterpret_cast<void *>(library);
#else
    int flags = RTLD_NOW | RTLD_LOCAL;
#ifdef __APPLE__
    flags |= RTLD_FIRST;
#endif
    auto library = dlopen(path, flags);
    if (!library) throw std::runtime_error(dlerror());
    return library;
#endif
}
static void *find_symbol(void *library, const char *name) noexcept {
#ifdef _WIN32
    return reinterpret_cast<void *>(GetProcAddress(reinterpret_cast<HMODULE>(library), name));
#else
    return dlsym(library, name);
#endif
}


struct Analysis {
    void *library = nullptr;
    transcribe_model *model = nullptr;
    transcribe_vad_session *vad[2] = {};
    transcribe_diarize_session *diarize = nullptr;
    template<class T> T symbol(const char *name) {
        auto p = find_symbol(library, name);
        if (!p) throw std::runtime_error(std::string("Missing analysis runtime symbol: ") + name);
        return reinterpret_cast<T>(p);
    }
    ~Analysis() noexcept {
        auto vf = reinterpret_cast<decltype(&transcribe_vad_session_free)>(find_symbol(library, "transcribe_vad_session_free"));
        for (auto v : vad) if (v && vf) vf(v);
        auto df = reinterpret_cast<decltype(&transcribe_diarize_session_free)>(find_symbol(library, "transcribe_diarize_session_free"));
        if (diarize && df) df(diarize);
        auto mf = reinterpret_cast<decltype(&transcribe_model_free)>(find_symbol(library, "transcribe_model_free"));
        if (model && mf) mf(model);
        // ggml global backend lifetime ends with this worker, never dlclose.
    }
};
#define CALL(name) h->symbol<decltype(&name)>(#name)
static void check(int status) {
    if (status != 0) throw std::runtime_error("Analysis runtime failed with status " + std::to_string(status));
}
static void error_message(char *out, size_t n, const std::exception &e) {
    if (n) std::snprintf(out, n, "%s", e.what());
}
extern "C" Analysis *pressay_analysis_load(const char *library, const char *model, bool is_vad, char *error, size_t error_size) {
    try {
        auto h = std::make_unique<Analysis>();
        h->library = open_library(library);
        if (std::strcmp(CALL(transcribe_version)(), TRANSCRIBE_VERSION) != 0)
            throw std::runtime_error("Incompatible analysis runtime version");
        transcribe_model_load_params p;
        CALL(transcribe_model_load_params_init)(&p);
        // Silero's streaming reference uses CPU for stable per-frame output.
        if (is_vad) p.backend = TRANSCRIBE_BACKEND_CPU;
        else if (h->symbol<int (*)()>("pressay_sortformer_windowed_frontend_version")() != 1)
            throw std::runtime_error("Speaker separation requires the bundled windowed analysis runtime");
        check(CALL(transcribe_model_load_file)(model, &p, &h->model));
        if (is_vad) {
            transcribe_vad_info info;
            CALL(transcribe_vad_info_init)(&info);
            check(CALL(transcribe_vad_get_info)(h->model, &info));
            if (info.sample_rate != 16000 || info.frame_samples != 512)
                throw std::runtime_error("Unsupported VAD frame format");
            transcribe_vad_session_params sp;
            CALL(transcribe_vad_session_params_init)(&sp);
            sp.n_threads = 1;
            for (auto &v : h->vad) check(CALL(transcribe_vad_session_init)(h->model, &sp, &v));
        } else {
            transcribe_diarize_session_params sp;
            CALL(transcribe_diarize_session_params_init)(&sp);
            check(CALL(transcribe_diarize_session_init)(h->model, &sp, &h->diarize));
        }
        return h.release();
    } catch (const std::exception &e) { error_message(error, error_size, e); return nullptr; }
}
extern "C" void pressay_analysis_free(Analysis *h) { delete h; }
extern "C" int pressay_analysis_vad(Analysis *h, int track, int op, const float *pcm, int n,
    float *out, int capacity, int *count, int64_t *first, char *error, size_t error_size) {
    try {
        if (track < 0 || track > 1 || !h->vad[track]) throw std::runtime_error("Invalid VAD track or mode");
        auto v = h->vad[track];
        if (op == 2) { CALL(transcribe_vad_stream_reset)(v); *count = 0; *first = 0; return 0; }
        if (op == 1) check(CALL(transcribe_vad_stream_flush)(v));
        else check(CALL(transcribe_vad_stream_feed)(v, pcm, n));
        transcribe_vad_result result;
        CALL(transcribe_vad_result_init)(&result);
        check(CALL(transcribe_vad_get_result)(v, &result));
        if (result.n_probs < 0 || result.n_probs > capacity || result.first_frame < 0)
            throw std::runtime_error("Invalid VAD output length");
        *count = result.n_probs; *first = result.first_frame;
        if (*count) std::memcpy(out, CALL(transcribe_vad_probs)(v), *count * sizeof(float));
        return 0;
    } catch (const std::exception &e) { error_message(error, error_size, e); return -1; }
}
// Read-only mapping: PCM is never copied into a whole-recording heap vector.
struct Mapping {
    void *data = nullptr;
    size_t bytes = 0;
#ifdef _WIN32
    HANDLE file = INVALID_HANDLE_VALUE, mapping = nullptr;
#else
    int fd = -1;
#endif
    ~Mapping() {
#ifdef _WIN32
        if (data) UnmapViewOfFile(data);
        if (mapping) CloseHandle(mapping);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
#else
        if (data) munmap(data, bytes);
        if (fd >= 0) close(fd);
#endif
    }
    void open(const char *path) {
#ifdef _WIN32
        const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
        if (!count) throw std::runtime_error("Invalid PCM path");
        std::vector<wchar_t> wide(count);
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide.data(), count);
        file = CreateFileW(wide.data(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        LARGE_INTEGER size;
        if (file == INVALID_HANDLE_VALUE || GetFileType(file) != FILE_TYPE_DISK || !GetFileSizeEx(file, &size) || size.QuadPart <= 0)
            throw std::runtime_error("Cannot open meeting PCM");
        bytes = static_cast<size_t>(size.QuadPart);
#else
        fd = ::open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0)
            throw std::runtime_error("Cannot open meeting PCM");
        bytes = static_cast<size_t>(st.st_size);
#endif
        if (bytes % sizeof(float) || bytes > size_t(8 * 60 * 60 * 16000) * sizeof(float))
            throw std::runtime_error("Optional speaker separation supports recordings up to eight hours");
#ifdef _WIN32
        mapping = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
        if (mapping) data = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0);
#else
        data = mmap(nullptr, bytes, PROT_READ, MAP_PRIVATE, fd, 0);
        if (data == MAP_FAILED) data = nullptr;
#endif
        if (!data) throw std::runtime_error("Cannot map meeting PCM");
    }
};
extern "C" int pressay_analysis_diarize(Analysis *h, const char *path, char *error, size_t error_size) {
    try {
        if (!h->diarize) throw std::runtime_error("Invalid diarization mode");
        Mapping pcm; pcm.open(path);
        transcribe_diarize_params p;
        CALL(transcribe_diarize_params_init)(&p);
        transcribe_sortformer_diarize_ext ext;
        CALL(transcribe_sortformer_diarize_ext_init)(&ext);
        ext.preset = TRANSCRIBE_SORTFORMER_PRESET_VERY_HIGH_LATENCY;
        p.family = &ext.ext;
        check(CALL(transcribe_diarize_run)(h->diarize, static_cast<const float *>(pcm.data), int(pcm.bytes / 4), &p));
        int n = CALL(transcribe_diarize_n_segments)(h->diarize);
        if (n < 0 || n > 100000) throw std::runtime_error("Invalid speaker segment count");
        return n;
    } catch (const std::exception &e) { error_message(error, error_size, e); return -1; }
}
extern "C" int pressay_analysis_segment(Analysis *h, int index, double *start, double *end, int *speaker, float *confidence,
    char *error, size_t error_size) {
    try {
        transcribe_speaker_segment s;
        CALL(transcribe_speaker_segment_init)(&s);
        check(CALL(transcribe_diarize_get_segment)(h->diarize, index, &s));
        if (s.t0_ms < 0 || s.t1_ms <= s.t0_ms || s.speaker_id < 1 || s.speaker_id > 4)
            throw std::runtime_error("Invalid speaker segment");
        *start = s.t0_ms / 1000.0; *end = s.t1_ms / 1000.0; *speaker = s.speaker_id; *confidence = s.p;
        return 0;
    } catch (const std::exception &e) { error_message(error, error_size, e); return -1; }
}
