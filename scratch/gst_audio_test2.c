// gst_audio_test2.c — 极限保真复刻 app 音频启动路径:
//   - 与 uxplay 相同的 4 条管线预创建(ELD/ALAC/AAC-LC/PCM)
//   - gst_pipeline_use_clock 强制共享 REALTIME 系统时钟
//   - 从独立 GLib 线程驱动,总线 watch 挂在该线程
//   - 启动后 apply volume(模拟 apply_volume())
// appsrc 直接喂 F32LE 44100/2(avdec_aac 的输出等价物),静音。
#include <gst/gst.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static void mark(const char *step) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/am-test/gst2_progress.log", getenv("HOME"));
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", step); fsync(fd); close(fd); }
    printf("%s\n", step);
    fflush(stdout);
}

static GstElement *pipes[4];
static GstElement *srcs[4];
static GstClock *shared_clock;
static GMainLoop *loop;

static char sink_desc[256] = "osxaudiosink sync=true";

/* 管线在 main 里按 sink_desc 拼接(支持 SINK 环境变量换 sink) */
static char descs_buf[4][512];
static const char *descs[4];

static gboolean bus_cb(GstBus *bus, GstMessage *msg, gpointer data) {
    (void) bus; (void) data;
    if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
        GError *e = NULL;
        gst_message_parse_error(msg, &e, NULL);
        char m[512];
        snprintf(m, sizeof(m), "bus error: %s", e ? e->message : "?");
        mark(m);
    }
    return G_SOURCE_CONTINUE;
}

static gsize g_bpf = 8;

static void *feed_thread(void *arg) {
    (void) arg;
    GstElement *src = srcs[0];
    const int frames = 1024;
    gsize nbytes = frames * g_bpf;
    guint64 pts = 0;
    for (int i = 0; i < 400; i++) {   /* ~9.3s */
        GstBuffer *buf = gst_buffer_new_allocate(NULL, nbytes, NULL);
        gst_buffer_memset(buf, 0, 0, nbytes);
        GST_BUFFER_PTS(buf) = pts;
        GST_BUFFER_DURATION(buf) = gst_util_uint64_scale_int(frames, GST_SECOND, 44100);
        pts += GST_BUFFER_DURATION(buf);
        GstFlowReturn fr;
        g_signal_emit_by_name(src, "push-buffer", buf, &fr);
        gst_buffer_unref(buf);
        if (fr != GST_FLOW_OK) { mark("push flow != OK"); break; }
        g_usleep(frames * 1000000 / 44100);
    }
    mark("feed done");
    return NULL;
}

int main(void) {
    const char *plug = "/Applications/AirMirror.app/Contents/Frameworks/gstreamer";
    setenv("GST_PLUGIN_PATH", plug, 1);
    char scanner[1200];
    snprintf(scanner, sizeof(scanner), "%s/gst-plugin-scanner", plug);
    setenv("GST_PLUGIN_SCANNER", scanner, 1);
    setenv("GST_REGISTRY", "/tmp/gst2_registry.bin", 1);

    /* 二分开关:NOCLOCK=1 不强制时钟;NPIPE=1 只建一条管线;S16=1 用 S16LE */
    int use_clock = !getenv("NOCLOCK");
    int npipe = getenv("NPIPE") ? atoi(getenv("NPIPE")) : 4;
    const char *fmt = getenv("S16") ? "S16LE" : "F32LE";
    g_bpf = getenv("S16") ? 4 : 8;
    { char m[128]; snprintf(m, sizeof(m), "config: clock=%d npipe=%d fmt=%s",
                            use_clock, npipe, fmt); mark(m); }

    /* SINK 环境变量覆盖 sink(如 "fakesink"、"osxaudiosink buffer-time=500000") */
    const char *sink_env = getenv("SINK");
    if (sink_env && *sink_env)
        snprintf(sink_desc, sizeof(sink_desc), "%s", sink_env);
    for (int i = 0; i < 4; i++) {
        snprintf(descs_buf[i], sizeof(descs_buf[i]),
                 "appsrc name=asrc is-live=true format=time ! queue ! "
                 "audioconvert ! audioresample quality=10 ! volume name=volume ! "
                 "level ! %s", sink_desc);
        descs[i] = descs_buf[i];
    }
    { char m[300]; snprintf(m, sizeof(m), "sink: %s", sink_desc); mark(m); }

    mark("step1: gst_init");
    gst_init(NULL, NULL);

    mark("step2: shared REALTIME clock");
    shared_clock = gst_system_clock_obtain();
    g_object_set(shared_clock, "clock-type", GST_CLOCK_TYPE_REALTIME, NULL);

    mark("step3: create pipelines");
    GstCaps *raw = gst_caps_new_simple("audio/x-raw",
        "format", G_TYPE_STRING, fmt,
        "rate", G_TYPE_INT, 44100, "channels", G_TYPE_INT, 2,
        "layout", G_TYPE_STRING, "interleaved", NULL);
    for (int i = 0; i < npipe; i++) {
        GError *err = NULL;
        pipes[i] = gst_parse_launch(descs[i], &err);
        if (!pipes[i]) { mark("FAIL parse"); return 1; }
        if (use_clock)
            gst_pipeline_use_clock(GST_PIPELINE(pipes[i]), shared_clock);
        srcs[i] = gst_bin_get_by_name(GST_BIN(pipes[i]), "asrc");
        g_object_set(srcs[i], "caps", raw, NULL);
        GstBus *bus = gst_element_get_bus(pipes[i]);
        gst_bus_add_watch(bus, bus_cb, NULL);
        gst_object_unref(bus);
    }
    gst_caps_unref(raw);

    mark("step4: start GLib loop on its own thread");
    loop = g_main_loop_new(NULL, FALSE);
    GThread *lt = g_thread_new("loop", (GThreadFunc) g_main_loop_run, loop);
    (void) lt;

    mark("step5: pipeline[0] PLAYING (osxaudiosink 开 CoreAudio)");
    gst_element_set_state(pipes[0], GST_STATE_PLAYING);

    mark("step6: apply volume (模拟 apply_volume)");
    GstElement *vol = gst_bin_get_by_name(GST_BIN(pipes[0]), "volume");
    if (vol) { g_object_set(vol, "volume", 0.8, NULL); gst_object_unref(vol); }

    mark("step7: feed audio 9s");
    g_thread_new("feed", feed_thread, NULL);
    g_usleep(10 * 1000000);

    mark("step8: stop all");
    for (int i = 0; i < npipe; i++) gst_element_set_state(pipes[i], GST_STATE_NULL);
    mark("step9: done OK");
    return 0;
}
