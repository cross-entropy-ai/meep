// Minimal C API over WebRTC AudioProcessing (AEC3), callable from Swift.
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct wrtc_apm wrtc_apm;
/// rate: 16000/32000/48000. ns_level: 0=off, 1=low, 2=moderate, 3=high, 4=very high.
wrtc_apm *wrtc_apm_create(int rate, int ns_level);
/// Frame size in samples (10 ms, mono).
int wrtc_apm_frame_size(const wrtc_apm *apm);
/// Process one 10 ms frame. `ref` = what the speakers played, `mic` processed in place.
/// Returns 0 on success.
int wrtc_apm_process(wrtc_apm *apm, const int16_t *ref, int16_t *mic);
void wrtc_apm_destroy(wrtc_apm *apm);
#ifdef __cplusplus
}
#endif
