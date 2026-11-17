/* au_output.h — 最小 AUHAL 音频输出,替代 GStreamer osxaudiosink */
#ifndef AU_OUTPUT_H
#define AU_OUTPUT_H

#ifdef __cplusplus
extern "C" {
#endif

int  au_output_init(void);   /* 创建并初始化 AUHAL(幂等);0 = 成功 */
int  au_output_start(void);  /* 开始播放(幂等);0 = 成功 */
void au_output_stop(void);   /* 停止并清空缓冲 */
void au_output_destroy(void);
/* 写入 44100Hz 立体声 interleaved float32;生产者任意线程(GStreamer 流线程) */
void au_output_write(const float *interleaved, int frames);

#ifdef __cplusplus
}
#endif
#endif
