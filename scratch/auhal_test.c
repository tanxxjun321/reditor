// auhal_test.c — 复刻 osxaudiosink 的设备打开路径
// 用法:
//   ./auhal_test enum          只枚举设备(安全,只读)
//   ./auhal_test play [devid]  AUHAL 打开默认/指定输出设备,播 3 秒正弦波
// 每个关键步骤写进度到 ~/am-test/auhal_progress.log 并 fsync,
// 机器若重启,重启后可读回最后停在哪一步。
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>

static void mark(const char *step) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/am-test/auhal_progress.log", getenv("HOME"));
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "%s\n", step);
        fsync(fd);
        close(fd);
    }
    printf("%s\n", step);
    fflush(stdout);
}

static void get_name(AudioObjectID dev, char *buf, size_t n) {
    CFStringRef name = NULL;
    UInt32 sz = sizeof(name);
    AudioObjectPropertyAddress a = { kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    buf[0] = 0;
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &name) == noErr && name) {
        CFStringGetCString(name, buf, (CFIndex)n, kCFStringEncodingUTF8);
        CFRelease(name);
    }
}

static void enum_devices(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    int count = (int)(sz / sizeof(AudioObjectID));
    AudioObjectID *devs = malloc(sz);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, devs);
    for (int i = 0; i < count; i++) {
        char name[256];
        get_name(devs[i], name, sizeof(name));
        UInt32 ss = 0;
        AudioObjectPropertyAddress sa = { kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        AudioObjectGetPropertyDataSize(devs[i], &sa, 0, NULL, &ss);
        printf("device id=%u  name=\"%s\"  output_streams=%u\n",
               devs[i], name, ss / (UInt32)sizeof(AudioStreamID));
    }
    AudioObjectID def = 0;
    UInt32 ds = sizeof(def);
    AudioObjectPropertyAddress da = { kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &da, 0, NULL, &ds, &def);
    char dn[256]; get_name(def, dn, sizeof(dn));
    printf("default output device: id=%u name=\"%s\"\n", def, dn);
    free(devs);
}

static double g_phase = 0;
static int g_set_bufsize = 0;

static OSStatus renderProc(void *inRefCon, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void) inRefCon; (void) flags; (void) ts; (void) bus;
    for (UInt32 i = 0; i < frames; i++) {
        float v = (float)(0.1 * sin(g_phase));
        g_phase += 2.0 * M_PI * 440.0 / 44100.0;
        for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
            float *out = (float *) data->mBuffers[b].mData;
            for (UInt32 c = 0; c < data->mBuffers[b].mNumberChannels; c++)
                out[i * data->mBuffers[b].mNumberChannels + c] = v;
        }
    }
    return noErr;
}

static void play(AudioObjectID devid) {
    AudioUnit au = NULL;
    AudioComponentDescription desc = { kAudioUnitType_Output,
        kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0 };
    mark("step1: find component");
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    mark("step2: instance new");
    if (AudioComponentInstanceNew(comp, &au) != noErr) { mark("FAIL: instance"); return; }
    if (devid) {
        char m[128]; snprintf(m, sizeof(m), "step3: bind device %u", devid);
        mark(m);
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &devid, sizeof(devid));
    }
    mark("step4: set stream format 44100/2ch/float32");
    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = 44100; fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mFramesPerPacket = 1; fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 32; fmt.mBytesPerFrame = 8; fmt.mBytesPerPacket = 8;
    AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (g_set_bufsize) {
        /* 复刻 osxaudiosink 的行为:按 latency-time 改设备的硬件缓冲帧数。
         * 这是对"设备"的改动(影响全局),与病态聚合设备同栈时
         * 疑似会卡死 CoreAudio HAL。 */
        UInt32 cur = 0, sz = sizeof(cur);
        AudioUnitGetProperty(au, kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global, 0, &cur, &sz);
        char m[128];
        snprintf(m, sizeof(m), "step4b: device buffer frame size currently %u, set 441", cur);
        mark(m);
        UInt32 frames = 441;
        OSStatus s = AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global, 0, &frames, sizeof(frames));
        snprintf(m, sizeof(m), "step4c: set result %d", (int) s);
        mark(m);
    }
    mark("step5: set render callback");
    AURenderCallbackStruct cb = { renderProc, NULL };
    AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    mark("step6: AudioUnitInitialize");
    if (AudioUnitInitialize(au) != noErr) { mark("FAIL: init"); return; }
    mark("step7: AudioOutputUnitStart (此处为危险点)");
    if (AudioOutputUnitStart(au) != noErr) { mark("FAIL: start"); return; }
    mark("step8: playing 3s...");
    sleep(3);
    mark("step9: stop");
    AudioOutputUnitStop(au);
    mark("step10: uninitialize");
    AudioUnitUninitialize(au);
    mark("step11: done OK");
}

static OSStatus dev_changed_cb(AudioObjectID id, UInt32 naddr,
                               const AudioObjectPropertyAddress *addrs, void *ctx) {
    (void) id; (void) ctx;
    for (UInt32 i = 0; i < naddr; i++) {
        char m[128];
        snprintf(m, sizeof(m), "NOTIFY: selector=%c%c%c%c scope=%c%c%c%c",
                 (char)(addrs[i].mSelector >> 24), (char)(addrs[i].mSelector >> 16),
                 (char)(addrs[i].mSelector >> 8), (char)(addrs[i].mSelector),
                 (char)(addrs[i].mScope >> 24), (char)(addrs[i].mScope >> 16),
                 (char)(addrs[i].mScope >> 8), (char)(addrs[i].mScope));
        mark(m);
    }
    return noErr;
}

/* 模拟 app 的行为:监听默认输出变化 + 播 5 秒,记录期间收到的所有通知 */
static void listen_and_play(void) {
    static const AudioObjectPropertyAddress addrs[] = {
        { kAudioHardwarePropertyDefaultOutputDevice,
          kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioHardwarePropertyDevices,
          kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    mark("listen: install listeners (default-output + device-list)");
    for (int i = 0; i < 2; i++)
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &addrs[i],
                                       dev_changed_cb, NULL);
    play(0);   /* 内部会写 step 日志;通知穿插其中即说明有 spurious 事件 */
    mark("listen: remove listeners");
    for (int i = 0; i < 2; i++)
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &addrs[i],
                                          dev_changed_cb, NULL);
    mark("listen: done");
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "enum") == 0) { enum_devices(); return 0; }
    if (argc >= 2 && strcmp(argv[1], "listen") == 0) { listen_and_play(); return 0; }
    if (argc >= 2 && strcmp(argv[1], "gstplay") == 0) {
        /* 复刻 GStreamer gstcoreaudio 的完整打开序列:
         * 1) kAudioHardwarePropertyRunLoop = NULL(系统级!HAL 另起通知线程)
         * 2) HALOutput unit + 显式绑定设备
         * 3) Global scope 的 SetRenderCallback(非 Input scope)
         * 4) 44100 float 格式 + start */
        mark("g1: set kAudioHardwarePropertyRunLoop = NULL (系统级)");
        CFRunLoopRef rl = NULL;
        AudioObjectPropertyAddress rla = { kAudioHardwarePropertyRunLoop,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        OSStatus s = AudioObjectSetPropertyData(kAudioObjectSystemObject,
            &rla, 0, NULL, sizeof(rl), &rl);
        { char m[96]; snprintf(m, sizeof(m), "g1 result %d", (int) s); mark(m); }

        AudioUnit au = NULL;
        AudioComponentDescription desc = { kAudioUnitType_Output,
            kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0 };
        mark("g2: instance HALOutput");
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        AudioComponentInstanceNew(comp, &au);
        AudioObjectID def = 0; UInt32 ds = sizeof(def);
        AudioObjectPropertyAddress da = { kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &da, 0, NULL, &ds, &def);
        mark("g3: bind default device explicitly");
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &def, sizeof(def));
        mark("g4: SetRenderCallback on GLOBAL scope");
        AURenderCallbackStruct cb = { renderProc, NULL };
        AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Global, 0, &cb, sizeof(cb));
        mark("g5: stream format 44100 float (Input scope, element 0)");
        AudioStreamBasicDescription fmt = {0};
        fmt.mSampleRate = 44100; fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        fmt.mFramesPerPacket = 1; fmt.mChannelsPerFrame = 2;
        fmt.mBitsPerChannel = 32; fmt.mBytesPerFrame = 8; fmt.mBytesPerPacket = 8;
        AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
        mark("g6: Initialize");
        if (AudioUnitInitialize(au) != noErr) { mark("FAIL init"); return 1; }
        mark("g7: Start");
        if (AudioOutputUnitStart(au) != noErr) { mark("FAIL start"); return 1; }
        mark("g8: playing 4s");
        sleep(4);
        AudioOutputUnitStop(au);
        AudioUnitUninitialize(au);
        mark("g9: done OK");
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "playbuf") == 0) {
        g_set_bufsize = 1;
        play(0);
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "play") == 0) {
        AudioObjectID dev = (argc >= 3) ? (AudioObjectID) atoi(argv[2]) : 0;
        play(dev);
        return 0;
    }
    fprintf(stderr, "usage: %s enum | play [deviceID] | listen\n", argv[0]);
    return 1;
}
