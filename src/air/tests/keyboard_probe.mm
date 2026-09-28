#include "../native.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <cstdio>
#include <vector>

// Diagnostic only: posts into the OS HID path, never input/network callbacks.
static std::atomic<bool> configured(false), scheduled(false), started(false);
static std::atomic<uint64_t> generation(0);
static uint64_t nowNs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static CGEventFlags unsafeModifiers() {
  constexpr auto m = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl |
                     kCGEventFlagMaskShift | kCGEventFlagMaskSecondaryFn;
  return CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & m;
}
static CGEventRef key(CGKeyCode code, bool down, CGEventFlags flags) {
  auto e = CGEventCreateKeyboardEvent(nullptr, code, down);
  if (e)
    CGEventSetFlags(e, flags);
  return e;
}
static CGEventRef media(bool down) {
  NSEvent *n = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                  location:NSZeroPoint
                             modifierFlags:down ? 10 : 11
                                 timestamp:0
                              windowNumber:0
                                   context:nil
                                   subtype:8
                                     data1:(16 << 16) | ((down ? 10 : 11) << 8)
                                     data2:-1];
  return n.CGEvent ? CGEventCreateCopy(n.CGEvent) : nullptr;
}
static bool safe(uint64_t g) {
  return g == generation.load() && air_input_grabbing() && NSApp.isActive &&
         CGPreflightPostEventAccess() && !unsafeModifiers();
}
static NSArray *retainEvents(const std::vector<CGEventRef> &events) {
  NSMutableArray *a = [NSMutableArray arrayWithCapacity:events.size()];
  for (auto e : events)
    [a addObject:(__bridge id)e];
  return a;
}
static void releaseEvents(std::vector<CGEventRef> &events) {
  for (auto e : events)
    if (e)
      CFRelease(e);
  events.clear();
}
static bool complete(const std::vector<CGEventRef> &events) {
  for (auto e : events)
    if (!e)
      return false;
  return true;
}
static void post(NSArray *events) {
  for (id object in events)
    CGEventPost(kCGHIDEventTap, (__bridge CGEventRef)object);
}
static void run(uint64_t g) {
  if (g != generation.load())
    return;
  if (!configured.load() || started.exchange(true) || !safe(g)) {
    fprintf(stderr, "air_keyboard_extended_aborted=preflight timestamp_ns=%llu\n",
            (unsigned long long)nowNs());
    scheduled = false;
    return;
  }
  std::vector<CGEventRef> baseline = {key(106, true, 0), key(106, false, 0), key(64, true, 0),
                                      key(64, false, 0), key(79, true, 0),   key(79, false, 0)};
  std::vector<CGEventRef> extended = {key(49, true, kCGEventFlagMaskCommand),
                                      key(49, false, kCGEventFlagMaskCommand),
                                      key(48, true, kCGEventFlagMaskCommand),
                                      key(48, false, kCGEventFlagMaskCommand),
                                      media(true),
                                      media(false),
                                      key(122, true, kCGEventFlagMaskSecondaryFn),
                                      key(122, false, kCGEventFlagMaskSecondaryFn)};
  auto chord = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;
  std::vector<CGEventRef> finish = {key(53, true, chord), key(53, false, chord), key(55, false, 0),
                                    key(58, false, 0), key(59, false, 0)};
  for (size_t i = 2; i < finish.size(); i++)
    if (finish[i])
      CGEventSetType(finish[i], kCGEventFlagsChanged);
  if (!complete(baseline) || !complete(extended) || !complete(finish)) {
    releaseEvents(baseline);
    releaseEvents(extended);
    releaseEvents(finish);
    scheduled = false;
    fprintf(stderr, "air_keyboard_extended_constructed=0 timestamp_ns=%llu\n",
            (unsigned long long)nowNs());
    return;
  }
  NSArray *b = retainEvents(baseline), *x = retainEvents(extended), *f = retainEvents(finish);
  releaseEvents(baseline);
  releaseEvents(extended);
  releaseEvents(finish);
  post(b);
  fprintf(stderr, "air_keyboard_extended_phase=baseline timestamp_ns=%llu\n",
          (unsigned long long)nowNs());
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (g != generation.load())
      return;
    if (!safe(g)) {
      fprintf(stderr, "air_keyboard_extended_aborted=extended_preflight timestamp_ns=%llu\n",
              (unsigned long long)nowNs());
      scheduled = false;
      return;
    }
    post(x);
    fprintf(stderr,
            "air_keyboard_extended_phase=shortcuts_media_fn events=8 action_tested=0 "
            "timestamp_ns=%llu\n",
            (unsigned long long)nowNs());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (g != generation.load())
        return;
      if (!safe(g)) {
        fprintf(stderr, "air_keyboard_extended_aborted=emergency_preflight timestamp_ns=%llu\n",
                (unsigned long long)nowNs());
        scheduled = false;
        return;
      }
      post(f);
      fprintf(stderr, "air_keyboard_extended_final_posted=1 total_events=19 timestamp_ns=%llu\n",
              (unsigned long long)nowNs());
      scheduled = false;
    });
  });
}
extern "C" int air_keyboard_probe_configure(int enabled) {
  if (enabled != 0 && enabled != 1) {
    air_set_error("Keyboard path probe setting must be 0 or 1");
    return -1;
  }
  if (scheduled || started) {
    air_set_error("Keyboard path probe must be configured before a session");
    return -1;
  }
  configured = enabled != 0;
  return 0;
}
extern "C" void air_keyboard_probe_ready(int ready) {
  if (!ready) {
    ++generation;
    scheduled = false;
    return;
  }
  if (!configured.load() || started.load() || scheduled.exchange(true))
    return;
  uint64_t g = ++generation;
  fprintf(stderr, "air_keyboard_extended_scheduled=1 delay_seconds=6 timestamp_ns=%llu\n",
          (unsigned long long)nowNs());
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    run(g);
  });
}
extern "C" void air_keyboard_probe_shutdown() {
  ++generation;
  scheduled = false;
  configured = false;
}
