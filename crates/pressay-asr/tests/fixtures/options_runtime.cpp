// Disposable native ABI fixture; no model weights or user audio involved.
#include "transcribe.h"
#include <string>

struct transcribe_model {};
struct transcribe_session { std::string text; };
extern "C" {
const char *transcribe_version() { return TRANSCRIBE_VERSION; }
const char *transcribe_status_string(int) { return "fixture error"; }
void transcribe_model_load_params_init(transcribe_model_load_params *p) { *p = {}; }
void transcribe_session_params_init(transcribe_session_params *p) { *p = {}; }
void transcribe_run_params_init(transcribe_run_params *p) { *p = {}; }
void transcribe_capabilities_init(transcribe_capabilities *p) { *p = {}; }
transcribe_status transcribe_model_load_file(const char *, const transcribe_model_load_params *, transcribe_model **out) {
    *out = new transcribe_model; return TRANSCRIBE_OK;
}
void transcribe_model_free(transcribe_model *m) { delete m; }
transcribe_status transcribe_session_init(transcribe_model *, const transcribe_session_params *, transcribe_session **out) {
    *out = new transcribe_session; return TRANSCRIBE_OK;
}
void transcribe_session_free(transcribe_session *s) { delete s; }
transcribe_status transcribe_model_get_capabilities(const transcribe_model *, transcribe_capabilities *out) {
    static const char *languages[] = { "en", "hr" };
    out->n_languages = 2; out->languages = languages; return TRANSCRIBE_OK;
}
bool transcribe_model_supports(const transcribe_model *, transcribe_feature feature) {
    // Deliberately support ITN only: the adapter must gate the two separately.
    return feature == TRANSCRIBE_FEATURE_ITN;
}
transcribe_status transcribe_run(transcribe_session *s, const float *, int count, const transcribe_run_params *p) {
    s->text = std::string(p->language ? p->language : "auto") + ":" +
        std::to_string(p->pnc) + ":" + std::to_string(p->itn) + ":" + std::to_string(count);
    return TRANSCRIBE_OK;
}
const char *transcribe_full_text(const transcribe_session *s) { return s->text.c_str(); }
}
