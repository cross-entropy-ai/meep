// Minimal C API over WebRTC AudioProcessing (AEC3, noise suppression, AGC2), callable from Swift.
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct wrtc_apm wrtc_apm;
/// rate: 16000/32000/48000. aec: echo cancellation (needs `ref` in wrtc_apm_process).
/// ns_level: 0=off, 1=low, 2=moderate, 3=high, 4=very high. agc: adaptive digital gain (AGC2).
wrtc_apm *wrtc_apm_create(int rate, int aec, int ns_level, int agc);
/// Frame size in samples (10 ms, mono).
int wrtc_apm_frame_size(const wrtc_apm *apm);
/// Process one 10 ms frame. `ref` = what the speakers played (NULL without echo cancellation),
/// `mic` processed in place.
/// Returns 0 on success.
int wrtc_apm_process(wrtc_apm *apm, const int16_t *ref, int16_t *mic);
void wrtc_apm_destroy(wrtc_apm *apm);
#ifdef __cplusplus
}
#endif
