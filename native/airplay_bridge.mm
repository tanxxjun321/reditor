/*
 * airplay_bridge.mm — AirPlay receiver bridge for REditor.
 *
 * Wraps the UxPlay core (native/uxplay/lib, GPLv3/LGPL-2.1+) and its
 * GStreamer renderers (native/uxplay/renderers, GPLv3) behind a small C API.
 * Wiring below is a reduced version of uxplay.cpp: mirroring (H.264) +
 * AAC/ALAC audio only, no HLS, no cover-art rendering.
 *
 * Rendering: the video pipeline is fully GPU zero-copy (h264parse ! vtdec !
 * glcolorconvert ! glimagesink) — VideoToolbox decodes into GL textures and
 * glimagesink renders them; no CPU conversion. The renderer's GstVideoOverlay
 * sync handler embeds the sink into the NSView supplied through
 * airplay_set_video_view(). Audio plays via osxaudiosink.
 */

#import <Cocoa/Cocoa.h>
#include <CoreAudio/CoreAudio.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
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
static NSView            *g_cover_view = nil;     /* black cover over the sink */
static std::atomic<bool>  g_video_frames_seen{false};
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

/* Decoder: hardware (VideoToolbox "vtdec"). vtdec cannot absorb a mid-stream
 * resolution change (iPhone rotation delivers a new SPS in-band -> heap
 * corruption / green frames), so resolution changes are handled by rebuilding
 * the whole pipeline: cb_video_set_codec_and_size detects the new size,
 * cb_video_process buffers packets (starting at the SPS/PPS+IDR packet that
 * always follows), and the GLib loop thread rebuilds and then flushes the
 * buffer into the fresh pipeline. The decode chain stays unbroken from the
 * IDR on, so no green/garbled frames can appear; frames that are late for
 * display after the rebuild are dropped cleanly by the sink's QoS. */

/* video packets buffered while the pipeline is rebuilt (rotation) */
struct PendingPacket {
    std::vector<unsigned char> data;
    int      nal_count = 0;
    uint64_t pts       = 0;    /* already mapped to local time */
};
static std::mutex           g_video_mtx;          /* guards the four below   */
static std::vector<PendingPacket> g_pending_video;
static bool                 g_have_geom = false;
static video_geometry_t     g_last_geom = {};
static std::atomic<bool>    g_video_rebuilding{false};
static std::atomic<bool>    g_rebuild_scheduled{false};
static std::atomic<bool>    g_reset_clock_on_rebuild{false};
static int                  g_late_streak = 0;   /* raop thread only */

static void start_video_renderer() {
    videoflip_t flips[2] = { NONE, NONE };
    /* mask the sink with a black cover until the first decoded frame arrives:
     * a freshly created osxvideosink can otherwise flash an uninitialized
     * (green) frame at stream start and at every rebuild (rotation) */
    g_video_frames_seen = false;
    if (g_cover_view) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_cover_view.hidden = NO;
        });
    }
    /* REDITOR_SINK overrides the sink for A/B diagnosis:
     * glimagesink (default, zero-copy GL), caopengllayersink (GL RGBA),
     * osxvideosink (CPU path), fakesink (no rendering, isolates decode) */
    const char *sink = getenv("REDITOR_SINK");
    if (!sink || !*sink) sink = "glimagesink";
    const bool cpu_sink = !strcmp(sink, "osxvideosink");
    /* qos=false + max-lateness=-1: never drop a frame for being late and
     * never ask the decoder to drop either. Sender-side latency (which can
     * reach hundreds of ms at high resolutions) is handled by re-baselining
     * the clock offset in cb_video_process instead; dropping P-frames only
     * ever corrupts the reference chain and collapses the frame rate. */
    video_renderer_init(g_logger, g_server_name.c_str(), flips,
                        "h264parse", /* rtp_pipeline */ "",
                        /* decoder */ "vtdec",
                        /* converter */ cpu_sink ? "videoconvert" : "glcolorconvert",
                        sink, /* sink options */ " qos=false max-lateness=-1",
                        /* fullscreen */ false, g_video_sync,
                        /* h265 */ false, /* coverart */ false,
                        /* playbin_version */ 3, /* uri */ nullptr);
    if (g_video_view)
        video_renderer_set_window_handle((uintptr_t) g_video_view);
    video_renderer_start();
}

/* Push the packets buffered during a rebuild into the fresh pipeline.
 * Must run after the new pipeline is PLAYING. */
static void flush_pending_video() {
    for (;;) {
        std::vector<PendingPacket> pending;
        {
            std::lock_guard<std::mutex> lk(g_video_mtx);
            if (g_pending_video.empty()) {
                /* nothing more will be buffered once the flag is down;
                 * clear it under the lock so cb_video_process cannot race
                 * a final packet into the buffer behind our back */
                g_video_rebuilding.store(false);
                return;
            }
            pending.swap(g_pending_video);
        }
        /* replay without timestamps: the frames predate the new pipeline's
         * base time; the sink presents them immediately (fast catch-up, no
         * gap in the decode chain) and live frames keep perfect A/V sync */
        for (auto &p : pending) {
            int len = (int) p.data.size();
            int nal = p.nal_count;
            uint64_t pts = p.pts;
            video_renderer_render_buffer_replay(p.data.data(), &len, &nal, &pts);
        }
        char msg[64];
        snprintf(msg, sizeof(msg), "rebuilt video pipeline, replayed %zu buffered packets",
                 pending.size());
        emit(AP_EV_LOG, msg);
    }
}

/* Stop, destroy and recreate the mirror pipeline, then re-select the codec
 * with the most recent geometry. Must run on the GLib loop thread. */
static void rebuild_video_pipeline() {
    video_renderer_stop();
    video_renderer_destroy();
    start_video_renderer();
    video_geometry_t geom;
    bool have_geom;
    {
        std::lock_guard<std::mutex> lk(g_video_mtx);
        geom = g_last_geom;
        have_geom = g_have_geom;
    }
    if (have_geom)
        video_renderer_choose_codec_and_size(false, /* h265 */ false, &geom);
}

/* Runs on the GLib loop thread: rebuild the mirror pipeline after a reset. */
static gboolean rebuild_video_cb(gpointer) {
    g_rebuild_scheduled = false;
    if (!g_running) {
        g_video_rebuilding = false;
        return G_SOURCE_REMOVE;
    }
    if (g_video_watch) { g_source_remove(g_video_watch); g_video_watch = 0; }
    rebuild_video_pipeline();
    if (g_reset_clock_on_rebuild.exchange(false)) {
        g_clock_offset = 0;
        std::lock_guard<std::mutex> lk(g_video_mtx);
        g_pending_video.clear();   /* buffered pts belong to the old clock */
    }
    if (g_loop)
        g_video_watch = video_renderer_listen(g_loop, 0);
    flush_pending_video();         /* also clears g_video_rebuilding */
    return G_SOURCE_REMOVE;
}

static void request_video_rebuild(bool reset_clock) {
    if (reset_clock) g_reset_clock_on_rebuild = true;
    bool expected = false;
    if (!g_rebuild_scheduled.compare_exchange_strong(expected, true))
        return;                                  /* one already queued */
    if (g_loop) {
        g_idle_add(rebuild_video_cb, nullptr);
    } else {
        g_rebuild_scheduled = false;
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
    request_video_rebuild(true);
}

static void cb_video_reset(void *cls, reset_type_t type) {
    (void) cls;
    switch (type) {
    case RESET_TYPE_NOHOLD:
    case RESET_TYPE_RTP_SHUTDOWN:
        request_video_rebuild(true);
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
    {
        std::lock_guard<std::mutex> lk(g_video_mtx);
        if (g_have_geom && (geom.width != g_last_geom.width ||
                            geom.height != g_last_geom.height)) {
            /* resolution change (rotation): buffer the incoming packets and
             * rebuild the pipeline around the new size instead of letting the
             * decoder see a mid-stream SPS change. The next data packet
             * carries the new SPS/PPS + IDR, so the new pipeline starts on a
             * clean keyframe. */
            g_last_geom = geom;
            g_video_rebuilding = true;
            char msg[96];
            snprintf(msg, sizeof(msg), "video size changed to %dx%d, rebuilding pipeline",
                     (int) width, (int) height);
            emit(AP_EV_LOG, msg);
            request_video_rebuild(false);   /* keep the session clock offset */
            return 0;
        }
        bool already = g_have_geom;
        g_last_geom = geom;
        g_have_geom = true;
        if (already)
            return 0;                       /* same size again (resume etc.) */
    }
    return video_renderer_choose_codec_and_size(false, codec == VIDEO_CODEC_H265, &geom);
}

static void cb_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    (void) cls; (void) ntp;
    if (!g_running) return;
    uint64_t local = data->ntp_time_local ? data->ntp_time_local : get_local_time();
    if (!map_pts(&data->ntp_time_remote, local)) return;
    /* The clock offset is calibrated to the NTP-synced sender clock, so a
     * frame's PTS tracks its CAPTURE time. ntp_time_local is the NTP-converted
     * capture time too (not arrival time), so lateness must be measured against
     * the actual wall clock. When the sender can't sustain the advertised load
     * (e.g. multi-MP landscape at 60fps), its encoder/network backlog grows
     * and every frame starts arriving late (observed: ~330ms). The sink then
     * treats frames as outdated; detect sustained lateness and re-baseline the
     * offset so the presentation deadline tracks the actual transit delay. */
    {
        int64_t late_ns = (int64_t) get_local_time() - (int64_t) data->ntp_time_remote;
        if (late_ns > 250 * 1000000LL) {
            if (++g_late_streak >= 30) {   /* ~1s of persistently late frames */
                g_clock_offset += (uint64_t) late_ns;
                data->ntp_time_remote += (uint64_t) late_ns;
                g_late_streak = 0;
                char msg[96];
                snprintf(msg, sizeof(msg),
                         "video stream persistently %.0f ms late; re-baselining clock offset",
                         (double) late_ns / 1e6);
                emit(AP_EV_LOG, msg);
            }
        } else {
            g_late_streak = 0;
        }
    }
    {
        std::lock_guard<std::mutex> lk(g_video_mtx);
        if (g_video_rebuilding.load()) {
            /* pipeline is being rebuilt for a new resolution: buffer instead
             * of feeding new-size data into the old decoder */
            if (g_pending_video.size() < 1024) {
                PendingPacket p;
                p.data.assign(data->data, data->data + data->data_len);
                p.nal_count = data->nal_count;
                p.pts = data->ntp_time_remote;
                g_pending_video.push_back(std::move(p));
            }
            return;
        }
    }
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

/* first buffer reached the sink after a pipeline (re)start: uncover video */
static void on_first_video_frame(void *ctx) {
    (void) ctx;
    g_video_frames_seen = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_cover_view.hidden = YES;
    });
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
            rebuild_video_pipeline();
            g_clock_offset = 0;
        }
    }
}

} /* extern "C" */

/* ----------------------------------------------------------- public API */

/*
 * Advertise a SQUARE canvas capped at 2560px per edge, plus 60 fps.
 *
 * The client picks the largest stream that fits the advertised canvas while
 * keeping its own aspect ratio, and happily scales beyond its panel's native
 * resolution to fill a bigger one (observed: a 2556x1179 iPhone landscape
 * screen became a 3024x1398 stream on a 3024-wide display — 40% pure
 * upscaled pixels, wasted encoder throughput and bandwidth, and the sender
 * fell behind by ~330ms). A square canvas sized to the iPhone panel's long
 * edge (2556; Pro Max 2796) makes BOTH orientations stream at native
 * resolution: nothing upscaled (no waste), nothing downscaled (full detail).
 * Rendering adapts to the actual stream size either way.
 */
#define AP_MAX_ADVERTISED_DIM 2560

static void advertise_display(raop_t *raop) {
    NSScreen *screen = nil;
    if (g_video_view) {
        NSView *view = (NSView *) g_video_view;
        screen = view.window.screen;
    }
    if (!screen) screen = [NSScreen mainScreen];

    int edge = AP_MAX_ADVERTISED_DIM;
    if (screen) {
        CGFloat scale = screen.backingScaleFactor;
        NSSize pts = screen.frame.size;
        int longest = (int) lround(MAX(pts.width, pts.height) * scale);
        if (longest < edge) edge = longest;
    }
    raop_set_plist(raop, "width", edge);
    raop_set_plist(raop, "height", edge);
    raop_set_plist(raop, "maxFPS", 60);
    raop_set_plist(raop, "refreshRate", 60);
    char msg[96];
    snprintf(msg, sizeof(msg), "advertising display %dx%d @60fps", edge, edge);
    emit(AP_EV_LOG, msg);
}


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
    logger_set_level(g_logger, LOGGER_DEBUG);   /* REditor: verbose while diagnosing */
    logger_set_callback(g_logger, bridge_log_callback, nullptr);

    audio_renderer_init(g_logger, "osxaudiosink", &g_audio_sync, &g_video_sync, "");
    video_renderer_set_caps_callback(on_video_caps, nullptr);
    video_renderer_set_first_frame_callback(on_first_video_frame, nullptr);
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

    advertise_display(g_raop);

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
    g_video_rebuilding = false;
    g_rebuild_scheduled = false;
    g_reset_clock_on_rebuild = false;
    g_video_frames_seen = false;
    {
        std::lock_guard<std::mutex> lk(g_video_mtx);
        g_pending_video.clear();
        g_have_geom = false;
    }
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

/*
 * Video host view that ignores all mouse input: hitTest: returns nil so
 * every event falls through to Avalonia's view underneath. Required for
 * the overlay UI (auto-hiding toolbar, double-click fullscreen) to work
 * over the video area. The sink renders into this view's layer, which is
 * unaffected by hit-testing.
 */
@interface APPassthroughVideoView : NSView
@end
@implementation APPassthroughVideoView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

extern "C" void *airplay_create_video_view(void) {
    __block NSView *view = nil;
    void (^make)(void) = ^{
        view = [[APPassthroughVideoView alloc] initWithFrame:NSZeroRect];
        view.wantsLayer = YES;
        view.layer.backgroundColor = NSColor.blackColor.CGColor;
        /* black cover above the sink's GL layer (zPosition wins over sublayer
         * add-order); shown while a pipeline (re)starts so the sink's initial
         * uninitialized frame is never visible, hidden on the first real
         * frame. Lives inside the passthrough view, so it cannot block mouse
         * input. Starts visible: the idle view is black anyway. */
        NSView *cover = [[NSView alloc] initWithFrame:view.bounds];
        cover.wantsLayer = YES;
        cover.layer.backgroundColor = NSColor.blackColor.CGColor;
        cover.layer.zPosition = 1000;
        cover.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        cover.hidden = g_video_frames_seen;
        [view addSubview:cover];
        g_cover_view = cover;   /* retained by the superview */
    };
    if ([NSThread isMainThread])
        make();
    else
        dispatch_sync(dispatch_get_main_queue(), make);
    return (void *) CFBridgingRetain(view);
}

extern "C" void airplay_release_video_view(void *ptr) {
    if (!ptr) return;
    g_cover_view = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *view = (NSView *) CFBridgingRelease(ptr);
        [view removeFromSuperview];
        /* ARC releases view at end of scope */
    });
}

extern "C" void airplay_hide_cursor_until_move(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSCursor setHiddenUntilMouseMoves:YES];
    });
}
