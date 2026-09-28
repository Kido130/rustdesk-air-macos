#import <AppKit/AppKit.h>
#include "native.h"
#include <mutex>
#include <vector>
#include <cmath>
#include <string>
#include <algorithm>
#include <atomic>
#include <dispatch/dispatch.h>

static std::mutex displayMutex;
struct SavedOrigin { std::string uuid; int32_t x,y; };
struct ModeKey {
    size_t width=0,height=0,pixelWidth=0,pixelHeight=0;
    int32_t ioMode=0;
};
static std::vector<SavedOrigin> savedOrigins;
static std::vector<std::string> lastTopology;
static CGDisplayModeRef savedMode=nullptr, appliedMode=nullptr;
static std::string changedUUID;
static ModeKey originalKey, appliedKey;
static bool restorePending=false, callbackRegistered=false, retryBurstArmed=false;
static bool displayShuttingDown=false;
static uint64_t displayGeneration=0, retryBurst=0;
static std::atomic<bool> callbackQueued{false};

static int displayError(const std::string &message) { air_set_error(message.c_str()); return -1; }
static bool sameSpec(CGDisplayModeRef mode,const AirDisplaySpec &s) {
    return mode && CGDisplayModeGetWidth(mode)==s.logical_width && CGDisplayModeGetHeight(mode)==s.logical_height
        && CGDisplayModeGetPixelWidth(mode)==s.pixel_width && CGDisplayModeGetPixelHeight(mode)==s.pixel_height;
}
extern "C" int air_display_current(AirDisplaySpec *spec) {
    if (!spec) return displayError("Missing Air display information");
    auto display=air_builtin_display();
    auto mode=display ? CGDisplayCopyDisplayMode(display) : nullptr;
    if (!mode) return displayError("The built-in display is unavailable");
    *spec={(uint32_t)CGDisplayModeGetWidth(mode),(uint32_t)CGDisplayModeGetHeight(mode),
        (uint32_t)CGDisplayModeGetPixelWidth(mode),(uint32_t)CGDisplayModeGetPixelHeight(mode)};
    CGDisplayModeRelease(mode); return 0;
}
static ModeKey modeKey(CGDisplayModeRef mode) {
    if (!mode) return {};
    return {CGDisplayModeGetWidth(mode),CGDisplayModeGetHeight(mode),
        CGDisplayModeGetPixelWidth(mode),CGDisplayModeGetPixelHeight(mode),
        CGDisplayModeGetIODisplayModeID(mode)};
}
static bool sameMode(const ModeKey &a,const ModeKey &b) {
    return a.width==b.width && a.height==b.height && a.pixelWidth==b.pixelWidth
        && a.pixelHeight==b.pixelHeight && a.ioMode==b.ioMode;
}
static std::string displayUUID(CGDirectDisplayID display) {
    auto uuid=CGDisplayCreateUUIDFromDisplayID(display);
    if (!uuid) return {};
    auto value=CFUUIDCreateString(kCFAllocatorDefault,uuid);
    CFRelease(uuid);
    if (!value) return {};
    auto result=std::string([(__bridge NSString *)value UTF8String] ?: "");
    CFRelease(value);
    return result;
}
static bool onlineDisplays(std::vector<std::pair<std::string,CGDirectDisplayID>> &displays) {
    CGDirectDisplayID ids[32]; uint32_t count=0;
    if (CGGetOnlineDisplayList(32,ids,&count)) return false;
    displays.clear();
    for (uint32_t i=0;i<count;i++) {
        auto uuid=displayUUID(ids[i]);
        if (uuid.empty()) return false;
        displays.push_back({uuid,ids[i]});
    }
    return true;
}
static std::vector<std::string> topology(const std::vector<std::pair<std::string,CGDirectDisplayID>> &displays) {
    std::vector<std::string> result;
    for (const auto &entry:displays) result.push_back(entry.first);
    std::sort(result.begin(),result.end());
    return result;
}
static CGDirectDisplayID findDisplay(const std::vector<std::pair<std::string,CGDirectDisplayID>> &displays,
                                     const std::string &uuid) {
    for (const auto &entry:displays) if (entry.first==uuid) return entry.second;
    return 0;
}
static bool originsMatch(const std::vector<std::pair<std::string,CGDirectDisplayID>> &displays) {
    if (displays.size()!=savedOrigins.size()) return false;
    for (const auto &origin:savedOrigins) {
        auto display=findDisplay(displays,origin.uuid);
        if (!display) return false;
        auto bounds=CGDisplayBounds(display);
        if (fabs(bounds.origin.x-origin.x)>0.5 || fabs(bounds.origin.y-origin.y)>0.5) return false;
    }
    return true;
}
static CGDisplayModeRef exactOriginalMode(CGDirectDisplayID display) {
    NSDictionary *options=@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES};
    auto modes=CGDisplayCopyAllDisplayModes(display,(__bridge CFDictionaryRef)options);
    CGDisplayModeRef selected=nullptr;
    if (modes) for (CFIndex i=0;i<CFArrayGetCount(modes);i++) {
        auto mode=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);
        if (CGDisplayModeIsUsableForDesktopGUI(mode) && sameMode(modeKey(mode),originalKey)) {
            selected=CGDisplayModeRetain(mode); break;
        }
    }
    if (modes) CFRelease(modes);
    return selected;
}
static int configure(CGDirectDisplayID display,CGDisplayModeRef mode,
                     const std::vector<std::pair<std::string,CGDirectDisplayID>> *origins,
                     const std::vector<SavedOrigin> *originValues=nullptr) {
    CGDisplayConfigRef config=nullptr;
    auto error=CGBeginDisplayConfiguration(&config);
    if (error) return displayError("Cannot start display configuration: "+std::to_string(error));
    error=CGConfigureDisplayWithDisplayMode(config,display,mode,nullptr);
    if (origins && !error) {
        for (const auto &origin:originValues ? *originValues : savedOrigins) {
            auto id=findDisplay(*origins,origin.uuid);
            if (!id) { error=kCGErrorFailure; break; }
            error=CGConfigureDisplayOrigin(config,id,origin.x,origin.y);
            if (error) break;
        }
    }
    if (error) { CGCancelDisplayConfiguration(config); return displayError("Cannot configure display: "+std::to_string(error)); }
    // The OS also reverts this temporary configuration if the host crashes.
    error=CGCompleteDisplayConfiguration(config,kCGConfigureForAppOnly);
    return error ? displayError("Cannot apply display configuration: "+std::to_string(error)) : 0;
}
static void clearSavedLocked() {
    if (savedMode) CGDisplayModeRelease(savedMode);
    if (appliedMode) CGDisplayModeRelease(appliedMode);
    savedMode=nullptr; appliedMode=nullptr; changedUUID.clear(); savedOrigins.clear();
    originalKey={}; appliedKey={}; restorePending=false; retryBurstArmed=false;
    ++displayGeneration; ++retryBurst;
}
static int restoreLocked() {
    if (!savedMode) return 0;
    std::vector<std::pair<std::string,CGDirectDisplayID>> displays;
    if (!onlineDisplays(displays)) return displayError("Cannot inspect displays for deferred restoration");
    lastTopology=topology(displays);
    auto display=findDisplay(displays,changedUUID);
    if (!display || !CGDisplayIsBuiltin(display)) {
        return displayError("The original built-in display is unavailable; restoration is pending");
    }
    std::vector<std::string> originalTopology;
    for (const auto &origin:savedOrigins) originalTopology.push_back(origin.uuid);
    std::sort(originalTopology.begin(),originalTopology.end());
    bool originalLayoutAvailable=topology(displays)==originalTopology;
    auto current=CGDisplayCopyDisplayMode(display);
    if (!current) return displayError("Cannot read the built-in mode for restoration");
    auto key=modeKey(current);
    CGDisplayModeRelease(current);
    if (!sameMode(key,originalKey) && !sameMode(key,appliedKey))
        return displayError("The built-in mode changed outside Air; restoration is pending");
    if (!originalLayoutAvailable) {
        if (!sameMode(key,originalKey)) {
            auto original=exactOriginalMode(display);
            if (!original) return displayError("The original built-in mode is unavailable; restoration is pending");
            std::vector<SavedOrigin> currentOrigins;
            for (const auto &entry:displays) {
                auto bounds=CGDisplayBounds(entry.second);
                currentOrigins.push_back({entry.first,(int32_t)bounds.origin.x,(int32_t)bounds.origin.y});
            }
            // Restore the built-in scale while preserving the presently connected layout.
            auto result=configure(display,original,&displays,&currentOrigins);
            CGDisplayModeRelease(original);
            if (result) return result;
            auto actual=CGDisplayCopyDisplayMode(display);
            bool restored=actual && sameMode(modeKey(actual),originalKey);
            if (actual) CGDisplayModeRelease(actual);
            if (!restored) return displayError("macOS has not restored the original built-in mode");
        }
        return displayError("The built-in scale is restored; the original display layout is still unavailable");
    }
    if (sameMode(key,originalKey) && originsMatch(displays)) { clearSavedLocked(); return 0; }
    auto original=exactOriginalMode(display);
    if (!original) return displayError("The original built-in mode is unavailable; restoration is pending");
    auto result=configure(display,original,&displays);
    CGDisplayModeRelease(original);
    if (result) return result;
    std::vector<std::pair<std::string,CGDirectDisplayID>> actualDisplays;
    bool verified=onlineDisplays(actualDisplays) && originsMatch(actualDisplays);
    auto actualDisplay=verified ? findDisplay(actualDisplays,changedUUID) : 0;
    auto actual=actualDisplay && CGDisplayIsBuiltin(actualDisplay) ? CGDisplayCopyDisplayMode(actualDisplay) : nullptr;
    verified=verified && actual && sameMode(modeKey(actual),originalKey);
    if (actual) CGDisplayModeRelease(actual);
    if (!verified) return displayError("macOS has not restored the original display mode and layout");
    clearSavedLocked();
    return 0;
}
static void retryStepLocked(uint64_t generation,uint64_t burst,unsigned attempt);
static void scheduleRetryLocked(uint64_t generation,uint64_t burst,unsigned attempt) {
    if (attempt>=3) { retryBurstArmed=false; return; }
    auto delay=attempt==1 ? 500 : 1500;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,int64_t(delay)*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(displayMutex);
        retryStepLocked(generation,burst,attempt);
    });
}
static void retryStepLocked(uint64_t generation,uint64_t burst,unsigned attempt) {
    if (!savedMode || !restorePending || generation!=displayGeneration || burst!=retryBurst) return;
    auto result=restoreLocked();
    if (result && savedMode) scheduleRetryLocked(generation,burst,attempt+1);
    else retryBurstArmed=false;
}
static void processDisplayChangedLocked() {
    if (!savedMode) return;
    std::vector<std::pair<std::string,CGDirectDisplayID>> displays;
    if (!onlineDisplays(displays)) return;
    auto currentTopology=topology(displays);
    if (currentTopology==lastTopology) return;
    lastTopology=currentTopology;
    ++retryBurst; retryBurstArmed=false;
    if (!restorePending || !findDisplay(displays,changedUUID)) return;
    auto generation=displayGeneration, burst=retryBurst;
    retryBurstArmed=true;
    auto result=restoreLocked();
    if (result && savedMode) scheduleRetryLocked(generation,burst,1);
    else retryBurstArmed=false;
}
static void displayChanged(CGDirectDisplayID,CGDisplayChangeSummaryFlags flags,void *) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    if (callbackQueued.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        callbackQueued=false;
        std::lock_guard<std::mutex> lock(displayMutex);
        processDisplayChangedLocked();
    });
}
extern "C" int air_display_match(const AirDisplaySpec *spec) {
    std::lock_guard<std::mutex> lock(displayMutex);
    if (displayShuttingDown) return displayError("The Air host is shutting down");
    if (!spec || !spec->logical_width || !spec->logical_height || spec->logical_width>8192 || spec->logical_height>8192
        || !spec->pixel_width || !spec->pixel_height || spec->pixel_width>8192 || spec->pixel_height>8192
        || uint64_t(spec->pixel_width)*spec->pixel_height>16777216)
        return displayError("Invalid Air resolution or scaling");
    if (savedMode) return displayError(restorePending ? "Original display restoration is pending" : "Display matching is already in use");
    auto display=air_builtin_display();
    if (!display || CGDisplayIsInMirrorSet(display)) return displayError("Display matching needs the unmirrored built-in display");
    auto current=CGDisplayCopyDisplayMode(display);
    if (!current) return displayError("Cannot read the Pro display mode");
    NSDictionary *options=@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES};
    CFArrayRef modes=CGDisplayCopyAllDisplayModes(display,(__bridge CFDictionaryRef)options);
    CGDisplayModeRef selected=nullptr;
    double best=1e9;
    if (modes) for (CFIndex i=0;i<CFArrayGetCount(modes);i++) {
        auto mode=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode) || !sameSpec(mode,*spec)) continue;
        double score=fabs(CGDisplayModeGetRefreshRate(mode)-CGDisplayModeGetRefreshRate(current));
        if (score<best) { best=score; selected=mode; }
    }
    double bestFallbackRefresh=1e9;
    if (!selected && modes) for (CFIndex i=0;i<CFArrayGetCount(modes);i++) {
        auto mode=(CGDisplayModeRef)CFArrayGetValueAtIndex(modes,i);
        if (!CGDisplayModeIsUsableForDesktopGUI(mode)
            || CGDisplayModeGetPixelWidth(mode)!=spec->pixel_width
            || CGDisplayModeGetPixelHeight(mode)!=spec->pixel_height) continue;
        double widthRatio=double(CGDisplayModeGetWidth(mode))/spec->logical_width;
        double heightRatio=double(CGDisplayModeGetHeight(mode))/spec->logical_height;
        double widthError=fabs(widthRatio-1.0), heightError=fabs(heightRatio-1.0);
        // Preserve one source pixel per Air pixel and reject visibly different UI scales or aspect ratios.
        if (std::max(widthError,heightError)>0.15 || fabs(widthRatio-heightRatio)>0.02) continue;
        double score=std::max(widthError,heightError);
        double refreshError=fabs(CGDisplayModeGetRefreshRate(mode)-CGDisplayModeGetRefreshRate(current));
        if (score<best || (score==best && refreshError<bestFallbackRefresh)) {
            best=score; bestFallbackRefresh=refreshError; selected=mode;
        }
    }
    if (selected) CGDisplayModeRetain(selected);
    if (modes) CFRelease(modes);
    if (!selected) {
        CGDisplayModeRelease(current);
        return displayError("The Pro has no pixel-matched display mode near this Air scaling ("+std::to_string(spec->logical_width)+"×"+
            std::to_string(spec->logical_height)+" points, "+std::to_string(spec->pixel_width)+"×"+
            std::to_string(spec->pixel_height)+" pixels). Choose a supported Air scaling or turn off Match Air display.");
    }
    if (sameSpec(current,*spec) || sameMode(modeKey(current),modeKey(selected))) {
        CGDisplayModeRelease(current); CGDisplayModeRelease(selected); return 0;
    }
    std::vector<std::pair<std::string,CGDirectDisplayID>> displays;
    if (!onlineDisplays(displays)) {
        CGDisplayModeRelease(current); CGDisplayModeRelease(selected);
        return displayError("Cannot save display layout");
    }
    auto uuid=displayUUID(display);
    if (uuid.empty() || findDisplay(displays,uuid)!=display) {
        CGDisplayModeRelease(current); CGDisplayModeRelease(selected);
        return displayError("Cannot identify the built-in display");
    }
    if (!callbackRegistered) {
        auto error=CGDisplayRegisterReconfigurationCallback(displayChanged,nullptr);
        if (error) {
            CGDisplayModeRelease(current); CGDisplayModeRelease(selected);
            return displayError("Cannot monitor display restoration: "+std::to_string(error));
        }
        callbackRegistered=true;
    }
    savedOrigins.clear();
    for (const auto &entry:displays) {
        auto b=CGDisplayBounds(entry.second);
        savedOrigins.push_back({entry.first,(int32_t)b.origin.x,(int32_t)b.origin.y});
    }
    savedMode=current; appliedMode=selected; changedUUID=uuid;
    originalKey=modeKey(current); appliedKey=modeKey(selected);
    lastTopology=topology(displays);
    restorePending=false; retryBurstArmed=false;
    ++displayGeneration; ++retryBurst;
    if (configure(display,selected,nullptr)) {
        restorePending=true;
        if (restoreLocked() && savedMode) {
            retryBurstArmed=true;
            scheduleRetryLocked(displayGeneration,retryBurst,1);
        }
        return -1;
    }
    auto actual=CGDisplayCopyDisplayMode(display); bool matched=actual && sameMode(modeKey(actual),appliedKey);
    if (actual) CGDisplayModeRelease(actual);
    if (!matched) {
        restorePending=true;
        if (restoreLocked() && savedMode) {
            retryBurstArmed=true;
            scheduleRetryLocked(displayGeneration,retryBurst,1);
        }
        return displayError("macOS did not apply the requested Air display mode");
    }
    return 0;
}
extern "C" int air_display_restore() {
    std::lock_guard<std::mutex> lock(displayMutex);
    if (!savedMode) return 0;
    restorePending=true;
    auto result=restoreLocked();
    if (result && savedMode && !retryBurstArmed) {
        std::vector<std::pair<std::string,CGDirectDisplayID>> displays;
        if (onlineDisplays(displays) && findDisplay(displays,changedUUID)) {
            retryBurstArmed=true;
            scheduleRetryLocked(displayGeneration,retryBurst,1);
        }
    }
    return result;
}
extern "C" int air_display_shutdown() {
    {
        std::lock_guard<std::mutex> lock(displayMutex);
        displayShuttingDown=true;
    }
    return air_display_restore();
}
