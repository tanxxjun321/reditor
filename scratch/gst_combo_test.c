// gst_combo_test.c — 视频(glimagesink) + 音频(avdec_aac + osxaudiosink)并发复现
// 视频: appsrc(NV12 720p60 彩条) ! videoconvert ! glimagesink sync=true
// 音频: appsrc(ADTS AAC 循环) ! avdec_aac ! audioconvert ! audioresample
//       quality=10 ! volume ! level ! osxaudiosink sync=true
// 进度写 ~/am-test/combo_progress.log 并 fsync。
#include <gst/gst.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static void mark(const char *step) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/am-test/combo_progress.log", getenv("HOME"));
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", step); fsync(fd); close(fd); }
    printf("%s\n", step);
    fflush(stdout);
}

static char *g_aac = NULL;
static gsize g_aac_len = 0;

static void load_aac(void) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/am-test/am_test.aac", getenv("HOME"));
    FILE *f = fopen(path, "rb");
    if (!f) { mark("WARN: no aac file, audio will be silent PCM fallback"); return; }
    fseek(f, 0, SEEK_END);
    g_aac_len = (gsize) ftell(f);
    fseek(f, 0, SEEK_SET);
    g_aac = malloc(g_aac_len);
    if (fread(g_aac, 1, g_aac_len, f) != g_aac_len) { /* best effort */ }
    fclose(f);
}

static void push_audio_loop(GstElement *src) {
    /* 每次推整个文件(ADTS 帧序列),循环 */
    if (!g_aac) return;
    GstBuffer *buf = gst_buffer_new_allocate(NULL, g_aac_len, NULL);
    gst_buffer_fill(buf, 0, g_aac, g_aac_len);
    GstFlowReturn fr;
    g_signal_emit_by_name(src, "push-buffer", buf, &fr);
    gst_buffer_unref(buf);
    if (fr != GST_FLOW_OK) mark("audio push flow != OK");
}

int main(void) {
    const char *plug = "/Applications/AirMirror.app/Contents/Frameworks/gstreamer";
    setenv("GST_PLUGIN_PATH", plug, 1);
    char scanner[1200];
    snprintf(scanner, sizeof(scanner), "%s/gst-plugin-scanner", plug);
    setenv("GST_PLUGIN_SCANNER", scanner, 1);
    setenv("GST_REGISTRY", "/tmp/gst_combo_registry.bin", 1);

    mark("step1: gst_init");
    gst_init(NULL, NULL);
    load_aac();

    GError *err = NULL;
    mark("step2: build video pipeline");
    GstElement *vpipe = gst_parse_launch(
        "appsrc name=vsrc is-live=true format=time ! "
        "video/x-raw,format=NV12,width=1280,height=720,framerate=60/1 ! "
        "videoconvert ! glimagesink sync=true", &err);
    if (!vpipe) { mark("FAIL video parse"); return 1; }

    mark("step3: build audio pipeline (avdec_aac)");
    GstElement *apipe = gst_parse_launch(
        "appsrc name=asrc is-live=true format=time ! "
        "audio/mpeg,mpegversion=4,stream-format=adts,rate=22050,channels=1 ! "
        "avdec_aac ! audioconvert ! audioresample quality=10 ! "
        "volume ! level ! osxaudiosink sync=true", &err);
    if (!apipe) {
        char m[512]; snprintf(m, sizeof(m), "FAIL audio parse: %s",
                              err ? err->message : "?");
        mark(m);
        return 1;
    }
    GstElement *vsrc = gst_bin_get_by_name(GST_BIN(vpipe), "vsrc");
    GstElement *asrc = gst_bin_get_by_name(GST_BIN(apipe), "asrc");

    mark("step4: video PLAYING (glimagesink 开窗)");
    gst_element_set_state(vpipe, GST_STATE_PLAYING);
    sleep(1);
    mark("step5: audio PLAYING (osxaudiosink 开 CoreAudio)");
    gst_element_set_state(apipe, GST_STATE_PLAYING);

    mark("step6: dual-stream 10s");
    guint64 vpts = 0;
    const int w = 1280, h = 720;
    gsize vbytes = (gsize) w * h * 3 / 2;
    guint8 *frame = malloc(vbytes);
    for (int i = 0; i < 600; i++) {  /* 10s @60fps */
        /* 移动的彩条,让编码侧始终有内容 */
        memset(frame, (i * 3) & 0xff, (gsize) w * h);
        memset(frame + (gsize) w * h, 128, (gsize) w * h / 2);
        GstBuffer *buf = gst_buffer_new_allocate(NULL, vbytes, NULL);
        gst_buffer_fill(buf, 0, frame, vbytes);
        GST_BUFFER_PTS(buf) = vpts;
        GST_BUFFER_DURATION(buf) = GST_SECOND / 60;
        vpts += GST_SECOND / 60;
        GstFlowReturn fr;
        g_signal_emit_by_name(vsrc, "push-buffer", buf, &fr);
        gst_buffer_unref(buf);
        if (fr != GST_FLOW_OK) { mark("video push flow != OK"); break; }
        if (i % 60 == 0) {
            push_audio_loop(asrc);   /* 每秒推一轮 AAC */
            char m[64]; snprintf(m, sizeof(m), "  t=%ds", i / 60);
            mark(m);
        }
        g_usleep(16600);
    }

    mark("step7: stop both");
    gst_element_set_state(vpipe, GST_STATE_NULL);
    gst_element_set_state(apipe, GST_STATE_NULL);
    gst_object_unref(vpipe);
    gst_object_unref(apipe);
    mark("step8: done OK");
    gst_deinit();
    free(frame);
    free(g_aac);
    return 0;
}
