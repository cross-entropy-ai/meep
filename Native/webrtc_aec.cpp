#include "webrtc_aec.h"
#include <vector>
#include "api/scoped_refptr.h"
#include "modules/audio_processing/include/audio_processing.h"

struct wrtc_apm {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::StreamConfig cfg;
    std::vector<int16_t> ref;
    int frame;
};

extern "C" wrtc_apm *wrtc_apm_create(int rate, int ns_level) {
    auto *s = new wrtc_apm{webrtc::AudioProcessingBuilder().Create(), webrtc::StreamConfig(rate, 1), {}, rate / 100};
    if (!s->apm) { delete s; return nullptr; }
    webrtc::AudioProcessing::Config c;
    c.echo_canceller.enabled = true;
    c.echo_canceller.mobile_mode = false;
    c.high_pass_filter.enabled = true;
    c.noise_suppression.enabled = ns_level > 0;
    using NS = webrtc::AudioProcessing::Config::NoiseSuppression;
    const NS::Level levels[] = {NS::kLow, NS::kLow, NS::kModerate, NS::kHigh, NS::kVeryHigh};
    c.noise_suppression.level = levels[ns_level < 0 ? 0 : (ns_level > 4 ? 4 : ns_level)];
    c.gain_controller1.enabled = false;   // offline: no analog mic gain to control
    c.gain_controller2.enabled = false;
    s->apm->ApplyConfig(c);
    s->ref.resize(s->frame);
    return s;
}

extern "C" int wrtc_apm_frame_size(const wrtc_apm *s) { return s->frame; }

extern "C" int wrtc_apm_process(wrtc_apm *s, const int16_t *ref, int16_t *mic) {
    std::copy(ref, ref + s->frame, s->ref.begin());
    int e = s->apm->ProcessReverseStream(s->ref.data(), s->cfg, s->cfg, s->ref.data());
    if (e != 0) return e;
    s->apm->set_stream_delay_ms(0);  // tracks are pre-aligned; AEC3 estimates the residual delay itself
    return s->apm->ProcessStream(mic, s->cfg, s->cfg, mic);
}

extern "C" void wrtc_apm_destroy(wrtc_apm *s) { delete s; }
