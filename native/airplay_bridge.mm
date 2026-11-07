/*
 * airplay_bridge.mm — AirPlay receiver bridge for REditor.
 *
 * Wraps the UxPlay core (native/uxplay/lib, GPLv3/LGPL-2.1+) and its
 * GStreamer renderers (native/uxplay/renderers, GPLv3) behind a small C API.
 * Wiring below is a reduced version of uxplay.cpp: mirroring (H.264) +
 * AAC/ALAC audio only, no HLS, no cover-art rendering.
 *
 * Rendering: the video pipeline uses osxvideosink; the renderer's
 * GstVideoOverlay sync handler embeds it into the NSView supplied through
 * airplay_set_video_view(). Audio plays via osxaudiosink.
 */

#import <Cocoa/Cocoa.h>
#include <CoreAudio/CoreAudio.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <gst/gst.h>

#include "airplay_bridge.h"

extern "C" {
#include "uxplay/lib/raop.h"
#include "uxplay/lib/dnssd.h"
#include "uxplay/lib/logger.h"
#include "uxplay/lib/crypto.h"     /* get_random_bytes */
#include "uxplay/renderers/video_renderer.h"
#include "uxplay/renderers/audio_renderer.h"
}

/* ------------------------------------------------------------------ state */

static std::atomic<bool>  g_running{false};
static ap_event_cb        g_event_cb = nullptr;
static void              *g_event_ctx = nullptr;

static raop_t            *g_raop = nullptr;
static dnssd_t           *g_dnssd = nullptr;
static logger_t          *g_logger = nullptr;

static GMainLoop         *g_loop = nullptr;      /* only touched by loop thread + stop */
static std::thread        g_loop_thread;
static guint              g_video_watch = 0;
static guint              g_audio_watch0 = 0;
static guint              g_audio_watch1 = 0;

static std::atomic<int>   g_open_connections{0};
static uint64_t           g_clock_offset = 0;    /* remote->local NTP offset   */
static double             g_volume = 1.0;        /* client-driven linear volume */
static double             g_user_gain = 1.0;     /* app-side gain multiplier    */

static void apply_volume() {
    double v = g_volume * g_user_gain;
    if (v < 0.0) v = 0.0;
    audio_renderer_set_volume(v);   /* renderer clamps to <= 10.0 */
}

static bool               g_audio_sync = true;
/* Video must run clock-synced (sync=true): buffers then carry the sender's
 * NTP-derived PTS and the sink presents on the same REALTIME clock as the
 * audio sink, so A/V stay aligned and late frames get dropped via QoS.
 * With sync=false the video queue accumulates whenever decode momentarily
 * lags and latency grows unboundedly (no timestamps, no frame dropping). */
static bool               g_video_sync = true;

static void              *g_video_view = nullptr; /* NSView* from Avalonia     */
static std::string        g_server_name;

static unsigned char      g_audio_ct = 0;         /* active stream's codec      */
static std::atomic<bool>  g_audio_active{false};

/* ------------------------------------------------------------- utilities */

static void emit(ap_event_t ev, const char *info = nullptr, int w = 0, int h = 0) {
    ap_event_cb cb = g_event_cb;
    if (cb) cb(g_event_ctx, ev, info, w, h);
}

static void bridge_log_callback(void *cls, int level, const char *msg) {
    (void) cls; (void) level;
    if (msg) emit(AP_EV_LOG, msg);
}

static std::string config_dir() {
    const char *home = getenv("HOME");
    std::string dir = (home ? home : ".");
    dir += "/Library/Application Support/REditor";
    return dir;
}

/* persistent random (locally-administered) MAC = stable AirPlay device id */
static std::string load_or_create_mac() {
    std::string dir = config_dir();
    std::string path = dir + "/airplay_device_id";
    if (FILE *f = fopen(path.c_str(), "r")) {
        char buf[32] = {0};
        if (fgets(buf, sizeof(buf), f) && strlen(buf) >= 17) {
            fclose(f);
            return std::string(buf, 17);
        }
        fclose(f);
    }
    unsigned char rnd[6];
    get_random_bytes(rnd, sizeof(rnd));
    rnd[0] = (rnd[0] & ~0x01) | 0x02;   /* locally administered, unicast */
    char mac[18];
    snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
             rnd[0], rnd[1], rnd[2], rnd[3], rnd[4], rnd[5]);
    std::string cmd = "mkdir -p \"" + dir + "\"";
    if (system(cmd.c_str()) == 0) {
        if (FILE *f = fopen(path.c_str(), "w")) {
            fputs(mac, f);
            fclose(f);
        }
    }
    return std::string(mac);
}

static std::vector<char> parse_hw_addr(const std::string &str) {
    std::vector<char> hw;
    for (size_t i = 0; i + 1 < str.length(); i += 3)
        hw.push_back((char) strtol(str.substr(i, 2).c_str(), nullptr, 16));
    return hw;
}

/* ---------------------------------------------------- clock offset sanity */

#define AP_SANITY_ADOPT_NS  3000000000LL   /* |local - remote| <= 3s to adopt offset */
#define AP_SANITY_SKEW_NS   5000000000LL   /* |pts - local|   >  5s => resync       */

/* The sender->local clock offset is computed from the first packet after a
 * reset. Around pause/resume (iPhone lock/unlock) the client can deliver
 * stale or garbage timestamps; adopting an offset from one poisons every
 * later timestamp (observed: audio scheduled ~5 hours into the future).
 * Only adopt offsets that map the first packet to (roughly) now. */
static bool clock_offset_ensure(uint64_t remote, uint64_t local) {
    if (g_clock_offset) return true;
    int64_t diff = (int64_t) local - (int64_t) remote;
    if (diff > -AP_SANITY_ADOPT_NS && diff < AP_SANITY_ADOPT_NS) {
        g_clock_offset = (uint64_t) diff;
        return true;
    }
    emit(AP_EV_LOG, "dropping packet with bogus timestamp while syncing clock");
    return false;
}

/* Returns the local-domain PTS for a packet, or false to drop it. */
static bool map_pts(uint64_t *remote, uint64_t local) {
    if (!clock_offset_ensure(*remote, local)) return false;
    uint64_t pts = *remote + g_clock_offset;
    int64_t skew = (int64_t) pts - (int64_t) local;
    if (skew > AP_SANITY_SKEW_NS || skew < -AP_SANITY_SKEW_NS) {
        /* client re-based its clock (e.g. across lock/unlock): resync once */
        emit(AP_EV_LOG, "clock skew detected, resyncing sender clock offset");
        g_clock_offset = 0;
        if (!clock_offset_ensure(*remote, local)) return false;
        pts = *remote + g_clock_offset;
    }
    *remote = pts;
    return true;
}

/* ------------------------------------------------ default output tracking */

/* osxaudiosink binds the output device when the pipeline opens and does NOT
 * follow macOS default-output changes (e.g. plugging in headphones) while
 * playing. Listen for the change ourselves and restart the audio renderer,
 * which reopens the sink on the current default device. */
static OSStatus default_output_changed_cb(AudioObjectID, UInt32,
                                          const AudioObjectPropertyAddress *, void *) {
    if (g_running && g_audio_active && g_audio_ct) {
        unsigned char ct = g_audio_ct;
        emit(AP_EV_LOG, "default audio output changed; restarting audio renderer");
        audio_renderer_stop();
        audio_renderer_start(&ct);
        apply_volume();
    }
    return noErr;
}

static const AudioObjectPropertyAddress kDefaultOutputAddr = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

/* ------------------------------------------------------- renderer control */

static void start_video_renderer() {
    videoflip_t flips[2] = { NONE, NONE };
    /* Decoder: force software (avdec_h264) instead of decodebin/vtdec.
     * VideoToolbox corrupts the heap when the stream changes resolution
     * mid-flight (iPhone rotation delivers a new SPS in-band); avdec
     * handles it cleanly. See test: alternate portrait/landscape Annex-B
     * into "h264parse ! vtdec" -> crash; "h264parse ! avdec_h264" -> fine. */
    video_renderer_init(g_logger, g_server_name.c_str(), flips,
                        "h264parse", /* rtp_pipeline */ "",
                        /* decoder */ "avdec_h264", /* converter */ "videoconvert",
                        "osxvideosink", /* sink options */ "",
                        /* fullscreen */ false, g_video_sync,
                        /* h265 */ false, /* coverart */ false,
                        /* playbin_version */ 3, /* uri */ nullptr);
    if (g_video_view)
        video_renderer_set_window_handle((uintptr_t) g_video_view);
    video_renderer_start();
}

/* Runs on the GLib loop thread: rebuild the mirror pipeline after a reset. */
static gboolean rebuild_video_cb(gpointer) {
    if (!g_running) return G_SOURCE_REMOVE;
    if (g_video_watch) { g_source_remove(g_video_watch); g_video_watch = 0; }
    video_renderer_stop();
    video_renderer_destroy();
    start_video_renderer();
    g_clock_offset = 0;
    if (g_loop)
        g_video_watch = video_renderer_listen(g_loop, 0);
    return G_SOURCE_REMOVE;
}

static void request_video_rebuild() {
    if (g_loop) {
        GMainContext *ctx = g_main_loop_get_context(g_loop);
        if (ctx) g_idle_add(rebuild_video_cb, nullptr);
    }
}

/* ------------------------------------------------------------ raop cbs */

extern "C" {

static void cb_conn_init(void *cls) {
    (void) cls;
    g_open_connections++;
    /* start each session at full volume: the client drives it down to its
     * own preference right after connecting. Without this, the -30 dB
     * fade-out an iPhone sends on disconnect would persist silently. */
    g_volume = 1.0;
    apply_volume();
}

static void cb_conn_destroy(void *cls) {
    (void) cls;
    if (g_open_connections > 0) g_open_connections--;
    if (g_open_connections == 0) {
        g_clock_offset = 0;
        audio_renderer_stop();
        g_audio_active = false;
        emit(AP_EV_DISCONNECTED);
    }
}

static void cb_conn_feedback(void *cls) { (void) cls; }

static void cb_conn_reset(void *cls, int reason) {
    (void) cls;
    emit(AP_EV_ERROR, reason == 1 ? "lost connection with client"
                                  : "connection reset");
    request_video_rebuild();
}

static void cb_video_reset(void *cls, reset_type_t type) {
    (void) cls;
    switch (type) {
    case RESET_TYPE_NOHOLD:
    case RESET_TYPE_RTP_SHUTDOWN:
        request_video_rebuild();
        break;
    default:
        break;
    }
}

static int cb_video_set_codec_and_size(void *cls, video_codec_t codec,
                                       unsigned short width_source, unsigned short height_source,
                                       unsigned short x_offset, unsigned short y_offset,
                                       unsigned short width, unsigned short height) {
    (void) cls;
    video_geometry_t geom;
    geom.width_source = width_source;
    geom.height_source = height_source;
    geom.x_offset = x_offset;
    geom.y_offset = y_offset;
    geom.width = width;
    geom.height = height;
    emit(AP_EV_VIDEO_SIZE, nullptr, (int) width, (int) height);
    return video_renderer_choose_codec_and_size(false, codec == VIDEO_CODEC_H265, &geom);
}

static void cb_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    (void) cls; (void) ntp;
    if (!g_running) return;
    uint64_t local = data->ntp_time_local ? data->ntp_time_local : get_local_time();
    if (!map_pts(&data->ntp_time_remote, local)) return;
    int count = 0;
    uint64_t pts_mismatch = 0;
    do {
        pts_mismatch = video_renderer_render_buffer(data->data, &data->data_len,
                                                    &data->nal_count, &data->ntp_time_remote);
        if (pts_mismatch) {
            g_clock_offset += pts_mismatch;
            data->ntp_time_remote += pts_mismatch;
        }
        count++;
    } while (pts_mismatch && count < 10);
}

static void cb_video_pause(void *cls)  { (void) cls; video_renderer_pause();  }
static void cb_video_resume(void *cls) { (void) cls; video_renderer_resume(); }
static void cb_video_flush(void *cls)  { (void) cls; video_renderer_flush();  }

static void cb_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void) cls; (void) ntp;
    if (!g_running) return;
    uint64_t local = data->ntp_time_local ? data->ntp_time_local : get_local_time();
    if (!map_pts(&data->ntp_time_remote, local)) return;
    audio_renderer_render_buffer(data->data, &data->data_len, &data->seqnum,
                                 &data->ntp_time_remote);
}

static void cb_audio_flush(void *cls) { (void) cls; audio_renderer_flush(); }

static double cb_audio_set_client_volume(void *cls) {
    (void) cls;
    /* report current volume back to the client in AirPlay dB */
    return g_volume <= 0.0 ? -144.0 : 20.0 * log10(g_volume);
}

static void cb_audio_set_volume(void *cls, float volume) {
    (void) cls;
    /* AirPlay volume in dB, range [-144 (mute), 0 (max)]. Map dB -> linear
     * directly: -30 dB is quiet (0.0316), NOT silence. (iPhone pushes -30 dB
     * as a fade-out when it stops mirroring; treating that as mute left the
     * pipeline silent forever after a disconnect/reconnect.) */
    if (volume <= -144.0f) {
        g_volume = 0.0;
    } else {
        if (volume < -30.0f) volume = -30.0f;
        if (volume > 0.0f)   volume = 0.0f;
        g_volume = pow(10.0, (double) volume / 20.0);
    }
    apply_volume();
}

static void cb_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf,
                                bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    (void) cls; (void) spf; (void) usingScreen; (void) isMedia; (void) audioFormat;
    g_audio_ct = *ct;
    audio_renderer_start(ct);
    g_audio_active = true;
    /* re-assert volume on the (re)started pipeline: audio_renderer_set_volume
     * is a no-op while no renderer is active, and a previous session's
     * fade-out leaves the volume element at ~0 */
    apply_volume();
}

static void cb_report_client_request(void *cls, char *deviceid, char *model,
                                     char *name, bool *admit) {
    (void) cls; (void) deviceid;
    *admit = true;
    video_renderer_set_device_model(model, name);
    emit(AP_EV_CONNECTED, name);
}

static void cb_register_client(void *cls, const char *device_id,
                               const char *pk_str, const char *name) {
    (void) cls; (void) device_id; (void) pk_str; (void) name;
}

static bool cb_check_register(void *cls, const char *pk_str) {
    (void) cls; (void) pk_str;
    return true;
}

static const char *cb_passwd(void *cls, int *len) {
    (void) cls;
    *len = 0;                    /* no access control */
    return nullptr;
}

static void cb_display_pin(void *cls, char *pin) {
    (void) cls;
    emit(AP_EV_LOG, pin);
}

/* negotiated frame size from the pipeline (also fires on rotation) */
static void on_video_caps(int width, int height, void *ctx) {
    (void) ctx;
    emit(AP_EV_VIDEO_SIZE, nullptr, width, height);
}

/* ---------------------------------------------------- GLib loop thread */

static void loop_thread_fn() {
    while (g_running) {
        g_loop = g_main_loop_new(nullptr, FALSE);
        g_video_watch  = video_renderer_listen(g_loop, 0);
        g_audio_watch0 = audio_renderer_listen(g_loop, 0);
        g_audio_watch1 = audio_renderer_listen(g_loop, 1);
        g_main_loop_run(g_loop);   /* returns on pipeline error or stop */

        if (g_video_watch)  { g_source_remove(g_video_watch);  g_video_watch = 0; }
        if (g_audio_watch0) { g_source_remove(g_audio_watch0); g_audio_watch0 = 0; }
        if (g_audio_watch1) { g_source_remove(g_audio_watch1); g_audio_watch1 = 0; }
        g_main_loop_unref(g_loop);
        g_loop = nullptr;

        if (g_running) {
            /* video pipeline errored (uxplay's bus watch quits the loop):
             * rebuild it and keep serving */
            emit(AP_EV_ERROR, "video pipeline reset");
            video_renderer_stop();
            video_renderer_destroy();
            start_video_renderer();
            g_clock_offset = 0;
        }
    }
}

} /* extern "C" */

/* ----------------------------------------------------------- public API */

extern "C" int airplay_start(const char *server_name, ap_event_cb cb, void *ctx) {
    if (g_running.exchange(true))
        return -1;

    g_event_cb = cb;
    g_event_ctx = ctx;
    g_server_name = (server_name && *server_name) ? server_name : "REditor";

    if (!gstreamer_init()) {
        emit(AP_EV_ERROR, "GStreamer initialization failed (missing plugins?)");
        g_running = false;
        return -2;
    }

    g_logger = logger_init();
    logger_set_level(g_logger, LOGGER_INFO);
    logger_set_callback(g_logger, bridge_log_callback, nullptr);

    audio_renderer_init(g_logger, "osxaudiosink", &g_audio_sync, &g_video_sync, "");
    video_renderer_set_caps_callback(on_video_caps, nullptr);
    start_video_renderer();

    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDefaultOutputAddr,
                                   default_output_changed_cb, nullptr);

    /* persistent device identity + pairing key */
    std::string mac = load_or_create_mac();
    std::string dir = config_dir();
    std::string keyfile = dir + "/airplay.pem";
    std::vector<char> hw_addr = parse_hw_addr(mac);

    /* service discovery via Apple Bonjour (dns_sd) */
    int dnssd_error = 0;
    g_dnssd = dnssd_init(g_server_name.c_str(), (int) g_server_name.length(),
                         hw_addr.data(), (int) hw_addr.size(), /* pin_pw */ 0,
                         &dnssd_error);
    if (!g_dnssd || dnssd_error) {
        emit(AP_EV_ERROR, "failed to initialize Bonjour service discovery");
        airplay_stop();
        return -3;
    }

    /* advertised feature set (uxplay defaults, HLS/h265 off) */
    static const int8_t features[32] = {
        0, 1, 1, 0, 0, 1, 1, 1,   /*  0-7 : mirroring, photos, slideshow ...  */
        0, 1, 1, 1, 1, 1, 1, 1,   /*  8-15: audio, FairPlay, metadata ...     */
        1, 1, 1, 1, 1, 1, 1, 0,   /* 16-23: audio formats, auth ...           */
        0, 1, 0, 1, 1, 0, 1, 0    /* 24-31: legacy pairing, RAOP support      */
    };
    for (int i = 0; i < 32; i++)
        dnssd_set_airplay_features(g_dnssd, i, features[i]);

    /* RAOP / AirPlay server */
    raop_callbacks_t cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.cls = nullptr;
    cbs.conn_init = cb_conn_init;
    cbs.conn_destroy = cb_conn_destroy;
    cbs.conn_feedback = cb_conn_feedback;
    cbs.conn_reset = cb_conn_reset;
    cbs.video_reset = cb_video_reset;
    cbs.video_set_codec_and_size = cb_video_set_codec_and_size;
    cbs.video_process = cb_video_process;
    cbs.video_pause = cb_video_pause;
    cbs.video_resume = cb_video_resume;
    cbs.video_flush = cb_video_flush;
    cbs.audio_process = cb_audio_process;
    cbs.audio_flush = cb_audio_flush;
    cbs.audio_set_client_volume = cb_audio_set_client_volume;
    cbs.audio_set_volume = cb_audio_set_volume;
    cbs.audio_get_format = cb_audio_get_format;
    cbs.report_client_request = cb_report_client_request;
    cbs.register_client = cb_register_client;
    cbs.check_register = cb_check_register;
    cbs.passwd = cb_passwd;
    cbs.display_pin = cb_display_pin;

    g_raop = raop_init(&cbs);
    if (!g_raop) {
        emit(AP_EV_ERROR, "raop_init failed");
        airplay_stop();
        return -4;
    }
    raop_set_log_callback(g_raop, bridge_log_callback, nullptr);
    raop_set_log_level(g_raop, LOGGER_INFO);

    if (raop_init2(g_raop, /* nohold */ 0, mac.c_str(), keyfile.c_str())) {
        emit(AP_EV_ERROR, "raop_init2 failed");
        airplay_stop();
        return -5;
    }

    unsigned short tcp[3] = {0, 0, 0};   /* 0 = dynamically assigned */
    unsigned short udp[3] = {0, 0, 0};
    raop_set_tcp_ports(g_raop, tcp);
    raop_set_udp_ports(g_raop, udp);

    unsigned short raop_port = raop_get_port(g_raop);
    raop_start_httpd(g_raop, &raop_port);
    raop_set_port(g_raop, raop_port);
    raop_set_dnssd(g_raop, g_dnssd);

    if (dnssd_register_raop(g_dnssd, raop_port) ||
        dnssd_register_airplay(g_dnssd, raop_port)) {
        emit(AP_EV_ERROR, "Bonjour service registration failed "
                          "(check Local Network permission)");
        airplay_stop();
        return -6;
    }

    g_loop_thread = std::thread(loop_thread_fn);
    emit(AP_EV_WAITING);
    return 0;
}

extern "C" void airplay_stop(void) {
    if (!g_running.exchange(false))
        return;

    if (g_loop) g_main_loop_quit(g_loop);
    if (g_loop_thread.joinable()) g_loop_thread.join();

    if (g_dnssd) {
        dnssd_unregister_raop(g_dnssd);
        dnssd_unregister_airplay(g_dnssd);
        dnssd_destroy(g_dnssd);
        g_dnssd = nullptr;
    }
    if (g_raop) {
        raop_destroy(g_raop);
        g_raop = nullptr;
    }

    audio_renderer_stop();
    audio_renderer_destroy();
    video_renderer_stop();
    video_renderer_destroy();
    g_audio_active = false;

    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &kDefaultOutputAddr,
                                      default_output_changed_cb, nullptr);

    if (g_logger) {
        logger_destroy(g_logger);
        g_logger = nullptr;
    }
    g_open_connections = 0;
    g_clock_offset = 0;
    emit(AP_EV_STOPPED);
}

extern "C" void airplay_set_video_view(void *view) {
    g_video_view = view;
    video_renderer_set_window_handle((uintptr_t) view);
}

/* App-side gain multiplier (0 .. 3), applied on top of the client volume. */
extern "C" void airplay_set_volume(double gain) {
    if (gain < 0.0) gain = 0.0;
    if (gain > 3.0) gain = 3.0;
    g_user_gain = gain;
    apply_volume();
}

/* ------------------------------------------------------------- NSView */

extern "C" void *airplay_create_video_view(void) {
    __block NSView *view = nil;
    void (^make)(void) = ^{
        view = [[NSView alloc] initWithFrame:NSZeroRect];
        view.wantsLayer = YES;
        view.layer.backgroundColor = NSColor.blackColor.CGColor;
    };
    if ([NSThread isMainThread])
        make();
    else
        dispatch_sync(dispatch_get_main_queue(), make);
    return (void *) CFBridgingRetain(view);
}

extern "C" void airplay_release_video_view(void *ptr) {
    if (!ptr) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *view = (NSView *) CFBridgingRelease(ptr);
        [view removeFromSuperview];
        /* ARC releases view at end of scope */
    });
}
