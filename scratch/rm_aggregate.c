// rm_aggregate.c — 删除病态的多输出设备(聚合设备)
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

int main(void) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    int count = (int)(sz / sizeof(AudioObjectID));
    AudioObjectID *devs = malloc(sz);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, devs);
    int killed = 0;
    for (int i = 0; i < count; i++) {
        AudioObjectPropertyAddress ta = { kAudioObjectPropertyClass,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioClassID cls = 0; UInt32 cs = sizeof(cls);
        AudioObjectGetPropertyData(devs[i], &ta, 0, NULL, &cs, &cls);
        if (cls != kAudioAggregateDeviceClassID &&
            cls != kAudioEndPointDeviceClassID) continue;
        /* 是聚合设备:打印名称并销毁 */
        CFStringRef name = NULL; UInt32 ns = sizeof(name);
        AudioObjectPropertyAddress na = { kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectGetPropertyData(devs[i], &na, 0, NULL, &ns, &name);
        char cname[256] = {0};
        if (name) { CFStringGetCString(name, cname, sizeof(cname), kCFStringEncodingUTF8); CFRelease(name); }
        printf("aggregate device id=%u name=\"%s\" — destroying\n", devs[i], cname);
        OSStatus s = AudioHardwareDestroyAggregateDevice(devs[i]);
        printf("  destroy result: %d %s\n", (int) s, s == noErr ? "OK" : "FAILED");
        if (s == noErr) killed++;
    }
    if (!killed) printf("no aggregate device found\n");
    free(devs);
    return 0;
}
