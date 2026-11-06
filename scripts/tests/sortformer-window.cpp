// Compare the bounded frontend to the original whole-clip implementation.
// Build against the patched pinned source, including transcribe-mel.cpp itself.
#include "transcribe-mel.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>
// The test explicitly passes two threads; satisfy the unused auto-thread fallback.
namespace transcribe { int default_n_threads(int) { return 2; } }
int main() {
    transcribe::MelConfig cfg;
    cfg.normalize = "none";
    cfg.pad_mode = "constant";
    cfg.nemo_seq_len_ceil = true;
    transcribe::MelFrontend mel(cfg);
    std::mt19937 random(1234);
    float max_difference = 0;
    size_t checked = 0;
    for (size_t length : {size_t(321), size_t(16000), size_t(480001), size_t(1600003)}) {
        for (int signal = 0; signal < 3; ++signal) {
            std::vector<float> pcm(length);
            for (size_t i = 0; i < length; ++i)
                pcm[i] = signal == 0 ? 0 : signal == 1 ? float(std::sin(i * 0.021) * 0.7) : float(int(random() % 20001) - 10000) / 10000;
            std::vector<float> whole;
            int bins = 0, frames = 0;
            if (mel.compute(pcm.data(), pcm.size(), whole, bins, frames, 2) != TRANSCRIBE_OK) return 1;
            for (int window : {1, 17, 3040}) {
                for (int first = 0; first < frames; first += window) {
                    const int count = std::min(window, frames - first);
                    std::vector<float> bounded;
                    if (mel.compute_window(pcm.data(), pcm.size(), first, count, bounded, 2) != TRANSCRIBE_OK) return 2;
                    for (int bin = 0; bin < bins; ++bin) for (int t = 0; t < count; ++t) {
                        const float actual = bounded[size_t(bin) * count + t];
                        const float expected = whole[size_t(bin) * frames + first + t];
                        const float difference = std::abs(actual - expected);
                        max_difference = std::max(max_difference, difference);
                        ++checked;
                        if (difference > 0.000002f) {
                            std::fprintf(stderr, "mel mismatch: n=%zu frame=%d bin=%d %.9g != %.9g\n", length, first+t, bin, actual, expected);
                            return 3;
                        }
                    }
                }
            }
        }
    }
    std::printf("Compared %zu mel values; maximum absolute difference %.9g\n", checked, max_difference);
}
