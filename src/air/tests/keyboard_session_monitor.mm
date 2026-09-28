#import <AppKit/AppKit.h>

#include <chrono>
#include <climits>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted = 0;

static void stopMonitor(int) {
    interrupted = 1;
}

static bool parseNumber(const char *value, long *result) {
    if (!value || !*value) return false;
    errno = 0;
    char *end = nullptr;
    long parsed = strtol(value, &end, 10);
    if (errno || !end || *end || parsed <= 0) return false;
    *result = parsed;
    return true;
}

static bool writeRecord(FILE *file, NSDictionary *record) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!json) return false;
    return fwrite(json.bytes, 1, json.length, file) == json.length &&
           fputc('\n', file) != EOF && fflush(file) == 0;
}

static long long wallMilliseconds() {
    return static_cast<long long>([NSDate date].timeIntervalSince1970 * 1000.0);
}

static bool previewAlive(pid_t pid, NSString *bundle, NSDate *launchDate) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.isTerminated || ![app.bundleIdentifier isEqualToString:bundle]) return false;
    NSDate *currentLaunch = app.launchDate;
    return !launchDate || !currentLaunch || [currentLaunch isEqualToDate:launchDate];
}

struct AppTotals {
    unsigned activations = 0;
    long long foregroundMilliseconds = 0;
};

int main(int argc, const char **argv) {
    @autoreleasepool {
        long seconds = 0;
        long rawPid = 0;
        const char *output = nullptr;
        NSString *expectedBundle = nil;
        if (argc != 9) {
            fprintf(stderr, "Usage: %s --seconds 45..180 --output /absolute/path.jsonl --preview-pid PID --expected-bundle dev.rustdesk.air.Client|dev.rustdesk.air.Host\n", argv[0]);
            return 2;
        }
        for (int index = 1; index < argc; index += 2) {
            const char *name = argv[index];
            const char *value = argv[index + 1];
            if (!strcmp(name, "--seconds") && !seconds) {
                if (!parseNumber(value, &seconds)) return 2;
            } else if (!strcmp(name, "--preview-pid") && !rawPid) {
                if (!parseNumber(value, &rawPid)) return 2;
            } else if (!strcmp(name, "--output") && !output) {
                output = value;
            } else if (!strcmp(name, "--expected-bundle") && !expectedBundle) {
                expectedBundle = [NSString stringWithUTF8String:value];
            } else {
                fprintf(stderr, "Invalid or duplicate argument: %s\n", name);
                return 2;
            }
        }
        if (seconds < 45 || seconds > 180 || rawPid <= 0 || rawPid > INT_MAX ||
            !output || output[0] != '/' ||
            !([expectedBundle isEqualToString:@"dev.rustdesk.air.Client"] ||
              [expectedBundle isEqualToString:@"dev.rustdesk.air.Host"])) {
            fprintf(stderr, "Duration, output path, preview PID, or bundle ID is invalid\n");
            return 2;
        }

        pid_t pid = static_cast<pid_t>(rawPid);
        NSRunningApplication *preview = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!preview || preview.isTerminated ||
            ![preview.bundleIdentifier isEqualToString:expectedBundle]) {
            fprintf(stderr, "Preview PID is not a running instance of the expected bundle\n");
            return 2;
        }
        NSDate *launchDate = preview.launchDate;

        int fd = open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0 || fchmod(fd, 0600) != 0) {
            fprintf(stderr, "Unable to create exclusive private output: %s\n", strerror(errno));
            if (fd >= 0) {
                close(fd);
                unlink(output);
            }
            return 2;
        }
        FILE *file = fdopen(fd, "w");
        if (!file) {
            fprintf(stderr, "Unable to open output stream: %s\n", strerror(errno));
            close(fd);
            unlink(output);
            return 2;
        }

        struct sigaction action = {};
        action.sa_handler = stopMonitor;
        sigemptyset(&action.sa_mask);
        sigaction(SIGINT, &action, nullptr);
        sigaction(SIGTERM, &action, nullptr);

        const auto start = std::chrono::steady_clock::now();
        const long long startedAt = wallMilliseconds();
        bool alive = true;
        long long aliveMilliseconds = 0;
        long long stoppedAt = -1;
        NSString *front = nil;
        bool frontKnown = false;
        bool writeFailed = false;
        std::map<std::string, AppTotals> apps;
        if (!writeRecord(file, @{@"type": @"start", @"wall_ms": @(startedAt),
                                 @"preview_pid": @(pid), @"preview_bundle": expectedBundle,
                                 @"duration_ms": @(seconds * 1000)})) {
            fclose(file);
            return 1;
        }

        long long previousElapsed = 0;
        while (!interrupted) {
            auto now = std::chrono::steady_clock::now();
            long long elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count();
            if (elapsed > seconds * 1000) elapsed = seconds * 1000;
            long long delta = elapsed - previousElapsed;
            if (delta < 0) delta = 0;
            if (frontKnown) {
                apps[front ? std::string(front.UTF8String) : std::string("<unknown>")].foregroundMilliseconds += delta;
            }
            if (alive) aliveMilliseconds += delta;
            previousElapsed = elapsed;

            NSString *currentFront = [NSWorkspace sharedWorkspace].frontmostApplication.bundleIdentifier;
            if (!frontKnown || !((front == currentFront) || [front isEqualToString:currentFront])) {
                front = currentFront;
                frontKnown = true;
                apps[front ? std::string(front.UTF8String) : std::string("<unknown>")].activations++;
                if (!writeRecord(file, @{@"type": @"activation", @"elapsed_ms": @(elapsed),
                                         @"wall_ms": @(wallMilliseconds()),
                                         @"bundle_id": front ?: (id)[NSNull null]})) {
                    writeFailed = true;
                    break;
                }
            }

            bool currentAlive = previewAlive(pid, expectedBundle, launchDate);
            if (currentAlive != alive) {
                alive = currentAlive;
                if (!alive) stoppedAt = elapsed;
                if (!writeRecord(file, @{@"type": @"preview_lifetime", @"elapsed_ms": @(elapsed),
                                         @"wall_ms": @(wallMilliseconds()), @"alive": @(alive)})) {
                    writeFailed = true;
                    break;
                }
            }
            if (elapsed >= seconds * 1000) break;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }

        long long elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start).count();
        if (elapsed > seconds * 1000) elapsed = seconds * 1000;
        long long remaining = elapsed - previousElapsed;
        if (remaining > 0) {
            if (frontKnown) apps[front ? std::string(front.UTF8String) : std::string("<unknown>")].foregroundMilliseconds += remaining;
            if (alive) aliveMilliseconds += remaining;
        }
        NSMutableArray *totals = [NSMutableArray array];
        for (const auto &entry : apps) {
            NSString *bundle = [NSString stringWithUTF8String:entry.first.c_str()];
            [totals addObject:@{@"bundle_id": [bundle isEqualToString:@"<unknown>"] ? (id)[NSNull null] : bundle,
                                @"activations": @(entry.second.activations),
                                @"foreground_ms": @(entry.second.foregroundMilliseconds)}];
        }
        bool saved = writeRecord(file, @{@"type": @"summary", @"elapsed_ms": @(elapsed),
                                         @"wall_ms": @(wallMilliseconds()),
                                         @"interrupted": @(interrupted != 0),
                                         @"preview_alive_at_end": @(alive),
                                         @"preview_alive_ms": @(aliveMilliseconds),
                                         @"preview_stopped_ms": stoppedAt < 0 ? (id)[NSNull null] : @(stoppedAt),
                                         @"apps": totals});
        saved = fclose(file) == 0 && saved && !writeFailed;
        if (!saved) fprintf(stderr, "Monitor output was not saved completely\n");
        return saved ? (interrupted ? 130 : 0) : 1;
    }
}
