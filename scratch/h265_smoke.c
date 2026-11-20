/* h265_smoke.c — 不启动 GUI,直接拉起 AirPlay 接收端做 h265 支持冒烟测试。
 * 验证点:
 *   1. 视频 renderer 注册了两条管线(h264 + h265),h265parse/avdec_h265 能实例化
 *   2. Bonjour 广播的 features 第二段含 bit 42(SupportsScreenMultiCodec)
 * 用法: ./h265_smoke  (跑 8 秒后自动停止;期间可用 dns-sd 查询广播) */
#include <stdio.h>
#include <unistd.h>
#include "airplay_bridge.h"

static void cb(void *ctx, ap_event_t ev, const char *info, int w, int h) {
    (void) ctx;
    const char *names[] = {"WAITING","CONNECTED","DISCONNECTED","VIDEO_SIZE","Log","ERROR","STOPPED"};
    printf("[%s] %s %dx%d\n", names[ev], info ? info : "", w, h);
    fflush(stdout);
}

int main(void) {
    int rc = airplay_start("AirMirrorTest", cb, NULL);
    if (rc != 0) { fprintf(stderr, "airplay_start failed: %d\n", rc); return 1; }
    sleep(8);
    airplay_stop();
    return 0;
}
