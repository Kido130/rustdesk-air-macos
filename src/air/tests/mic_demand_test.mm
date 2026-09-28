// Standalone CoreAudio demand test. The child opens BlackHole input but never
// renders, stores, or transmits samples.
#include "../mic_demand.mm"
#include <AudioUnit/AudioUnit.h>
#include <spawn.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
extern char **environ;

static OSStatus discard_input(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                              UInt32, UInt32, AudioBufferList *) { return noErr; }

static int fixture() {
    AudioObjectID blackhole = kAudioObjectUnknown;
    if (!blackhole_device(blackhole)) return 10;
    AudioComponentDescription description{};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    if (!component) return 11;
    AudioUnit unit = nullptr;
    if (AudioComponentInstanceNew(component, &unit)) return 12;
    UInt32 enabled = 1, disabled = 0;
    AURenderCallbackStruct callback{discard_input, nullptr};
    const bool ready =
        !AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                              1, &enabled, sizeof(enabled))
        && !AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                 0, &disabled, sizeof(disabled))
        && !AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &blackhole, sizeof(blackhole))
        && !AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global, 0, &callback, sizeof(callback))
        && !AudioUnitInitialize(unit) && !AudioOutputUnitStart(unit);
    if (!ready) { AudioComponentInstanceDispose(unit); return 13; }
    puts("READY"); fflush(stdout);
    for (;;) pause();
}

static bool wait_for(int expected, std::chrono::milliseconds limit) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    do {
        const int observed = air_mic_demand();
        if (observed == expected) return true;
        if (observed < 0) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
}

static bool process_reads_blackhole(pid_t wanted) {
    AudioObjectID blackhole = kAudioObjectUnknown;
    std::vector<AudioObjectID> processes;
    if (!blackhole_device(blackhole) || !object_list(kAudioObjectSystemObject,
            address(kAudioHardwarePropertyProcessObjectList), processes)) return false;
    for (const auto process : processes) {
        UInt32 pid = 0, running = 0;
        if (!scalar(process, kAudioProcessPropertyPID, pid) || pid != static_cast<UInt32>(wanted)
            || !scalar(process, kAudioProcessPropertyIsRunningInput, running) || !running) continue;
        std::vector<AudioObjectID> inputs;
        if (!object_list(process, address(kAudioProcessPropertyDevices,
                                 kAudioObjectPropertyScopeInput), inputs)) return false;
        for (const auto input : inputs) if (input == blackhole) return true;
    }
    return false;
}

int main(int argc, char **argv) {
    if (argc > 1 && !std::strcmp(argv[1], "--fixture")) return fixture();
    const int baseline = air_mic_demand();
    if (baseline < 0) {
        fprintf(stderr, "BlackHole demand unavailable\n");
        return 1;
    }
    if (baseline != 0) {
        fprintf(stderr, "BlackHole baseline demand=%d (preexisting reader)\n", baseline);
        AudioObjectID blackhole = kAudioObjectUnknown;
        std::vector<AudioObjectID> processes;
        if (blackhole_device(blackhole) && object_list(kAudioObjectSystemObject,
                address(kAudioHardwarePropertyProcessObjectList), processes)) {
            for (const auto process : processes) {
                UInt32 pid = 0, running = 0;
                if (!scalar(process, kAudioProcessPropertyPID, pid)
                    || !scalar(process, kAudioProcessPropertyIsRunningInput, running)
                    || !running) continue;
                std::vector<AudioObjectID> inputs;
                if (object_list(process, address(kAudioProcessPropertyDevices,
                                 kAudioObjectPropertyScopeInput), inputs)) {
                    for (const auto input : inputs) if (input == blackhole)
                        fprintf(stderr, "BlackHole active input PID=%u\n", pid);
                }
            }
        }
    }
    int pipefd[2];
    if (pipe(pipefd)) return 2;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);
    char *child_argv[] = {argv[0], const_cast<char *>("--fixture"), nullptr};
    pid_t child = 0;
    const int spawn = posix_spawn(&child, argv[0], &actions, nullptr, child_argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);
    if (spawn) { close(pipefd[0]); return 3; }
    fd_set fds; FD_ZERO(&fds); FD_SET(pipefd[0], &fds);
    timeval timeout{5, 0};
    const int selected = select(pipefd[0] + 1, &fds, nullptr, nullptr, &timeout);
    char marker[16]{};
    const ssize_t received = selected > 0 ? read(pipefd[0], marker, sizeof(marker)) : 0;
    close(pipefd[0]);
    const bool started = received >= 5 && !std::memcmp(marker, "READY", 5);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    bool active = false;
    while (started && std::chrono::steady_clock::now() < deadline) {
        if (process_reads_blackhole(child) && air_mic_demand() == 1) { active = true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    kill(child, SIGTERM);
    int child_status = 0;
    waitpid(child, &child_status, 0);
    const bool idle = !process_reads_blackhole(child) && wait_for(baseline, std::chrono::seconds(5));
    printf("baseline=%d fixture_started=%d fixture_active=%d restored_baseline=%d\n",
           baseline, started, active, idle);
    return started && active && idle ? 0 : 4;
}
