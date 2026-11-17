// gst_audio_test.c — 用 AirMirror.app 内置的 GStreamer 复刻音频管线
// 管线与 uxplay audio_renderer 一致(先用 PCM 静音,跳过 avdec_aac):
//   appsrc ! queue ! audioconvert ! audioresample quality=10 !
//   volume ! level ! osxaudiosink sync=true
// 进度写入 ~/am-test/gst_progress.log 并 fsync,机器重启后可读回。
#include <gst/gst.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static void mark(const char *step) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/am-test/gst_progress.log", getenv("HOME"));
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", step); fsync(fd); close(fd); }
    printf("%s\n", step);
    fflush(stdout);
}

int main(int argc, char **argv) {
    (void) argc; (void) argv;
    const char *home = getenv("HOME");
    char plug[1024], scanner[1200];
    snprintf(plug, sizeof(plug),
             "%s", "/Applications/AirMirror.app/Contents/Frameworks/gstreamer");
    snprintf(scanner, sizeof(scanner), "%s/gst-plugin-scanner", plug);
    setenv("GST_PLUGIN_PATH", plug, 1);
    setenv("GST_PLUGIN_SCANNER", scanner, 1);
    setenv("GST_REGISTRY", "/tmp/gst_audio_test_registry.bin", 1);
    (void) home;

    mark("step1: gst_init");
    gst_init(NULL, NULL);

    mark("step2: parse launch");
    GError *err = NULL;
    GstElement *pipeline = gst_parse_launch(
        "appsrc name=audio_source is-live=true format=time ! "
        "queue ! audioconvert ! audioresample quality=10 ! "
        "volume name=volume ! level ! osxaudiosink sync=true", &err);
    if (!pipeline) {
        char m[512]; snprintf(m, sizeof(m), "FAIL parse: %s", err->message);
        mark(m);
        return 1;
    }
    GstElement *src = gst_bin_get_by_name(GST_BIN(pipeline), "audio_source");
    GstCaps *caps = gst_caps_new_simple("audio/x-raw",
        "format", G_TYPE_STRING, "S16LE",
        "rate", G_TYPE_INT, 44100,
        "channels", G_TYPE_INT, 2,
        "layout", G_TYPE_STRING, "interleaved", NULL);
    g_object_set(src, "caps", caps, NULL);
    gst_caps_unref(caps);

    mark("step3: set PLAYING (osxaudiosink 在此打开 CoreAudio)");
    gst_element_set_state(pipeline, GST_STATE_PLAYING);

    mark("step4: push 5s of silence");
    /* 44100 * 2ch * 2B = 176400 B/s;每 buffer 4096 帧 */
    const int frames_per_buf = 4096;
    gsize nbytes = frames_per_buf * 4;
    for (int i = 0; i < 54; i++) {   /* ~5 秒 */
        GstBuffer *buf = gst_buffer_new_allocate(NULL, nbytes, NULL);
        gst_buffer_memset(buf, 0, 0, nbytes);
        GST_BUFFER_PTS(buf) = gst_util_uint64_scale_int(
            (guint64) i * frames_per_buf, GST_SECOND, 44100);
        GST_BUFFER_DURATION(buf) = gst_util_uint64_scale_int(
            frames_per_buf, GST_SECOND, 44100);
        GstFlowReturn fr;
        g_signal_emit_by_name(src, "push-buffer", buf, &fr);
        gst_buffer_unref(buf);
        if (fr != GST_FLOW_OK) {
            char m[128]; snprintf(m, sizeof(m), "push flow=%d", fr);
            mark(m);
            break;
        }
        g_usleep((gulong) frames_per_buf * 1000000 / 44100);
        if (i % 10 == 0) { char m[64]; snprintf(m, sizeof(m), "  pushed %d", i); mark(m); }
    }

    mark("step5: set NULL");
    gst_element_set_state(pipeline, GST_STATE_NULL);
    mark("step6: unref, done OK");
    gst_object_unref(pipeline);
    gst_deinit();
    return 0;
}
