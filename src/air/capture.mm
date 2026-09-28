#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#include "native.h"
#include <mutex>
#include <condition_variable>
#include <vector>
#include <string>
#include <atomic>
#include <chrono>
#include <algorithm>
#include <cstdlib>
#include <cstring>

// Keep encoder experiments independently selectable for matched live A/B runs.
// Neither setting changes the encoded packet format or permits software encode.
static bool encoderTune(const char *name) {
    const char *value=std::getenv("RUSTDESK_AIR_ENCODER_TUNE");
    if (!value) return false;
    return !std::strcmp(value,name);
}

static std::atomic<uint32_t> videoBitrate(12000000);
extern "C" int air_set_video_bitrate(uint32_t bits_per_second) {
    if (bits_per_second<1000000 || bits_per_second>100000000) {
        air_set_error("Video bitrate must be 1–100 Mbps"); return -1;
    }
    videoBitrate=bits_per_second; return 0;
}

struct Capture;
@interface AirCaptureOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic,assign) Capture *owner;
@end
struct Capture {
    SCStream *stream;
    AirCaptureOutput *output;
    dispatch_queue_t queue;
    dispatch_queue_t encodeQueue=nullptr;
    std::mutex mutex;
    std::condition_variable ready;
    std::mutex encodeMutex;
    std::condition_variable encodeReady;
    bool encodePending=false, encodeDone=false;
    std::atomic<bool> encodePublished{false};
    CVPixelBufferRef latest=nullptr, held=nullptr;
    bool stopped=false, locked=false;
    std::string error;
    VTCompressionSessionRef encoder=nullptr;
    uint32_t targetBitrate=videoBitrate.load();
    int codec=0;
    uint32_t width=0,height=0;
    int64_t frameNumber=0;
    std::vector<uint8_t> encoded;
    OSStatus encodeStatus=0;
    bool profile=false;
    std::atomic<uint64_t> completeCallbacks{0}, latestOverwrites{0}, nextSuccesses{0};
    uint64_t encodeSubmitCalls=0, encodeSubmitTotalUs=0, encodeSubmitMaxUs=0;
    uint64_t encodeCompleteWaitCalls=0, encodeCompleteWaitTotalUs=0, encodeCompleteWaitMaxUs=0;
    ~Capture() {
        if (encodeQueue) dispatch_sync(encodeQueue,^{});
        if (encoder) { VTCompressionSessionCompleteFrames(encoder,kCMTimeInvalid); VTCompressionSessionInvalidate(encoder); CFRelease(encoder); }
        if (latest) CFRelease(latest);
        if (held) { if (locked) CVPixelBufferUnlockBaseAddress(held,kCVPixelBufferLock_ReadOnly); CFRelease(held); }
    }
};
@implementation AirCaptureOutput
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    auto attachments=(__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample,false);
    NSNumber *frameStatus=attachments.firstObject[SCStreamFrameInfoStatus];
    if (!frameStatus || frameStatus.integerValue!=SCFrameStatusComplete) return;
    auto buffer=CMSampleBufferGetImageBuffer(sample);
    if (!buffer) return;
    Capture *c=self.owner; if (!c) return;
    std::lock_guard<std::mutex> lock(c->mutex);
    if (c->stopped) return;
    if (c->profile) c->completeCallbacks.fetch_add(1,std::memory_order_relaxed);
    if (c->latest) {
        if (c->profile) c->latestOverwrites.fetch_add(1,std::memory_order_relaxed);
        CFRelease(c->latest);
    }
    c->latest=CVPixelBufferRetain(buffer);
    c->ready.notify_one();
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    Capture *c=self.owner; if (!c) return;
    std::lock_guard<std::mutex> lock(c->mutex);
    c->error=error.localizedDescription.UTF8String; c->stopped=true; c->ready.notify_one();
}
@end
static int captureFail(const std::string &s) { air_set_error(s.c_str()); return -1; }
extern "C" uint32_t air_capture_video_bitrate(void *value) {
    auto c=(Capture *)value;
    return c ? c->targetBitrate : 0;
}
extern "C" int air_capture_set_video_bitrate(void *value,uint32_t bits_per_second) {
    auto c=(Capture *)value;
    if (!c || bits_per_second<1000000 || bits_per_second>100000000)
        return captureFail("Invalid capture video bitrate");
    if (c->encoder && c->targetBitrate!=bits_per_second) {
        auto status=VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_AverageBitRate,
            (__bridge CFNumberRef)@(bits_per_second));
        if (status) return captureFail("Cannot update hardware video bitrate: "+std::to_string(status));
    }
    c->targetBitrate=bits_per_second;
    return 0;
}
extern "C" uint32_t air_builtin_display() {
    CGDirectDisplayID displays[32]; uint32_t count=0;
    if (CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess) return 0;
    for (uint32_t i=0;i<count;i++) if (CGDisplayIsBuiltin(displays[i])) return displays[i];
    return 0;
}
extern "C" void *air_capture_start(uint32_t display,int profile) {
    @autoreleasepool {
        if (!display || !CGDisplayIsBuiltin(display)) { captureFail("Only the built-in Retina display may be captured"); return nullptr; }
        if (!CGPreflightScreenCaptureAccess()) { captureFail("Allow Screen Recording for RustDesk Air Host in System Settings"); return nullptr; }
        __block SCShareableContent *content=nil;
        __block NSError *error=nil;
        auto semaphore=dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *value,NSError *failure) {
            content=value; error=failure; dispatch_semaphore_signal(semaphore);
        }];
        if (dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) { captureFail("Screen capture discovery timed out"); return nullptr; }
        if (error) { captureFail(error.localizedDescription.UTF8String); return nullptr; }
        SCDisplay *screen=nil;
        for (SCDisplay *d in content.displays) if (d.displayID==display) { screen=d; break; }
        if (!screen) { captureFail("Built-in display is unavailable"); return nullptr; }
        auto c=new Capture();
        c->profile=profile==1;
        auto mode=CGDisplayCopyDisplayMode(display);
        if (!mode) { delete c; captureFail("Cannot determine Retina capture raster"); return nullptr; }
        c->width=(uint32_t)CGDisplayModeGetPixelWidth(mode); c->height=(uint32_t)CGDisplayModeGetPixelHeight(mode);
        CGDisplayModeRelease(mode);
        auto config=[SCStreamConfiguration new];
        config.width=c->width; config.height=c->height;
        config.pixelFormat=kCVPixelFormatType_32BGRA; config.colorSpaceName=kCGColorSpaceSRGB;
        config.showsCursor=NO;
        // A deeper SCK queue can avoid starving capture while the host waits for
        // VideoToolbox. Latest-frame selection still discards stale samples.
        const char *queue5=std::getenv("RUSTDESK_AIR_CAPTURE_QUEUE5");
        config.queueDepth=(queue5 && !std::strcmp(queue5,"1")) ? 5 : 3;
        const char *maxRate=std::getenv("RUSTDESK_AIR_CAPTURE_MAX_RATE");
        config.minimumFrameInterval=(maxRate && !std::strcmp(maxRate,"1"))
            ? kCMTimeZero : CMTimeMake(1,60);
        auto filter=[[SCContentFilter alloc] initWithDisplay:screen excludingWindows:@[]];
        c->output=[AirCaptureOutput new]; c->output.owner=c;
        c->queue=dispatch_queue_create("rustdesk.air.capture",DISPATCH_QUEUE_SERIAL);
        c->stream=[[SCStream alloc] initWithFilter:filter configuration:config delegate:c->output];
        if (![c->stream addStreamOutput:c->output type:SCStreamOutputTypeScreen sampleHandlerQueue:c->queue error:&error]) {
            captureFail(error.localizedDescription.UTF8String); c->output.owner=nullptr; delete c; return nullptr;
        }
        auto started=dispatch_semaphore_create(0);
        [c->stream startCaptureWithCompletionHandler:^(NSError *failure) { error=failure; dispatch_semaphore_signal(started); }];
        dispatch_semaphore_wait(started,DISPATCH_TIME_FOREVER);
        if (error) { captureFail(error.localizedDescription.UTF8String); c->output.owner=nullptr; delete c; return nullptr; }
        return c;
    }
}
extern "C" int air_capture_next(void *value,const uint8_t **data,size_t *len,uint32_t *width,uint32_t *height,uint32_t *stride,uint32_t timeout) {
    auto c=(Capture *)value;
    if (!c || !data || !len || !width || !height || !stride) return captureFail("Invalid capture arguments");
    air_capture_release_frame(c);
    std::unique_lock<std::mutex> lock(c->mutex);
    c->ready.wait_for(lock,std::chrono::milliseconds(timeout),[&]{ return c->latest || c->stopped || c->encodePublished.load(std::memory_order_acquire); });
    if (c->stopped) return captureFail(c->error.empty()?"Capture stopped":c->error);
    if (!c->latest) return 0;
    c->held=c->latest; c->latest=nullptr; lock.unlock();
    auto status=CVPixelBufferLockBaseAddress(c->held,kCVPixelBufferLock_ReadOnly);
    if (status) return captureFail("Cannot access host capture buffer");
    c->locked=true;
    *data=(const uint8_t *)CVPixelBufferGetBaseAddress(c->held);
    *width=(uint32_t)CVPixelBufferGetWidth(c->held); *height=(uint32_t)CVPixelBufferGetHeight(c->held);
    *stride=(uint32_t)CVPixelBufferGetBytesPerRow(c->held); *len=size_t(*stride)*(*height);
    if (c->profile) c->nextSuccesses.fetch_add(1,std::memory_order_relaxed);
    return 1;
}
extern "C" void air_capture_release_frame(void *value) {
    auto c=(Capture *)value; if (!c || !c->held) return;
    if (c->locked) CVPixelBufferUnlockBaseAddress(c->held,kCVPixelBufferLock_ReadOnly);
    c->locked=false; CFRelease(c->held); c->held=nullptr;
}
extern "C" void air_capture_stop(void *value) {
    @autoreleasepool {
        auto c=(Capture *)value; if (!c) return;
        { std::lock_guard<std::mutex> lock(c->mutex); c->stopped=true; }
        auto stopped=dispatch_semaphore_create(0);
        [c->stream stopCaptureWithCompletionHandler:^(NSError *) { dispatch_semaphore_signal(stopped); }];
        dispatch_semaphore_wait(stopped,DISPATCH_TIME_FOREVER);
        dispatch_sync(c->queue,^{ c->output.owner=nullptr; });
        delete c;
    }
}
extern "C" void air_capture_stop_profiled(void *value,AirCaptureProfile *profile) {
    @autoreleasepool {
        auto c=(Capture *)value; if (!c) return;
        { std::lock_guard<std::mutex> lock(c->mutex); c->stopped=true; }
        auto stopped=dispatch_semaphore_create(0);
        [c->stream stopCaptureWithCompletionHandler:^(NSError *) { dispatch_semaphore_signal(stopped); }];
        dispatch_semaphore_wait(stopped,DISPATCH_TIME_FOREVER);
        dispatch_sync(c->queue,^{ c->output.owner=nullptr; });
        if (profile) {
            profile->complete_callbacks=c->completeCallbacks.load(std::memory_order_relaxed);
            profile->latest_overwrites=c->latestOverwrites.load(std::memory_order_relaxed);
            profile->next_successes=c->nextSuccesses.load(std::memory_order_relaxed);
            profile->encode_submit={c->encodeSubmitCalls,c->encodeSubmitTotalUs,c->encodeSubmitMaxUs};
            profile->encode_complete_wait={c->encodeCompleteWaitCalls,c->encodeCompleteWaitTotalUs,c->encodeCompleteWaitMaxUs};
        }
        delete c;
    }
}
static void append32(std::vector<uint8_t> &v,uint32_t n) {
    for (int i=0;i<4;i++) v.push_back(uint8_t(n>>(i*8)));
}
static void recordEncodeStage(std::chrono::steady_clock::time_point started,uint64_t &calls,uint64_t &total,uint64_t &maximum) {
    auto elapsed=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count();
    uint64_t us=elapsed>0 ? uint64_t(elapsed) : 0;
    calls++; total+=us; maximum=std::max(maximum,us);
}
static void encodedFrame(void *context,void *,OSStatus status,VTEncodeInfoFlags,CMSampleBufferRef sample) {
    auto c=(Capture *)context; c->encodeStatus=status;
    if (status || !sample || !CMSampleBufferDataIsReady(sample)) { c->encodeStatus=status?:-1; return; }
    auto format=CMSampleBufferGetFormatDescription(sample);
    auto &out=c->encoded; out.clear(); out.insert(out.end(),{'R','D','V','1'});
    append32(out,c->codec); append32(out,c->width); append32(out,c->height);
    uint32_t count=c->codec==2?3:2; append32(out,count);
    for (uint32_t i=0;i<count;i++) {
        const uint8_t *bytes=nullptr; size_t len=0;
        status=c->codec==2 ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,i,&bytes,&len,nullptr,nullptr)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,i,&bytes,&len,nullptr,nullptr);
        if (status || len>65536) { c->encodeStatus=status?:-1; return; }
        append32(out,(uint32_t)len); out.insert(out.end(),bytes,bytes+len);
    }
    auto block=CMSampleBufferGetDataBuffer(sample);
    auto length=CMBlockBufferGetDataLength(block);
    if (!length || length>64*1024*1024) { c->encodeStatus=-1; return; }
    auto offset=out.size(); out.resize(offset+length);
    c->encodeStatus=CMBlockBufferCopyDataBytes(block,0,length,out.data()+offset);
}
static void encodedFrameAsync(void *context,void *source,OSStatus status,VTEncodeInfoFlags flags,CMSampleBufferRef sample) {
    auto c=(Capture *)context;
    std::lock_guard<std::mutex> lock(c->encodeMutex);
    encodedFrame(context,source,status,flags,sample);
}
static int createEncoder(Capture *c,int codec,VTCompressionOutputCallback callback) {
    c->codec=codec;
    bool rate=encoderTune("rate"), speed=encoderTune("speed");
    NSDictionary *spec=rate ? @{
        (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES,
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl:@YES
    } : @{
        (__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES
    };
    OSStatus status=VTCompressionSessionCreate(kCFAllocatorDefault,c->width,c->height,
        codec==2?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)spec,nullptr,nullptr,callback,c,&c->encoder);
    if (status) return captureFail("Hardware encoder unavailable: "+std::to_string(status));
    VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_RealTime,kCFBooleanTrue);
    VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse);
    // Match the 1/60 source timestamps. This is an encoder hint, not a frame
    // limiter, and does not enable the speed-over-quality experiment.
    status=VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_ExpectedFrameRate,(__bridge CFNumberRef)@60);
    if (status) return captureFail("Cannot configure 60 fps hardware encoder: "+std::to_string(status));
    if (speed) {
        status=VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,kCFBooleanTrue);
        if (status) return captureFail("Hardware encoder speed option unavailable: "+std::to_string(status));
    }
    status=VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_AverageBitRate,(__bridge CFNumberRef)@(c->targetBitrate));
    if (status) return captureFail("Cannot configure hardware video bitrate: "+std::to_string(status));
    VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_MaxKeyFrameInterval,(__bridge CFNumberRef)@60);
    VTSessionSetProperty(c->encoder,kVTCompressionPropertyKey_ProfileLevel,
        codec==2 ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel);
    // Exact pixels and the Metal presentation layer are sRGB. Encoding them
    // with a 709 transfer curve shifts brightness whenever adaptive mode switches.
    const CFStringRef colorKeys[]={kVTCompressionPropertyKey_ColorPrimaries,
        kVTCompressionPropertyKey_TransferFunction,kVTCompressionPropertyKey_YCbCrMatrix};
    const CFStringRef colorValues[]={kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunction_sRGB,kCVImageBufferYCbCrMatrix_ITU_R_709_2};
    for (int i=0;i<3;i++) {
        status=VTSessionSetProperty(c->encoder,colorKeys[i],colorValues[i]);
        if (status) {
            VTCompressionSessionInvalidate(c->encoder); CFRelease(c->encoder); c->encoder=nullptr;
            return captureFail("Cannot configure matching sRGB hardware video: "+std::to_string(status));
        }
    }
    status=VTCompressionSessionPrepareToEncodeFrames(c->encoder);
    if (status) return captureFail("Cannot prepare hardware encoder: "+std::to_string(status));
    return 0;
}
extern "C" int air_encode_submit(void *value,int codec,int forceKey) {
    auto c=(Capture *)value;
    if (!c || !c->held || (codec!=1 && codec!=2)) return captureFail("Invalid asynchronous hardware encode request");
    if (c->encoder && c->codec!=codec) return captureFail("Encoder codec changed without reset");
    if (!c->encoder) {
        if (createEncoder(c,codec,encodedFrameAsync)) return -1;
        c->encodeQueue=dispatch_queue_create("rustdesk.air.encode-complete",DISPATCH_QUEUE_SERIAL);
    }
    {
        std::lock_guard<std::mutex> lock(c->encodeMutex);
        if (c->encodePending) return captureFail("Asynchronous hardware encoder already has a frame");
        c->encoded.clear(); c->encodeStatus=0;
        c->encodePending=true; c->encodeDone=false;
        c->encodePublished.store(false,std::memory_order_release);
    }
    NSDictionary *options=forceKey ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame:@YES} : nil;
    std::chrono::steady_clock::time_point stageStarted;
    if (c->profile) stageStarted=std::chrono::steady_clock::now();
    auto status=VTCompressionSessionEncodeFrame(c->encoder,c->held,CMTimeMake(c->frameNumber++,60),CMTimeMake(1,60),(__bridge CFDictionaryRef)options,nullptr,nullptr);
    if (c->profile) recordEncodeStage(stageStarted,c->encodeSubmitCalls,c->encodeSubmitTotalUs,c->encodeSubmitMaxUs);
    if (status) {
        std::lock_guard<std::mutex> lock(c->encodeMutex);
        c->encodePending=false;
        return captureFail("Hardware encoder submission failed: "+std::to_string(status));
    }
    dispatch_async(c->encodeQueue,^{
        auto completed=VTCompressionSessionCompleteFrames(c->encoder,kCMTimeInvalid);
        {
            std::lock_guard<std::mutex> lock(c->mutex);
            c->encodePublished.store(true,std::memory_order_release);
        }
        {
            std::lock_guard<std::mutex> lock(c->encodeMutex);
            if (completed && !c->encodeStatus) c->encodeStatus=completed;
            c->encodeDone=true;
        }
        c->encodeReady.notify_one();
        c->ready.notify_one();
    });
    return 0;
}
extern "C" int air_encode_finish(void *value,const uint8_t **data,size_t *len) {
    auto c=(Capture *)value;
    if (!c || !data || !len) return captureFail("Invalid asynchronous hardware encode completion");
    std::chrono::steady_clock::time_point stageStarted;
    if (c->profile) stageStarted=std::chrono::steady_clock::now();
    std::unique_lock<std::mutex> lock(c->encodeMutex);
    if (!c->encodePending) return captureFail("No asynchronous hardware frame is pending");
    c->encodeReady.wait(lock,[&]{ return c->encodeDone; });
    c->encodePending=false;
    c->encodePublished.store(false,std::memory_order_release);
    if (c->profile) recordEncodeStage(stageStarted,c->encodeCompleteWaitCalls,c->encodeCompleteWaitTotalUs,c->encodeCompleteWaitMaxUs);
    if (c->encodeStatus || c->encoded.empty()) return captureFail("Hardware encoder failed: "+std::to_string(c->encodeStatus?:-1));
    *data=c->encoded.data(); *len=c->encoded.size(); return 0;
}
extern "C" int air_encode(void *value,int codec,const uint8_t **data,size_t *len,int forceKey) {
    auto c=(Capture *)value;
    if (!c || !c->held || (codec!=1 && codec!=2)) return captureFail("Invalid hardware encode request");
    if (c->encoder && c->codec!=codec) return captureFail("Encoder codec changed without reset");
    if (!c->encoder) {
        if (createEncoder(c,codec,encodedFrame)) return -1;
    }
    c->encoded.clear(); c->encodeStatus=0;
    NSDictionary *options=forceKey ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame:@YES} : nil;
    std::chrono::steady_clock::time_point stageStarted;
    if (c->profile) stageStarted=std::chrono::steady_clock::now();
    auto status=VTCompressionSessionEncodeFrame(c->encoder,c->held,CMTimeMake(c->frameNumber++,60),CMTimeMake(1,60),(__bridge CFDictionaryRef)options,nullptr,nullptr);
    if (c->profile) recordEncodeStage(stageStarted,c->encodeSubmitCalls,c->encodeSubmitTotalUs,c->encodeSubmitMaxUs);
    if (!status) {
        if (c->profile) stageStarted=std::chrono::steady_clock::now();
        status=VTCompressionSessionCompleteFrames(c->encoder,kCMTimeInvalid);
        if (c->profile) recordEncodeStage(stageStarted,c->encodeCompleteWaitCalls,c->encodeCompleteWaitTotalUs,c->encodeCompleteWaitMaxUs);
    }
    if (status || c->encodeStatus || c->encoded.empty()) return captureFail("Hardware encoder failed: "+std::to_string(status?:c->encodeStatus));
    *data=c->encoded.data(); *len=c->encoded.size(); return 0;
}
extern "C" int air_codec_selftest(int codec) {
    @autoreleasepool {
        Capture c; c.width=256; c.height=192;
        NSDictionary *attributes=@{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES,(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        auto status=CVPixelBufferCreate(kCFAllocatorDefault,c.width,c.height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&c.held);
        if (status) return captureFail("Test pixel buffer allocation failed");
        CVPixelBufferLockBaseAddress(c.held,0);
        auto p=(uint8_t *)CVPixelBufferGetBaseAddress(c.held); auto stride=CVPixelBufferGetBytesPerRow(c.held);
        for (uint32_t y=0;y<c.height;y++) for (uint32_t x=0;x<c.width;x++) {
            p[y*stride+x*4]=uint8_t(x); p[y*stride+x*4+1]=uint8_t(y); p[y*stride+x*4+2]=91; p[y*stride+x*4+3]=255;
        }
        CVPixelBufferUnlockBaseAddress(c.held,0);
        const uint8_t *bytes; size_t len;
        for (int frame=0;frame<5;frame++) {
            if (air_encode(&c,codec,&bytes,&len,frame==0) || air_decode(bytes,len)) return -1;
        }
        air_decoder_reset(); return 0;
    }
}
extern "C" int air_codec_async_selftest(int codec) {
    @autoreleasepool {
        Capture c; c.width=256; c.height=192;
        NSDictionary *attributes=@{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES,(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        for (int frame=0;frame<8;frame++) {
            auto status=CVPixelBufferCreate(kCFAllocatorDefault,c.width,c.height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&c.held);
            if (status) return captureFail("Test pixel buffer allocation failed");
            CVPixelBufferLockBaseAddress(c.held,0);
            auto p=(uint8_t *)CVPixelBufferGetBaseAddress(c.held); auto stride=CVPixelBufferGetBytesPerRow(c.held);
            for (uint32_t y=0;y<c.height;y++) for (uint32_t x=0;x<c.width;x++) {
                p[y*stride+x*4]=uint8_t(x+frame); p[y*stride+x*4+1]=uint8_t(y);
                p[y*stride+x*4+2]=91; p[y*stride+x*4+3]=255;
            }
            CVPixelBufferUnlockBaseAddress(c.held,0);
            if (air_encode_submit(&c,codec,frame==0)) return -1;
            CFRelease(c.held); c.held=nullptr;
            const uint8_t *captureBytes=nullptr; size_t captureLen=0;
            uint32_t width=0,height=0,captureStride=0;
            if (air_capture_next(&c,&captureBytes,&captureLen,&width,&height,&captureStride,1000)
                || !c.encodePublished.load(std::memory_order_acquire)) return captureFail("Encoder completion did not wake capture");
            const uint8_t *bytes=nullptr; size_t len=0;
            if (air_encode_finish(&c,&bytes,&len) || air_decode(bytes,len)) return -1;
        }
        air_decoder_reset(); return 0;
    }
}
