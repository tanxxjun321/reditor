/* au_output.h — 最小 AUHAL 音频输出,替代 GStreamer osxaudiosink */
#ifndef AU_OUTPUT_H
#define AU_OUTPUT_H

#ifdef __cplusplus
extern "C" {
#endif

int  au_output_init(void);   /* 创建并初始化 AUHAL(幂等);0 = 成功 */
int  au_output_start(void);  /* 开始播放(幂等);0 = 成功 */
void au_output_stop(void);   /* 停止并清空缓冲 */
/* 清空环形缓冲(不停止 AU)。用于流出现断档(丢包跳洞/流重启)后丢弃陈旧
 * 音频:否则事故冲入的积压会让输出残留 ~0.5s 的固定滞后,迟迟无法恢复 */
void au_output_reset(void);
void au_output_destroy(void);
/* 写入 44100Hz 立体声 interleaved float32;生产者任意线程(GStreamer 流线程) */
void au_output_write(const float *interleaved, int frames);

#ifdef __cplusplus
}
#endif
#endif
