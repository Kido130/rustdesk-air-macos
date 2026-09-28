#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                             AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    return {selector, scope, kAudioObjectPropertyElementMain};
}

bool object_list(AudioObjectID object, const AudioObjectPropertyAddress &property,
                 std::vector<AudioObjectID> &values) {
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(object, &property, 0, nullptr, &bytes)
        || bytes % sizeof(AudioObjectID)) return false;
    values.resize(bytes / sizeof(AudioObjectID));
    if (!bytes) return true;
    if (AudioObjectGetPropertyData(object, &property, 0, nullptr, &bytes, values.data())
        || bytes % sizeof(AudioObjectID)) return false;
    values.resize(bytes / sizeof(AudioObjectID));
    return true;
}

bool scalar(AudioObjectID object, AudioObjectPropertySelector selector, UInt32 &value) {
    UInt32 bytes = sizeof(value);
    const auto property = address(selector);
    return !AudioObjectGetPropertyData(object, &property, 0, nullptr, &bytes, &value)
        && bytes == sizeof(value);
}

bool blackhole_device(AudioObjectID &device) {
    std::vector<AudioObjectID> devices;
    if (!object_list(kAudioObjectSystemObject, address(kAudioHardwarePropertyDevices), devices))
        return false;
    for (const auto candidate : devices) {
        const auto property = address(kAudioObjectPropertyName);
        CFStringRef name = nullptr;
        UInt32 bytes = sizeof(name);
        if (AudioObjectGetPropertyData(candidate, &property, 0, nullptr, &bytes, &name)) continue;
        if (!name) continue;
        const bool match = CFStringCompare(name, CFSTR("BlackHole 2ch"), 0) == kCFCompareEqualTo;
        CFRelease(name);
        if (match) { device = candidate; return true; }
    }
    return false;
}
}

// 1: another process actively reads BlackHole; 0: no reader; -1: CoreAudio
// cannot establish the answer. This function creates no audio stream or callback.
extern "C" int air_mic_demand() {
    AudioObjectID blackhole = kAudioObjectUnknown;
    if (!blackhole_device(blackhole)) return -1;
    std::vector<AudioObjectID> processes;
    if (!object_list(kAudioObjectSystemObject,
                     address(kAudioHardwarePropertyProcessObjectList), processes)) return -1;
    bool unknown = false;
    for (const auto process : processes) {
        UInt32 pid = 0, running = 0;
        if (!scalar(process, kAudioProcessPropertyPID, pid)) { unknown = true; continue; }
        if (pid == static_cast<UInt32>(getpid())) continue;
        if (!scalar(process, kAudioProcessPropertyIsRunningInput, running)) { unknown = true; continue; }
        if (!running) continue;
        std::vector<AudioObjectID> inputs;
        if (!object_list(process, address(kAudioProcessPropertyDevices,
                                          kAudioObjectPropertyScopeInput), inputs)) { unknown = true; continue; }
        for (const auto input : inputs) if (input == blackhole) return 1;
    }
    return unknown ? -1 : 0;
}
