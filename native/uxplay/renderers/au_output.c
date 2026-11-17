/* au_output.c — 最小 AUHAL 音频输出,替代 GStreamer osxaudiosink。
 *
 * 为什么存在:osxaudiosink 的 HAL 使用序列(系统 runloop 切换、属性监听、
 * 早期初始化、ringbuffer 回调)在部分带病 CoreAudio 栈的机器上(实测:
 * Mac mini M4 + macOS 15.7.4,曾寄生第三方虚拟声卡驱动)会触发死锁,
 * 蔓延进内核音频驱动工作队列后 SoC watchdog 整机复位(bug_type 210)。
 * 同样的机器上,裸 AUHAL 的最小调用序列(见下,与 scratch/auhal_test.c
 * 一致)被反复验证为安全。这里只用那段序列,不做任何多余动作:
 * 不改设备缓冲帧数、不设 runloop、不装属性监听、不枚举设备。
 *
 * 线程模型:SPSC 无锁环形缓冲。生产者 = appsink 回调(GStreamer 流线程),
 * 消费者 = render_cb(CoreAudio 实时线程)。写指针只有生产者动;
 * 读指针主要在消费者侧推进,生产者溢出时"丢最旧"也会推进它——
 * 竞态的最坏结果是偶发爆音,不会破坏内存安全。 */
#include "au_output.h"
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>

#define AU_RATE 44100
#define AU_CH   2
#define RING_FRAMES 44100          /* 0.5s 容量,延迟上界由丢最旧保证 */

static AudioUnit g_au = NULL;
static float g_ring[RING_FRAMES * AU_CH];
static _Atomic unsigned g_rpos = 0;
static _Atomic unsigned g_wpos = 0;

static OSStatus render_cb(void *ud, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                          AudioBufferList *data) {
    (void) ud; (void) flags; (void) ts; (void) bus;
    unsigned r = atomic_load_explicit(&g_rpos, memory_order_relaxed);
    unsigned w = atomic_load_explicit(&g_wpos, memory_order_acquire);
    unsigned avail = (w + RING_FRAMES - r) % RING_FRAMES;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        float *out = (float *) data->mBuffers[b].mData;
        for (UInt32 i = 0; i < frames; i++) {
            float l = 0.0f, rr = 0.0f;
            if (avail) {
                l  = g_ring[r * AU_CH];
                rr = g_ring[r * AU_CH + 1];
                r = (r + 1) % RING_FRAMES;
                avail--;
            }
            out[i * 2]     = l;
            out[i * 2 + 1] = rr;
        }
    }
    atomic_store_explicit(&g_rpos, r, memory_order_release);
    return noErr;
}

int au_output_init(void) {
    if (g_au) return 0;
    AudioComponentDescription desc = { kAudioUnitType_Output,
        kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) return -1;
    if (AudioComponentInstanceNew(comp, &g_au) != noErr) { g_au = NULL; return -1; }

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = AU_RATE; fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mFramesPerPacket = 1; fmt.mChannelsPerFrame = AU_CH;
    fmt.mBitsPerChannel = 32;
    fmt.mBytesPerFrame = 4 * AU_CH; fmt.mBytesPerPacket = 4 * AU_CH;
    AudioUnitSetProperty(g_au, kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    AURenderCallbackStruct cb = { render_cb, NULL };
    AudioUnitSetProperty(g_au, kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (AudioUnitInitialize(g_au) != noErr) {
        AudioComponentInstanceDispose(g_au);
        g_au = NULL;
        return -1;
    }
    return 0;
}

int au_output_start(void) {
    if (au_output_init() != 0) return -1;
    if (AudioOutputUnitStart(g_au) != noErr) return -1;
    return 0;
}

void au_output_stop(void) {
    if (g_au) AudioOutputUnitStop(g_au);
    atomic_store(&g_rpos, 0);
    atomic_store(&g_wpos, 0);
}

void au_output_destroy(void) {
    if (!g_au) return;
    AudioOutputUnitStop(g_au);
    AudioUnitUninitialize(g_au);
    AudioComponentInstanceDispose(g_au);
    g_au = NULL;
}

void au_output_write(const float *p, int frames) {
    if (frames <= 0) return;
    unsigned w = atomic_load_explicit(&g_wpos, memory_order_relaxed);
    unsigned r = atomic_load_explicit(&g_rpos, memory_order_acquire);
    unsigned used = (w + RING_FRAMES - r) % RING_FRAMES;
    /* 溢出丢最旧:直播流由发送端实时定速,积压没有意义,延迟必须有界 */
    while (used + (unsigned) frames >= RING_FRAMES) {
        r = (r + 1) % RING_FRAMES;
        used = (used + RING_FRAMES - 1) % RING_FRAMES;
    }
    atomic_store_explicit(&g_rpos, r, memory_order_release);
    for (int i = 0; i < frames; i++) {
        g_ring[w * AU_CH]     = p[i * AU_CH];
        g_ring[w * AU_CH + 1] = p[i * AU_CH + 1];
        w = (w + 1) % RING_FRAMES;
    }
    atomic_store_explicit(&g_wpos, w, memory_order_release);
}
