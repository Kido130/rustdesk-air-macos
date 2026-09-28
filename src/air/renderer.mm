#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <IOSurface/IOSurface.h>
#include "native.h"
#include "presentation_geometry.h"
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <sys/stat.h>

static std::mutex errorMutex;
static std::string lastError;
static void (*microphoneCallback)(int)=nullptr;
static NSMenuItem *microphoneMenuItem;
static int fail(const char *text, int code = 0) {
    std::lock_guard<std::mutex> lock(errorMutex);
    lastError = std::string(text) + (code ? ": " + std::to_string(code) : "");
    return -1;
}
extern "C" const char *air_last_error() {
    static thread_local std::string copy;
    std::lock_guard<std::mutex> lock(errorMutex); copy = lastError; return copy.c_str();
}
extern "C" void air_set_error(const char *message) { fail(message); }

static const char *shader = R"METAL(
#include <metal_stdlib>
using namespace metal;
struct V { float4 position [[position]]; float2 uv; };
struct Params { float4 y; float4 r; float4 g; float4 b; float4 fit; float4 cursor; };
vertex V vertexMain(uint i [[vertex_id]], constant Params& p [[buffer(0)]]) {
    const float2 xy[] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
    const float2 uv[] = {float2(0,1),float2(1,1),float2(0,0),float2(1,0)};
    return {float4(xy[i]*p.fit.xy,0,1),uv[i]};
}
fragment float4 bgraMain(V v [[stage_in]], texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(image.sample(s,v.uv).rgb,1);
}
fragment float4 yuvMain(V v [[stage_in]], texture2d<float> y [[texture(0)]],
                      texture2d<float> cbcr [[texture(1)]], constant Params& p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 v3 = float3((y.sample(s,v.uv).r-p.y.x)*p.y.y, cbcr.sample(s,v.uv).rg-float2(p.y.z));
    return float4(dot(v3,p.r.xyz),dot(v3,p.g.xyz),dot(v3,p.b.xyz),1);
}
)METAL";

struct Params { float y[4], r[4], g[4], b[4], fit[4], cursor[4]; };
struct PixelFrame {
    CVPixelBufferRef buffer = nullptr;
    CVMetalTextureRef y = nullptr, uv = nullptr;
    uint64_t serial = 0;
    Params params = {};
    ~PixelFrame() { if (y) CFRelease(y); if (uv) CFRelease(uv); if (buffer) CFRelease(buffer); }
};

@interface AirView : MTKView <MTKViewDelegate, NSWindowDelegate>
@end
@interface AirApplicationDelegate : NSObject <NSApplicationDelegate>
@end
static void prepareAppTermination();
@implementation AirApplicationDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // AppKit terminates the process without returning from air_app_run().
    prepareAppTermination();
    return NSTerminateNow;
}
@end
static AirApplicationDelegate *applicationDelegate;
static id<MTLDevice> device;
static id<MTLCommandQueue> commandQueue;
static id<MTLRenderPipelineState> bgraPipeline, yuvPipeline;
static CVMetalTextureCacheRef textureCache;
static std::mutex surfaceMutex;
static id<MTLTexture> desktop, pendingDesktop;
static id<MTLCommandBuffer> patchCommand;
static id<MTLBlitCommandEncoder> patchBlit;
static std::shared_ptr<PixelFrame> videoFrame;
static AirView *view;
static NSWindow *window;
static NSString *hostPairingPath;
static NSTextField *hostStatus;
static NSTextField *hostPermissionStatus;
static NSTextField *clientStatus;
static bool clientStatusError=false;
static bool clientFrameSubmitted=false;
static AirInput inputCallback;
static void *inputContext;
static std::atomic<bool> drawQueued(false);
static std::atomic<bool> drawPending(false);
static std::atomic<uint64_t> drawRequests(0), drawCoalesced(0);
static bool immediateVideoDraw=false;
static bool presentTraceEnabled=false;
static std::atomic<uint64_t> nextVideoSerial(0);
static std::atomic<uint64_t> lastPresentedVideoSerial(0), uniquePresentedVideoFrames(0);
struct VideoPresentation { uint64_t serial; double seconds; };
static constexpr size_t presentTraceCapacity=4096;
static std::mutex presentTraceMutex;
static std::vector<VideoPresentation> presentTrace;
static size_t presentTraceNext=0;
static uint64_t presentTraceOverwritten=0;
static void recordVideoPresentation(uint64_t serial,double seconds) {
    std::lock_guard<std::mutex> lock(presentTraceMutex);
    if (presentTrace.size()<presentTraceCapacity) presentTrace.push_back({serial,seconds});
    else {
        presentTrace[presentTraceNext]={serial,seconds};
        presentTraceNext=(presentTraceNext+1)%presentTraceCapacity;
        presentTraceOverwritten++;
    }
}
static std::atomic<bool> appStopRequested(false);
static AirAppCleanup appCleanup=nullptr;
static void *appCleanupContext=nullptr;
static bool appCleanupStarted=false;
static id<MTLBuffer> uploadStaging;
static size_t uploadOffset=0;
static std::atomic<uint64_t> presented(0), decoded(0), patchBytes(0), patches(0), hardwareSessions(0);
static std::atomic<uint64_t> submitted(0), dropped(0), drawableMisses(0);
extern "C" void air_presentation_counters(uint64_t *unique, uint64_t *missed) {
    if (unique) *unique=uniquePresentedVideoFrames.load(std::memory_order_relaxed);
    if (missed) *missed=dropped.load(std::memory_order_relaxed);
}
static std::atomic<uint32_t> consecutiveDrops(0);
static std::atomic<uint64_t> receivedVideoBytes(0);
static std::atomic<uint64_t> exactCommits(0);
static std::atomic<int> lastSurfaceKind(0);
extern "C" void air_video_bytes(size_t bytes) { receivedVideoBytes += bytes; }
static bool matchDisplay=false, chosenDisplayMatch=true, chosenRemoteMode=true;
static bool chosenRemoteSpaces=true, chosenRawContacts=true;
static std::atomic<uint64_t> pixelMatchedPresentations(0), pixelIdentityTests(0);
static std::atomic<uint64_t> lastPresentedRaster(0);
static std::atomic<uint64_t> rasterMismatchSkips(0);
static std::atomic<uint64_t> reconnectHoldGeneration(0), reconnectHolds(0), reconnectHoldExpirations(0);
static std::atomic<uint32_t> lastSourceWidth(0),lastSourceHeight(0),lastDrawableWidth(0),lastDrawableHeight(0);
static dispatch_semaphore_t drawCredits;
static bool hostWindow=false;
extern "C" void air_app_set_cleanup(AirAppCleanup cleanup,void *context) {
    appCleanup=cleanup; appCleanupContext=context;
}
static void prepareAppTermination() {
    if(appCleanupStarted) return;
    appCleanupStarted=true;
    appStopRequested=true;
    if(appCleanup) appCleanup(appCleanupContext);
    air_overlay_shutdown();
}
static std::atomic<uint32_t> inputWidth(0),inputHeight(0);
extern "C" void air_input_dimensions(uint32_t w,uint32_t h) { inputWidth=w; inputHeight=h; }

static void requestDraw() {
    drawRequests++;
    if (drawQueued.exchange(true)) { drawCoalesced++; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        drawQueued = false;
        // AppKit can defer an invalidation past the next decoded frame. The
        // existing two-credit gate still bounds outstanding command buffers.
        if (immediateVideoDraw && !hostWindow) [view draw];
        else [view setNeedsDisplay:YES];
    });
}
extern "C" void air_request_draw() { requestDraw(); }
static bool takeDrawCredit() {
    // Publish before the wait so a completion between a failed wait and return
    // cannot lose the request for the next (possibly static Exact) frame.
    drawPending=true;
    if(dispatch_semaphore_wait(drawCredits,DISPATCH_TIME_NOW)!=0)return false;
    drawPending=false;
    return true;
}
static void returnDrawCredit() {
    dispatch_semaphore_signal(drawCredits);
    if(drawPending.exchange(false))requestDraw();
}
static void sendInput(int kind, NSEvent *event, uint32_t code = 0) {
    if (!inputCallback) return;
    NSPoint p = [view convertPoint:event.locationInWindow fromView:nil];
    if (!hostWindow && air_overlay_pointer(p.x,p.y)) return;
    double w, h;
    { std::lock_guard<std::mutex> lock(surfaceMutex);
      w = videoFrame ? CVPixelBufferGetWidth(videoFrame->buffer) : desktop.width;
      h = videoFrame ? CVPixelBufferGetHeight(videoFrame->buffer) : desktop.height; }
    if (w <= 0 || h <= 0) return;
    bool fullScreen=(window.styleMask & NSWindowStyleMaskFullScreen)!=0;
    auto fit=air_presentation_fit(w,h,view.drawableSize.width,view.drawableSize.height,
        fullScreen,matchDisplay);
    auto source=air_presentation_source_point(p.x,p.y,view.bounds.size.width,
        view.bounds.size.height,w,h,fit);
    if (!source.inside) return;
    double x=source.x,y=source.y;
    if (inputWidth && inputHeight) { x=x*inputWidth/w; y=y*inputHeight/h; }
    inputCallback(kind, x, y, code, event.modifierFlags, inputContext);
}

@implementation AirView
- (void)toggleAirMicrophone:(NSMenuItem *)sender {
    const bool enabled=sender.state!=NSControlStateValueOn;
    sender.state=enabled ? NSControlStateValueOn : NSControlStateValueOff;
    if (microphoneCallback) microphoneCallback(enabled ? 1 : 0);
}
- (void)exportPairing:(id)sender {
    NSSavePanel *panel=[NSSavePanel savePanel];
    panel.nameFieldStringValue=@"RustDesk Air Pairing.json";
    panel.message=@"Save this file and transfer it privately to your Air. It grants access to this Mac.";
    if ([panel runModal]!=NSModalResponseOK) return;
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:hostPairingPath options:0 error:&error];
    if (!data || ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]
        || chmod(panel.URL.fileSystemRepresentation,0600)!=0) {
        air_show_error(error ? error.localizedDescription.UTF8String : "Could not protect the pairing file.");
    }
}
- (void)requestScreenRecording:(id)sender {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self requestScreenRecording:sender]; });
        return;
    }
    bool alreadyAllowed=CGPreflightScreenCaptureAccess();
    bool allowed=alreadyAllowed || CGRequestScreenCaptureAccess();
    hostPermissionStatus.stringValue=allowed
        ? (alreadyAllowed ? @"Screen Recording is already allowed."
                          : @"Screen Recording allowed. Reopen this Host if capture is still blocked.")
        : @"Not allowed yet. If you approved the prompt, reopen this Host. Otherwise allow it in System Settings.";
}
- (void)screenParametersChanged:(NSNotification *)notification {
    if (matchDisplay && inputCallback) inputCallback(8,0,0,0,0,inputContext);
    requestDraw();
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.arrowCursor];
}
- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent *)e { sendInput(1,e); }
- (void)mouseExited:(NSEvent *)e { air_overlay_pointer(-1,-1); }
- (void)windowDidResignKey:(NSNotification *)n { air_overlay_pointer(-1,-1); }

- (void)windowWillClose:(NSNotification *)notification { air_app_stop(); }
- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    if (window.occlusionState & NSWindowOcclusionStateVisible) { consecutiveDrops=0; requestDraw(); }
}
- (void)mtkView:(MTKView *)v drawableSizeWillChange:(CGSize)size { requestDraw(); }
- (void)drawInMTKView:(MTKView *)v {
    if (!takeDrawCredit()) return;
    std::shared_ptr<PixelFrame> frame;
    id<MTLTexture> exact;
    { std::lock_guard<std::mutex> lock(surfaceMutex); frame = videoFrame; exact = desktop; }
    if (!frame && !exact) {
        auto blank=v.currentRenderPassDescriptor;auto drawable=v.currentDrawable;
        if(!blank||!drawable){returnDrawCredit();return;}
        auto cmd=[commandQueue commandBuffer];auto render=[cmd renderCommandEncoderWithDescriptor:blank];
        [render endEncoding];[cmd presentDrawable:drawable];
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> completed){returnDrawCredit();}];
        [cmd commit];return;
    }
    double w = frame ? CVPixelBufferGetWidth(frame->buffer) : exact.width;
    double h = frame ? CVPixelBufferGetHeight(frame->buffer) : exact.height;
    lastSourceWidth=w; lastSourceHeight=h; lastDrawableWidth=v.drawableSize.width; lastDrawableHeight=v.drawableSize.height;
    bool rasterMatches=w==v.drawableSize.width && h==v.drawableSize.height;
    bool temporaryRasterMismatch=matchDisplay && (window.styleMask & NSWindowStyleMaskFullScreen)
        && !rasterMatches;
    // AppKit can replace CAMetalLayer's drawable before the Pro has captured
    // its new raster. A skipped draw exposes an empty drawable for one refresh.
    // Draw the retained image fitted to this temporary size until it matches.
    if (temporaryRasterMismatch) rasterMismatchSkips++;
    clientStatus.hidden=YES;
    clientStatusError=false;
    auto pass = v.currentRenderPassDescriptor;
    auto drawable = v.currentDrawable;
    if (!pass || !drawable) { drawableMisses++; returnDrawCredit(); return; }
    auto cmd = [commandQueue commandBuffer];
    auto render = [cmd renderCommandEncoderWithDescriptor:pass];
    Params p = frame ? frame->params : Params{};
    bool fullScreen=(window.styleMask & NSWindowStyleMaskFullScreen)!=0;
    auto fit=air_presentation_fit(w,h,v.drawableSize.width,v.drawableSize.height,
        fullScreen,matchDisplay && !temporaryRasterMismatch);
    p.fit[0]=fit.x; p.fit[1]=fit.y;
    bool pixelsMatched=matchDisplay && rasterMatches;
    [render setRenderPipelineState:frame ? yuvPipeline : bgraPipeline];
    [render setVertexBytes:&p length:sizeof(p) atIndex:0];
    [render setFragmentBytes:&p length:sizeof(p) atIndex:0];
    [render setFragmentTexture:frame ? CVMetalTextureGetTexture(frame->y) : exact atIndex:0];
    if (frame) [render setFragmentTexture:CVMetalTextureGetTexture(frame->uv) atIndex:1];
    [render drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [render endEncoding];
    if (!hostWindow) air_cursor_probe_capture_drawable((__bridge void *)cmd,(__bridge void *)drawable.texture);
    uint64_t frameSerial=frame ? frame->serial : 0;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        double presentedTime=shown.presentedTime;
        if (presentedTime>0) {
            presented++;
            if (frameSerial) {
                auto previous=lastPresentedVideoSerial.load(std::memory_order_relaxed);
                while (frameSerial>previous && !lastPresentedVideoSerial.compare_exchange_weak(
                    previous,frameSerial,std::memory_order_relaxed)) {}
                if (frameSerial>previous) uniquePresentedVideoFrames.fetch_add(1,std::memory_order_relaxed);
            }
            if (presentTraceEnabled && frameSerial) recordVideoPresentation(frameSerial,presentedTime);
            if (pixelsMatched) {
                pixelMatchedPresentations++;
                uint64_t raster=((uint64_t)w<<32)|(uint64_t)h;
                if (lastPresentedRaster.exchange(raster)!=raster)
                    fprintf(stderr,"air_pixel_matched_surface=%ux%u\n",(unsigned)w,(unsigned)h);
            }
            consecutiveDrops=0;
        }
        else {
            dropped++;
            // Intel may drop the first drawable while AppKit commits window
            // changes. A static exact desktop has no following video frame.
            if (++consecutiveDrops<=3) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,16*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
                    if (window.occlusionState & NSWindowOcclusionStateVisible) requestDraw();
                });
            }
        }
    }];
    [cmd presentDrawable:drawable];
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        // The shared pointer keeps both CVMetalTextures and the pixel buffer alive.
        (void)frame;
        if (completed.status != MTLCommandBufferStatusCompleted) fail("Metal presentation failed");
        returnDrawCredit();
    }];
    submitted++; [cmd commit];
    if (!hostWindow) clientFrameSubmitted=true;
}
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 53 && (e.modifierFlags & NSEventModifierFlagControl)
        && (e.modifierFlags & NSEventModifierFlagOption) && (e.modifierFlags & NSEventModifierFlagCommand)) {
        air_app_stop(); return;
    }
    if (!air_input_grabbing() && !air_overlay_visible()) sendInput(4,e,e.keyCode);
}
- (void)keyUp:(NSEvent *)e { if (!air_input_grabbing() && !air_overlay_visible()) sendInput(5,e,e.keyCode); }
- (void)flagsChanged:(NSEvent *)e { if (!air_input_grabbing() && !air_overlay_visible()) sendInput(6,e,e.keyCode); }
- (void)mouseMoved:(NSEvent *)e { sendInput(1,e); }
- (void)mouseDragged:(NSEvent *)e { sendInput(1,e); }
- (void)rightMouseDragged:(NSEvent *)e { sendInput(1,e); }
- (void)otherMouseDragged:(NSEvent *)e { sendInput(1,e); }
- (void)mouseDown:(NSEvent *)e { sendInput(2,e,1); }
- (void)mouseUp:(NSEvent *)e { sendInput(3,e,1); }
- (void)rightMouseDown:(NSEvent *)e { sendInput(2,e,2); }
- (void)rightMouseUp:(NSEvent *)e { sendInput(3,e,2); }
- (void)otherMouseDown:(NSEvent *)e { sendInput(2,e,4); }
- (void)otherMouseUp:(NSEvent *)e { sendInput(3,e,4); }
- (void)scrollWheel:(NSEvent *)e {
    NSPoint point=[view convertPoint:e.locationInWindow fromView:nil];
    if(air_overlay_visible() || air_overlay_pointer(point.x,point.y)) return;
    if (!air_input_grabbing() && inputCallback) inputCallback(7,e.scrollingDeltaX,e.scrollingDeltaY,0,e.modifierFlags,inputContext);
}
@end

static int initializeMetal() {
    if (device) return 0;
    device = MTLCreateSystemDefaultDevice();
    if (!device) return fail("Metal is unavailable");
    commandQueue = [device newCommandQueue];
    NSError *error = nil;
    auto library = [device newLibraryWithSource:[NSString stringWithUTF8String:shader] options:nil error:&error];
    if (!library) return fail(error.localizedDescription.UTF8String);
    for (int i=0;i<2;i++) {
        auto desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"vertexMain"];
        desc.fragmentFunction = [library newFunctionWithName:i ? @"yuvMain" : @"bgraMain"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        auto pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!pipeline) return fail(error.localizedDescription.UTF8String);
        if (i) yuvPipeline = pipeline; else bgraPipeline = pipeline;
    }
    auto status = CVMetalTextureCacheCreate(kCFAllocatorDefault,nullptr,device,nullptr,&textureCache);
    if (status) return fail("Metal texture cache failed",status);
    drawCredits = dispatch_semaphore_create(2);
    return 0;
}
extern "C" int air_app_init(AirInput callback, void *context, int host) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        applicationDelegate=[AirApplicationDelegate new]; NSApp.delegate=applicationDelegate;
        inputCallback = callback; inputContext = context; hostWindow=host!=0;
        clientFrameSubmitted=false; clientStatusError=false;
        const char *immediate=getenv("RUSTDESK_AIR_IMMEDIATE_DRAW");
        immediateVideoDraw=!immediate || strcmp(immediate,"0")!=0;
        const char *trace=getenv("RUSTDESK_AIR_PRESENT_TRACE");
        presentTraceEnabled=trace && strcmp(trace,"1")==0;
        if (presentTraceEnabled) presentTrace.reserve(presentTraceCapacity);
        if (initializeMetal()) return -1;
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120,120,host ? 440 : 720,host ? 205 : 480)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        window.title = host ? @"RustDesk Air — Pro host" : @"RustDesk Air — connecting";
        window.releasedWhenClosed = NO;
        if (host) window.contentMinSize=NSMakeSize(440,205);
        view = [[AirView alloc] initWithFrame:window.contentView.bounds device:device];
        view.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        if (!host && air_cursor_probe_enabled()) view.framebufferOnly=NO;
        view.clearColor = MTLClearColorMake(0.025,0.025,0.03,1);
        view.paused = YES; view.enableSetNeedsDisplay = YES; view.delegate = view;
        auto color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); view.colorspace = color; CGColorSpaceRelease(color);
        window.contentView = view; window.delegate = view; window.acceptsMouseMovedEvents = YES;
        if (!host) air_overlay_attach((__bridge void *)view);
        if (host) {
            hostStatus=[NSTextField wrappingLabelWithString:@"Starting the Pro host…"];
            hostStatus.textColor=NSColor.whiteColor;
            hostStatus.frame=NSMakeRect(20,130,400,55);
            hostStatus.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
            [view addSubview:hostStatus];
            hostPermissionStatus=[NSTextField wrappingLabelWithString:@"Choose Allow screen recording… if capture is blocked."];
            hostPermissionStatus.textColor=NSColor.whiteColor;
            hostPermissionStatus.frame=NSMakeRect(20,67,400,52);
            hostPermissionStatus.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
            [view addSubview:hostPermissionStatus];
            NSButton *exportButton=[NSButton buttonWithTitle:@"Export Air pairing file…" target:view action:@selector(exportPairing:)];
            exportButton.frame=NSMakeRect(20,20,220,32);
            [view addSubview:exportButton];
            NSButton *recordingButton=[NSButton buttonWithTitle:@"Allow screen recording…" target:view action:@selector(requestScreenRecording:)];
            recordingButton.frame=NSMakeRect(245,20,175,32);
            [view addSubview:recordingButton];
        } else {
            clientStatus=[NSTextField wrappingLabelWithString:@"Connecting to your Pro…"];
            clientStatus.textColor=NSColor.whiteColor;
            clientStatus.alignment=NSTextAlignmentCenter;
            clientStatus.frame=NSMakeRect(30,view.bounds.size.height/2-50,view.bounds.size.width-60,100);
            clientStatus.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin|NSViewMaxYMargin;
            [view addSubview:clientStatus];
        }
        NSMenu *menu=[NSMenu new];
        NSMenuItem *appMenu=[NSMenuItem new];
        NSMenu *actions=[NSMenu new];
        if (!host) {
            microphoneMenuItem=[actions addItemWithTitle:@"Use Air Microphone" action:@selector(toggleAirMicrophone:) keyEquivalent:@""];
            microphoneMenuItem.target=view;
            [actions addItem:NSMenuItem.separatorItem];
        }
        [actions addItemWithTitle:@"Quit RustDesk Air" action:@selector(terminate:) keyEquivalent:@"q"];
        appMenu.submenu=actions; [menu addItem:appMenu]; NSApp.mainMenu=menu;
        [window makeFirstResponder:view]; [window makeKeyAndOrderFront:nil];
        [[NSNotificationCenter defaultCenter] addObserver:view selector:@selector(screenParametersChanged:)
            name:NSApplicationDidChangeScreenParametersNotification object:nil];
        [NSApp finishLaunching];
        [NSApp activateIgnoringOtherApps:YES];
        return 0;
    }
}
extern "C" void air_microphone_menu(void (*callback)(int),int enabled) {
    microphoneCallback=callback;
    microphoneMenuItem.state=enabled ? NSControlStateValueOn : NSControlStateValueOff;
}
extern "C" void air_client_match_display(int enabled,int fullscreen) {
    matchDisplay=enabled!=0;
    if (fullscreen) {
        for (NSScreen *screen in NSScreen.screens) {
            auto number=screen.deviceDescription[@"NSScreenNumber"];
            if (CGDisplayIsBuiltin([number unsignedIntValue])) {
                [window setFrame:NSMakeRect(screen.frame.origin.x+20,screen.frame.origin.y+20,720,480) display:YES]; break;
            }
        }
        window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
        [window toggleFullScreen:nil];
    }
    requestDraw();
}
extern "C" int air_chosen_remote_mode() { return chosenRemoteMode ? 1 : 0; }
extern "C" int air_chosen_remote_spaces() { return chosenRemoteSpaces ? 1 : 0; }
extern "C" int air_chosen_raw_contacts() { return chosenRawContacts ? 1 : 0; }
extern "C" int air_chosen_display_match() { return chosenDisplayMatch ? 1 : 0; }
extern "C" int air_is_host_bundle() {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"dev.rustdesk.air.Host"];
}
extern "C" const char *air_choose_pairing() {
    static std::string path;
    NSOpenPanel *panel=[NSOpenPanel openPanel];
    panel.message=@"Choose the pairing file exported by RustDesk Air Host on your Pro.";
    panel.canChooseDirectories=NO; panel.allowsMultipleSelection=NO;
    if ([panel runModal]!=NSModalResponseOK) return nullptr;
    path=panel.URL.fileSystemRepresentation;
    return path.c_str();
}
extern "C" void air_host_pairing(const char *path) { hostPairingPath=[NSString stringWithUTF8String:path]; }
extern "C" int air_choose_mode() {
    NSAlert *alert=[NSAlert new];
    alert.messageText=@"Choose streaming quality";
    alert.informativeText=@"Smooth + Sharp uses compressed video during movement, then restores exact pixels when it settles. Exact Lossless keeps every update lossless. Remote Spaces and individual finger forwarding are still experimental.";
    alert.showsSuppressionButton=YES;
    alert.suppressionButton.title=@"Match Air display and scaling (full screen)";
    alert.suppressionButton.state=NSControlStateValueOn;
    bool startupBefore=air_shell_startup_enabled()!=0;
    NSButton *remote=[NSButton checkboxWithTitle:@"Remote Mode: capture keyboard and trackpad" target:nil action:nil];
    remote.state=NSControlStateValueOn;
    NSButton *spaces=[NSButton checkboxWithTitle:@"Try three Remote Spaces (experimental)" target:nil action:nil];
    spaces.state=NSControlStateValueOff;
    NSButton *raw=[NSButton checkboxWithTitle:@"Try individual finger forwarding (experimental)" target:nil action:nil];
    raw.state=NSControlStateValueOff;
    int savedMode=0,savedRemote=1,savedSpaces=0,savedRaw=0,savedMatch=1;
    if(startupBefore && air_shell_get_startup_options(&savedMode,&savedRemote,&savedSpaces,&savedRaw,&savedMatch)) {
        remote.state=savedRemote?NSControlStateValueOn:NSControlStateValueOff;
        spaces.state=savedSpaces?NSControlStateValueOn:NSControlStateValueOff;
        raw.state=savedRaw?NSControlStateValueOn:NSControlStateValueOff;
        alert.suppressionButton.state=savedMatch?NSControlStateValueOn:NSControlStateValueOff;
    }
    NSButton *startup=[NSButton checkboxWithTitle:@"Open with these settings when I log in" target:nil action:nil];
    startup.state=startupBefore?NSControlStateValueOn:NSControlStateValueOff;
    NSStackView *options=[NSStackView stackViewWithViews:@[remote,spaces,raw,startup]];
    options.orientation=NSUserInterfaceLayoutOrientationVertical;options.alignment=NSLayoutAttributeLeading;
    options.spacing=8;options.frame=NSMakeRect(0,0,410,110);alert.accessoryView=options;
    [alert addButtonWithTitle:@"Smooth + Sharp"];
    [alert addButtonWithTitle:@"Exact Lossless"];
    [alert addButtonWithTitle:@"HEVC"];
    [alert addButtonWithTitle:@"H.264"];
    [alert addButtonWithTitle:@"Cancel"];
    auto response=[alert runModal];
    chosenDisplayMatch=alert.suppressionButton.state==NSControlStateValueOn;
    chosenRemoteMode=remote.state==NSControlStateValueOn;
    chosenRemoteSpaces=chosenRemoteMode && spaces.state==NSControlStateValueOn;
    chosenRawContacts=chosenRemoteMode && raw.state==NSControlStateValueOn;
    int mode=response==NSAlertFirstButtonReturn ? 4 : response==NSAlertSecondButtonReturn ? 1 : response==NSAlertThirdButtonReturn ? 3 : response==NSAlertThirdButtonReturn+1 ? 2 : 0;
    if(mode && (startupBefore || startup.state==NSControlStateValueOn)) {
        if(air_shell_set_startup_options(startup.state==NSControlStateValueOn,mode,chosenRemoteMode,
            chosenRemoteSpaces,chosenRawContacts,chosenDisplayMatch))air_show_error(air_last_error());
    }
    return mode;
}
extern "C" void air_show_error(const char *message) {
    [NSApplication sharedApplication];
    NSAlert *alert=[NSAlert new];
    alert.messageText=@"RustDesk Air";
    alert.informativeText=[NSString stringWithUTF8String:message ?: "An unknown error occurred."];
    [alert addButtonWithTitle:@"OK"]; [alert runModal];
}
extern "C" void air_app_run() { @autoreleasepool { if(!appStopRequested) [NSApp run]; } }
extern "C" void air_app_stop() { appStopRequested=true; dispatch_async(dispatch_get_main_queue(), ^{ if(NSApp.modalWindow) [NSApp abortModal]; air_overlay_shutdown(); [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO]; }); }
extern "C" void air_status(const char *text,int error) {
    NSString *message = [NSString stringWithUTF8String:text ?: ""];
    dispatch_async(dispatch_get_main_queue(), ^{
        window.title=message; hostStatus.stringValue=message;
        clientStatus.stringValue=message; clientStatusError=error!=0;
        if (!clientFrameSubmitted) clientStatus.hidden=NO;
    });
}
extern "C" void air_cursor(double x, double y) { (void)x;(void)y; }
extern "C" void air_surface_clear() {
    reconnectHoldGeneration++;
    air_exact_abort();
    {std::lock_guard<std::mutex> lock(surfaceMutex);desktop=nil;videoFrame.reset();}
    air_cursor_reset();
    requestDraw();
}
extern "C" void air_surface_hold_for_reconnect() {
    // Preserve the last Metal texture across a short authenticated reconnect.
    // A retained CVPixelBuffer keeps an IOSurface alive after decoder reset.
    uint64_t generation=++reconnectHoldGeneration;
    reconnectHolds++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        if (reconnectHoldGeneration.load()==generation) {
            reconnectHoldExpirations++;
            air_surface_clear();
        }
    });
}
extern "C" int air_exact_begin(uint32_t w, uint32_t h, int full, size_t uploadBytes) {
    @autoreleasepool {
        if (!device || !w || !h || w>8192 || h>8192 || uint64_t(w)*h>16777216) return fail("Invalid exact surface");
        if (!uploadBytes || uploadBytes>80*1024*1024) return fail("Invalid exact upload budget");
        if (patchCommand) return fail("An exact update is already open");
        if (!uploadStaging || uploadStaging.length<uploadBytes) {
            uploadStaging=[device newBufferWithLength:uploadBytes options:MTLResourceStorageModeShared];
            if (!uploadStaging) return fail("GPU upload allocation failed");
        }
        uploadOffset=0;
        { std::lock_guard<std::mutex> lock(surfaceMutex); pendingDesktop = desktop; }
        if (full) {
            auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
            desc.storageMode = MTLStorageModePrivate; desc.usage = MTLTextureUsageShaderRead;
            pendingDesktop = [device newTextureWithDescriptor:desc];
        }
        if (!pendingDesktop || pendingDesktop.width!=w || pendingDesktop.height!=h) return fail("Exact surface needs resync");
        patchCommand = [commandQueue commandBuffer]; patchBlit = [patchCommand blitCommandEncoder];
        if (!patchBlit) { patchCommand=nil; return fail("Cannot create GPU upload command"); }
        return 0;
    }
}
extern "C" int air_exact_patch(uint32_t x,uint32_t y,uint32_t w,uint32_t h,const uint8_t *bytes,size_t len) {
    @autoreleasepool {
        if (!patchBlit || !bytes || len!=uint64_t(w)*h*4 || !w || !h
            || uint64_t(x)+w>pendingDesktop.width || uint64_t(y)+h>pendingDesktop.height) return fail("Invalid exact patch");
        // Compressed/network pixels are uploaded once. Existing desktop pixels stay on the GPU.
        const size_t stride = (size_t(w)*4+255)&~size_t(255);
        if (uploadOffset+stride*h>uploadStaging.length) return fail("Exact upload exceeds staging budget");
        for (size_t row=0;row<h;row++) memcpy((uint8_t *)uploadStaging.contents+uploadOffset+row*stride,bytes+row*w*4,w*4);
        [patchBlit copyFromBuffer:uploadStaging sourceOffset:uploadOffset sourceBytesPerRow:stride sourceBytesPerImage:stride*h
            sourceSize:MTLSizeMake(w,h,1) toTexture:pendingDesktop destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x,y,0)];
        uploadOffset+=stride*h;
        patchBytes += len; patches++;
        return 0;
    }
}
extern "C" int air_exact_commit() {
    @autoreleasepool {
        if (!patchCommand) return fail("No exact update to commit");
        [patchBlit endEncoding]; patchBlit=nil;
        auto cmd = patchCommand; patchCommand=nil;
        [cmd commit]; [cmd waitUntilCompleted];
        if (cmd.status != MTLCommandBufferStatusCompleted) { pendingDesktop=nil; return fail("Exact GPU upload failed"); }
        { std::lock_guard<std::mutex> lock(surfaceMutex); desktop=pendingDesktop; videoFrame.reset(); }
        reconnectHoldGeneration++;
        exactCommits++; lastSurfaceKind=1;
        pendingDesktop=nil; requestDraw(); return 0;
    }
}
extern "C" void air_exact_abort() {
    if (patchBlit) [patchBlit endEncoding];
    patchBlit=nil; patchCommand=nil; pendingDesktop=nil;
}

static VTDecompressionSessionRef decoder;
static CMVideoFormatDescriptionRef decodeFormat;
static std::vector<uint8_t> parameterIdentity;
static std::atomic<int> decodeStatus(0);
static void outputFrame(void *,void *,OSStatus status,VTDecodeInfoFlags,CVImageBufferRef buffer,CMTime,CMTime) {
    if (status || !buffer) { decodeStatus=fail("Hardware decode failed",status); return; }
    OSType format=CVPixelBufferGetPixelFormatType(buffer);
    if ((format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        || !CVPixelBufferGetIOSurface(buffer)) { decodeStatus=fail("Decoder did not return an IOSurface NV12 buffer"); return; }
    auto frame=std::make_shared<PixelFrame>();
    frame->buffer=CVPixelBufferRetain(buffer);
    frame->serial=++nextVideoSerial;
    for (size_t plane=0;plane<2;plane++) {
        CVReturn result=CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,textureCache,buffer,nullptr,
            plane ? MTLPixelFormatRG8Unorm : MTLPixelFormatR8Unorm,
            CVPixelBufferGetWidthOfPlane(buffer,plane),CVPixelBufferGetHeightOfPlane(buffer,plane),plane,
            plane ? &frame->uv : &frame->y);
        if (result) { decodeStatus=fail("Cannot map decoded IOSurface to Metal",result); return; }
    }
    bool full=format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    auto matrix=CVBufferCopyAttachment(buffer,kCVImageBufferYCbCrMatrixKey,nullptr);
    double kr=.2126, kb=.0722;
    if (matrix && CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_601_4)) { kr=.299; kb=.114; }
    else if (matrix && CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_2020)) { kr=.2627; kb=.0593; }
    if (matrix) CFRelease(matrix);
    double kg=1-kr-kb, c=full ? 1 : 255.0/224.0;
    auto &p=frame->params;
    p.y[0]=full ? 0 : 16.0/255; p.y[1]=full ? 1 : 255.0/219; p.y[2]=128.0/255;
    p.r[0]=p.g[0]=p.b[0]=1;
    p.r[2]=2*(1-kr)*c; p.g[1]=-2*kb*(1-kb)/kg*c; p.g[2]=-2*kr*(1-kr)/kg*c; p.b[1]=2*(1-kb)*c;
    { std::lock_guard<std::mutex> lock(surfaceMutex); videoFrame=frame; desktop=nil; }
    reconnectHoldGeneration++;
    decoded++; lastSurfaceKind=2; requestDraw();
}
extern "C" int air_hardware_support(int codec) {
    if (codec!=1 && codec!=2) return 0;
    return VTIsHardwareDecodeSupported(codec==2 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264);
}
extern "C" void air_decoder_reset() {
    if (decoder) { VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder); CFRelease(decoder); decoder=nullptr; }
    if (decodeFormat) { CFRelease(decodeFormat); decodeFormat=nullptr; }
    parameterIdentity.clear();
}
extern "C" int air_decode(const uint8_t *bytes,size_t len) {
    @autoreleasepool {
        if (!bytes || len<24 || len>67108864 || memcmp(bytes,"RDV1",4)) return fail("Invalid hardware-video packet");
        size_t offset=4;
        auto read=[&](uint32_t &v)->bool {
            if (offset+4>len) return false;
            v=uint32_t(bytes[offset])|uint32_t(bytes[offset+1])<<8|uint32_t(bytes[offset+2])<<16|uint32_t(bytes[offset+3])<<24; offset+=4; return true;
        };
        uint32_t codec,w,h,count;
        if (!read(codec)||!read(w)||!read(h)||!read(count)||!w||!h||w>8192||h>8192||uint64_t(w)*h>16777216
            ||(codec!=1&&codec!=2)||count!=(codec==2?3u:2u)) return fail("Unsupported hardware-video configuration");
        const uint8_t *params[3]; size_t sizes[3];
        for (uint32_t i=0;i<count;i++) {
            uint32_t size;
            if (!read(size)||!size||size>65536||offset+size>len) return fail("Invalid video parameter set");
            params[i]=bytes+offset; sizes[i]=size; offset+=size;
        }
        if (offset>=len) return fail("Empty compressed frame");
        std::vector<uint8_t> identity(bytes,bytes+offset);
        if (identity!=parameterIdentity) {
            air_decoder_reset();
            OSStatus status=codec==2 ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,count,params,sizes,4,nullptr,&decodeFormat)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,count,params,sizes,4,&decodeFormat);
            if (status) return fail("Invalid compressed-video format",status);
            auto dimensions=CMVideoFormatDescriptionGetDimensions(decodeFormat);
            if (dimensions.width!=w || dimensions.height!=h) { air_decoder_reset(); return fail("Video dimensions do not match configuration"); }
            NSDictionary *spec=@{(__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:@YES};
            NSDictionary *attributes=@{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES,(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
            VTDecompressionOutputCallbackRecord callback={outputFrame,nullptr};
            status=VTDecompressionSessionCreate(kCFAllocatorDefault,decodeFormat,(__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)attributes,&callback,&decoder);
            if (status) { air_decoder_reset(); return fail("Hardware decoder unavailable",status); }
            CFTypeRef usingHardware=nullptr;
            status=VTSessionCopyProperty(decoder,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,kCFAllocatorDefault,&usingHardware);
            bool verified=!status&&usingHardware&&CFEqual(usingHardware,kCFBooleanTrue);
            if (usingHardware) CFRelease(usingHardware);
            if (!verified) { air_decoder_reset(); return fail("Hardware decoder unavailable: verification failed",status); }
            parameterIdentity=std::move(identity); hardwareSessions++;
        }
        // Only compressed bytes are copied; decoded pixels are never CPU-mapped.
        CMBlockBufferRef block=nullptr;
        size_t sampleSize=len-offset;
        OSStatus status=CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,nullptr,sampleSize,kCFAllocatorDefault,nullptr,0,sampleSize,0,&block);
        if (status) return fail("Compressed buffer allocation failed",status);
        status=CMBlockBufferReplaceDataBytes(bytes+offset,block,0,sampleSize);
        CMSampleBufferRef sample=nullptr;
        if (!status) status=CMSampleBufferCreateReady(kCFAllocatorDefault,block,decodeFormat,1,0,nullptr,1,&sampleSize,&sample);
        if (!status) { decodeStatus=0; status=VTDecompressionSessionDecodeFrame(decoder,sample,0,nullptr,nullptr); }
        if (sample) CFRelease(sample); CFRelease(block);
        if (status) return fail("Hardware decode failed",status);
        return decodeStatus;
    }
}
struct VideoPresentMetrics {
    size_t samples=0, unique=0, gapsOver50ms=0;
    uint64_t overwritten=0;
    double spanMs=0, fps=0, p50Ms=0, p95Ms=0, maxMs=0;
};
static VideoPresentMetrics videoPresentMetrics() {
    VideoPresentMetrics metrics;
    if (!presentTraceEnabled) return metrics;
    std::vector<VideoPresentation> events;
    {
        std::lock_guard<std::mutex> lock(presentTraceMutex);
        events=presentTrace;
        metrics.overwritten=presentTraceOverwritten;
    }
    metrics.samples=events.size();
    // Keep the first visible presentation of each decoded frame, then measure
    // the actual presentation timeline rather than draw requests or duplicates.
    std::sort(events.begin(),events.end(),[](const auto &a,const auto &b) {
        return a.serial==b.serial ? a.seconds<b.seconds : a.serial<b.serial;
    });
    events.erase(std::unique(events.begin(),events.end(),[](const auto &a,const auto &b) {
        return a.serial==b.serial;
    }),events.end());
    metrics.unique=events.size();
    if (events.size()<2) return metrics;
    std::sort(events.begin(),events.end(),[](const auto &a,const auto &b) { return a.seconds<b.seconds; });
    metrics.spanMs=(events.back().seconds-events.front().seconds)*1000;
    if (metrics.spanMs>0) metrics.fps=(events.size()-1)*1000.0/metrics.spanMs;
    std::vector<double> intervals;
    intervals.reserve(events.size()-1);
    for (size_t i=1;i<events.size();i++) {
        double ms=(events[i].seconds-events[i-1].seconds)*1000;
        intervals.push_back(ms);
        if (ms>50) metrics.gapsOver50ms++;
    }
    std::sort(intervals.begin(),intervals.end());
    metrics.p50Ms=intervals[(intervals.size()*50+99)/100-1];
    metrics.p95Ms=intervals[(intervals.size()*95+99)/100-1];
    metrics.maxMs=intervals.back();
    return metrics;
}
extern "C" const char *air_metrics() {
    static thread_local std::string result;
    auto videoPresent=videoPresentMetrics();
    uint64_t cursorUploads=0,cursorDraws=0,cursorMoves=0;
    air_cursor_metrics(&cursorUploads,&cursorDraws,&cursorMoves);
    uint64_t inputSent=0,inputGestures=0,inputRawContacts=0,inputPosted=0,inputEscapes=0;
    air_input_metrics(&inputSent,&inputGestures,&inputRawContacts,&inputPosted,&inputEscapes);
    uint64_t rawFramesSent=0,rawFramesPosted=0,rawStale=0,rawDuplicates=0;
    air_raw_metrics(&rawFramesSent,&rawFramesPosted,&rawStale,&rawDuplicates);
    result="{\"presented\":"+std::to_string(presented)+",\"decoded\":"+std::to_string(decoded)
        +",\"hardware_sessions\":"+std::to_string(hardwareSessions)+",\"patches\":"+std::to_string(patches)
        +",\"submitted\":"+std::to_string(submitted)+",\"dropped\":"+std::to_string(dropped)
        +",\"draw_requests\":"+std::to_string(drawRequests)+",\"draw_coalesced\":"+std::to_string(drawCoalesced)
        +",\"immediate_video_draw\":"+std::to_string(immediateVideoDraw ? 1 : 0)
        +",\"video_present_trace\":"+std::to_string(presentTraceEnabled ? 1 : 0)
        +",\"video_trace_samples\":"+std::to_string(videoPresent.samples)
        +",\"video_trace_overwritten\":"+std::to_string(videoPresent.overwritten)
        +",\"video_unique_presented\":"+std::to_string(videoPresent.unique)
        +",\"video_present_span_ms\":"+std::to_string(videoPresent.spanMs)
        +",\"video_present_fps\":"+std::to_string(videoPresent.fps)
        +",\"video_interval_p50_ms\":"+std::to_string(videoPresent.p50Ms)
        +",\"video_interval_p95_ms\":"+std::to_string(videoPresent.p95Ms)
        +",\"video_interval_max_ms\":"+std::to_string(videoPresent.maxMs)
        +",\"video_gaps_over_50ms\":"+std::to_string(videoPresent.gapsOver50ms)
        +",\"drawable_misses\":"+std::to_string(drawableMisses)
        +",\"pixel_identity_tests\":"+std::to_string(pixelIdentityTests)
        +",\"pixel_matched_presentations\":"+std::to_string(pixelMatchedPresentations)
        +",\"raster_mismatch_skips\":"+std::to_string(rasterMismatchSkips)
        +",\"reconnect_holds\":"+std::to_string(reconnectHolds)
        +",\"reconnect_hold_expirations\":"+std::to_string(reconnectHoldExpirations)
        +",\"source_width\":"+std::to_string(lastSourceWidth)+",\"source_height\":"+std::to_string(lastSourceHeight)
        +",\"drawable_width\":"+std::to_string(lastDrawableWidth)+",\"drawable_height\":"+std::to_string(lastDrawableHeight)
        +",\"received_video_bytes\":"+std::to_string(receivedVideoBytes)
        +",\"exact_commits\":"+std::to_string(exactCommits)+",\"last_surface_kind\":"+std::to_string(lastSurfaceKind)
        +",\"cursor_uploads\":"+std::to_string(cursorUploads)+",\"cursor_draws\":"+std::to_string(cursorDraws)+",\"local_cursor_moves\":"+std::to_string(cursorMoves)
        +",\"native_input_sent\":"+std::to_string(inputSent)+",\"native_gestures_sent\":"+std::to_string(inputGestures)
        +",\"raw_contacts_sent\":"+std::to_string(inputRawContacts)+",\"native_input_posted\":"+std::to_string(inputPosted)+",\"emergency_escapes\":"+std::to_string(inputEscapes)
        +",\"raw_v2_frames_sent\":"+std::to_string(rawFramesSent)+",\"raw_v2_frames_posted\":"+std::to_string(rawFramesPosted)
        +",\"raw_v2_stale_rejected\":"+std::to_string(rawStale)+",\"raw_contact_duplicates_suppressed\":"+std::to_string(rawDuplicates)
        +",\"uploaded_bgra_bytes\":"+std::to_string(patchBytes)+",\"decoded_cpu_pixel_bytes\":0}";
    return result.c_str();
}
extern "C" int air_native_selftest() {
    @autoreleasepool {
        if (initializeMetal()) return -1;
        std::vector<uint8_t> original(128*96*4), patch(11*7*4);
        for (size_t i=0;i<original.size();i++) original[i]=uint8_t(i*31+i/7);
        for (size_t i=0;i<patch.size();i++) patch[i]=uint8_t(i*17+9);
        if (air_exact_begin(128,96,1,original.size())||air_exact_patch(0,0,128,96,original.data(),original.size())||air_exact_commit()) return -1;
        if (air_exact_begin(128,96,0,256*7)||air_exact_patch(23,41,11,7,patch.data(),patch.size())||air_exact_commit()) return -1;
        for (size_t y=0;y<7;y++) memcpy(original.data()+((41+y)*128+23)*4,patch.data()+y*11*4,11*4);
        if (air_exact_begin(128,96,0,256*7)||air_exact_patch(0,0,11,7,patch.data(),patch.size())) return -1;
        if (!air_exact_patch(127,95,11,7,patch.data(),patch.size())) return fail("Out-of-bounds patch accepted");
        air_exact_abort();
        auto readback=[device newBufferWithLength:original.size() options:MTLResourceStorageModeShared];
        auto cmd=[commandQueue commandBuffer]; auto blit=[cmd blitCommandEncoder];
        [blit copyFromTexture:desktop sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,96,1)
            toBuffer:readback destinationOffset:0 destinationBytesPerRow:128*4 destinationBytesPerImage:original.size()];
        [blit endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
        if (cmd.status!=MTLCommandBufferStatusCompleted || memcmp(readback.contents,original.data(),original.size())) return fail("GPU exact reconstruction failed");
        auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:128 height:96 mipmapped:NO];
        desc.usage=MTLTextureUsageRenderTarget; desc.storageMode=MTLStorageModePrivate;
        auto target=[device newTextureWithDescriptor:desc];
        auto pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        cmd=[commandQueue commandBuffer]; auto render=[cmd renderCommandEncoderWithDescriptor:pass];
        Params identity={}; identity.fit[0]=1; identity.fit[1]=1;
        [render setRenderPipelineState:bgraPipeline]; [render setVertexBytes:&identity length:sizeof(identity) atIndex:0];
        [render setFragmentTexture:desktop atIndex:0];
        [render drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [render endEncoding];
        blit=[cmd blitCommandEncoder];
        [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,96,1)
            toBuffer:readback destinationOffset:0 destinationBytesPerRow:128*4 destinationBytesPerImage:original.size()];
        [blit endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
        if (cmd.status!=MTLCommandBufferStatusCompleted) return fail("One-to-one GPU draw failed");
        auto actual=(const uint8_t *)readback.contents;
        for (size_t i=0;i<original.size();i++) {
            uint8_t expected=i%4==3 ? 255 : original[i];
            if (actual[i]!=expected) return fail("One-to-one display changed a captured color");
        }
        pixelIdentityTests++;
        const uint8_t invalid[]={0,1,2,3};
        if (!air_decode(invalid,sizeof(invalid))) return fail("Invalid codec packet was accepted");
        uint8_t unsupported[24]={'R','D','V','1',3,0,0,0,1,0,0,0,1,0,0,0,2};
        if (!air_decode(unsupported,sizeof(unsupported)) || air_hardware_support(3)) return fail("Unsupported codec was accepted");
        if (air_exact_begin(128,96,0,256*7)||air_exact_patch(23,41,11,7,patch.data(),patch.size())||air_exact_commit()) return -1;
        return 0;
    }
}

extern "C" int air_transition_selftest() {
    @autoreleasepool {
        std::vector<uint8_t> expected(128*96*4);
        for (size_t i=0;i<expected.size();i++) expected[i]=uint8_t(i*13+i/11);
        for (int cycle=0;cycle<3;cycle++) {
            if (air_codec_selftest(2)) return -1;
            if (!videoFrame || desktop) return fail("Video surface was not selected");
            if (air_exact_begin(128,96,1,expected.size()) || air_exact_patch(0,0,128,96,expected.data(),expected.size()) || air_exact_commit()) return -1;
            if (videoFrame || !desktop) return fail("Exact surface was not restored after video");
            auto readback=[device newBufferWithLength:expected.size() options:MTLResourceStorageModeShared];
            auto cmd=[commandQueue commandBuffer]; auto blit=[cmd blitCommandEncoder];
            [blit copyFromTexture:desktop sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,96,1)
                toBuffer:readback destinationOffset:0 destinationBytesPerRow:128*4 destinationBytesPerImage:expected.size()];
            [blit endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
            if (cmd.status!=MTLCommandBufferStatusCompleted || memcmp(readback.contents,expected.data(),expected.size())) return fail("Exact pixels did not recover after video");
            pixelIdentityTests++;
        }
        return 0;
    }
}

static void startInputCapture(int seconds,NSString *destination,int attempts) {
    if(!NSApp.isActive && attempts>0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            startInputCapture(seconds,destination,attempts-1);
        });
        return;
    }
    if(air_input_capture_test(seconds,destination.fileSystemRepresentation)) {
        fprintf(stderr,"Native input capture error: %s\n",air_last_error());
        air_status(air_last_error(),1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{air_app_stop();});
        return;
    }
    air_status("Trackpad test: pinch and swipe here. No typing is recorded. Closes automatically.",0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds+3)*NSEC_PER_SEC),dispatch_get_main_queue(), ^{air_app_stop();});
}
extern "C" void air_input_capture_schedule(int seconds,const char *path) {
    NSString *destination=[NSString stringWithUTF8String:path];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        startInputCapture(seconds,destination,100);
    });
}
