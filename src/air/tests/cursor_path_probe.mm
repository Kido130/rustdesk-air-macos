#include "../native.h"
#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>

static std::atomic<bool> configured(false),scheduled(false),started(false);
static std::atomic<uint64_t> generation(0);
static CGPoint originalPointer={};
static uint64_t baselineUploads=0,baselineDraws=0,baselineMoves=0;
static unsigned posted=0,observed=0,captured=0;
static std::atomic<int> requestedCapture(-1);
static std::atomic<int> captureState[6];
static unsigned capturedWidth[6]={},capturedHeight[6]={};
static unsigned firstRaster=0;
static CFAbsoluteTime startedAt=0;

static bool foreground() {
    NSWindow *window=NSApp.keyWindow;
    return NSThread.isMainThread && NSApp.isActive && !air_is_host_bundle()
        && air_input_grabbing() && !air_overlay_visible()
        && window && window==NSApp.mainWindow && window.isVisible
        && (window.occlusionState & NSWindowOcclusionStateVisible)
        && [window.contentView isKindOfClass:MTKView.class];
}
static bool safe(uint64_t token) {
    CGEventFlags flags=CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    constexpr CGEventFlags modifiers=kCGEventFlagMaskCommand|kCGEventFlagMaskAlternate
        |kCGEventFlagMaskControl|kCGEventFlagMaskShift|kCGEventFlagMaskSecondaryFn;
    return token==generation.load() && configured.load() && foreground()
        && CGPreflightPostEventAccess() && !(flags&modifiers)
        && !CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft)
        && !CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonRight);
}
static bool pointer(CGPoint *point) {
    CGEventRef event=CGEventCreate(nullptr);
    if(!event)return false;
    *point=CGEventGetLocation(event);CFRelease(event);
    return std::isfinite(point->x) && std::isfinite(point->y);
}
static bool post(CGPoint point) {
    CGEventRef event=CGEventCreateMouseEvent(nullptr,kCGEventMouseMoved,point,kCGMouseButtonLeft);
    if(!event)return false;
    CGEventPost(kCGHIDEventTap,event);CFRelease(event);posted++;
    return true;
}
static NSDictionary *metrics() {
    const char *raw=air_metrics();
    NSData *data=raw ? [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    id json=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}
static bool target(unsigned index,CGPoint *point,double *sourceX,double *sourceY) {
    if(index>=6 || !foreground())return false;
    NSWindow *window=NSApp.keyWindow;
    MTKView *view=(MTKView *)window.contentView;
    NSDictionary *report=metrics();
    unsigned width=[report[@"source_width"] unsignedIntValue],height=[report[@"source_height"] unsignedIntValue];
    if(!((width==2048 && height==1280)||(width==2560 && height==1600))
        || fabs(view.drawableSize.width-width)>1 || fabs(view.drawableSize.height-height)>1
        || view.bounds.size.width<=0 || view.bounds.size.height<=0)return false;
    const double offsets[]={-219,23,286};
    *sourceX=width/2.0+offsets[index%3]*2.0;
    *sourceY=height/2.0;
    double scale=view.bounds.size.width/view.drawableSize.width;
    NSPoint inside=NSMakePoint(*sourceX*scale,view.bounds.size.height-*sourceY*scale);
    if(inside.x<20 || inside.y<20 || inside.x>view.bounds.size.width-20
        || inside.y>view.bounds.size.height-20)return false;
    NSPoint base=[view convertPoint:inside toView:nil];
    NSPoint screenPoint=[window convertPointToScreen:base];
    NSScreen *screen=window.screen;
    CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect quartz=CGDisplayBounds(display);
    if(!display || CGRectIsEmpty(quartz))return false;
    *point=CGPointMake(quartz.origin.x+screenPoint.x-screen.frame.origin.x,
        quartz.origin.y+NSMaxY(screen.frame)-screenPoint.y);
    return std::isfinite(point->x) && std::isfinite(point->y)
        && CGRectContainsPoint(CGRectInset(quartz,10,10),*point);
}
static bool saveOwnDrawable(id<MTLBuffer> buffer,unsigned width,unsigned height,unsigned rowBytes,
                            unsigned index) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
        pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width*4 bitsPerPixel:32];
    if(!bitmap || !bitmap.bitmapData)return false;
    const uint8_t *source=(const uint8_t *)buffer.contents;
    uint8_t *destination=bitmap.bitmapData;
    for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++) {
        const uint8_t *from=source+y*rowBytes+x*4;
        uint8_t *to=destination+y*bitmap.bytesPerRow+x*4;
        to[0]=from[2];to[1]=from[1];to[2]=from[0];to[3]=from[3];
    }
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if(!png || !png.length)return false;
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"air-cursor-path-%d-%u.png",getpid(),index]];
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0)return false;
    const uint8_t *bytes=(const uint8_t *)png.bytes;size_t remaining=png.length;
    bool okay=true;
    while(remaining) {
        ssize_t count=write(fd,bytes,remaining);
        if(count<=0){okay=false;break;}
        bytes+=count;remaining-=(size_t)count;
    }
    if(close(fd)!=0)okay=false;
    if(!okay){unlink(path.fileSystemRepresentation);return false;}
    capturedWidth[index]=width;capturedHeight[index]=height;
    captured++;
    fprintf(stderr,"air_cursor_probe_png=%s scope=own_metal_drawable index=%u width=%u height=%u\n",
        path.fileSystemRepresentation,index,width,height);
    return true;
}
extern "C" int air_cursor_probe_enabled(void) {return configured.load() ? 1 : 0;}
extern "C" void air_cursor_probe_capture_drawable(void *command,void *rawTexture) {
    int index=requestedCapture.exchange(-1);
    if(index<0)return;
    id<MTLCommandBuffer> cmd=(__bridge id<MTLCommandBuffer>)command;
    id<MTLTexture> texture=(__bridge id<MTLTexture>)rawTexture;
    unsigned width=(unsigned)texture.width,height=(unsigned)texture.height;
    unsigned rowBytes=(width*4+255)&~255u;
    if(!configured || index>=6 || width<400 || height<250 || width>4096 || height>2400
        || texture.pixelFormat!=MTLPixelFormatBGRA8Unorm || !cmd) {
        if(index>=0 && index<6)captureState[index]=-1;
        return;
    }
    id<MTLBuffer> buffer=[texture.device newBufferWithLength:(size_t)rowBytes*height
        options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit=buffer ? [cmd blitCommandEncoder] : nil;
    if(!blit){captureState[index]=-1;return;}
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0
        sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1)
        toBuffer:buffer destinationOffset:0 destinationBytesPerRow:rowBytes
        destinationBytesPerImage:(size_t)rowBytes*height];
    [blit endEncoding];
    uint64_t token=generation.load();
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(dispatch_get_main_queue(),^{
            if(token!=generation.load())return;
            captureState[index]=completed.status==MTLCommandBufferStatusCompleted
                && saveOwnDrawable(buffer,width,height,rowBytes,index) ? 2 : -1;
        });
    }];
}
static void finish(uint64_t token,const char *reason) {
    if(token!=generation.load())return;
    bool restorePosted=safe(token) && post(originalPointer);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(token!=generation.load())return;
        CGPoint current={};
        bool restored=restorePosted && pointer(&current)
            && hypot(current.x-originalPointer.x,current.y-originalPointer.y)<=3;
        uint64_t uploads=0,draws=0,moves=0;
        air_cursor_metrics(&uploads,&draws,&moves);
        fprintf(stderr,"air_cursor_probe_end reason=%s posted=%u observed=%u png=%u restored=%d "
            "upload_delta=%llu draw_delta=%llu local_move_delta=%llu scope=own_metal_drawable\n",
            reason,posted,observed,captured,restored,
            (unsigned long long)(uploads-baselineUploads),
            (unsigned long long)(draws-baselineDraws),
            (unsigned long long)(moves-baselineMoves));
        ++generation;scheduled=false;
    });
}
static void step(uint64_t token,unsigned index) {
    if(token!=generation.load())return;
    if(index==6){finish(token,"complete");return;}
    unsigned width=[metrics()[@"source_width"] unsignedIntValue];
    if(index==3 && width==firstRaster) {
        if(CFAbsoluteTimeGetCurrent()-startedAt>32){finish(token,"second_raster_timeout");return;}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            step(token,index);
        });
        return;
    }
    if((index>0 && index<3 && width!=firstRaster)
        || (index>3 && width==firstRaster)) {finish(token,"raster_changed_mid_phase");return;}
    CGPoint point={};double sourceX=0,sourceY=0;
    uint64_t before=0,draws=0,uploads=0;
    air_cursor_metrics(&uploads,&draws,&before);
    if(!safe(token) || !target(index,&point,&sourceX,&sourceY) || !post(point)) {
        finish(token,"preflight_or_post_failed");return;
    }
    if(index==0)firstRaster=width;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(token!=generation.load())return;
        CGPoint current={};uint64_t after=0,drawn=0,shapes=0;
        air_cursor_metrics(&shapes,&drawn,&after);
        bool moved=pointer(&current) && hypot(current.x-point.x,current.y-point.y)<=3;
        bool gpuCursorIdle=after==before && drawn==draws && shapes==uploads;
        if(moved && gpuCursorIdle)observed++;
        if(!safe(token) || !moved || !gpuCursorIdle){finish(token,"native_pointer_not_observed");return;}
        captureState[index]=1;requestedCapture=index;air_request_draw();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            if(token!=generation.load())return;
            bool png=captureState[index]==2;
            uint64_t finalUploads=0,finalDraws=0,finalMoves=0;
            air_cursor_metrics(&finalUploads,&finalDraws,&finalMoves);
            uint64_t shapeID=0;uint32_t shapeW=0,shapeH=0,hotX=0,hotY=0;
            air_cursor_probe_shape(&shapeID,&shapeW,&shapeH,&hotX,&hotY);
            fprintf(stderr,"air_cursor_probe_hover=%u phase=%u raster=%ux%u source_x=%.0f "
                "source_y=%.0f posted_x=%.1f posted_y=%.1f pointer_match=%d gpu_cursor_idle=%d "
                "draw_delta=%llu upload_delta=%llu shape_id=%llu shape=%ux%u hotspot=%u,%u png=%d\n",
                index,index/3,width,width==2048?1280:1600,sourceX,sourceY,point.x,point.y,
                moved,gpuCursorIdle,(unsigned long long)(finalDraws-draws),
                (unsigned long long)(finalUploads-uploads),(unsigned long long)shapeID,
                shapeW,shapeH,hotX,hotY,png);
            bool nativeOnly=finalUploads==uploads && finalDraws==draws && finalMoves==after
                && shapeID==0 && shapeW==0 && shapeH==0 && hotX==0 && hotY==0;
            bool matchedRaster=capturedWidth[index]==width
                && capturedHeight[index]==(width==2048?1280:1600);
            if(!safe(token) || !png || !nativeOnly || !matchedRaster){
                finish(token,"native_pointer_or_capture_failed");return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                step(token,index+1);
            });
        });
    });
}
extern "C" int air_cursor_probe_configure(int enabled) {
    if((enabled!=0 && enabled!=1) || scheduled || started) {
        air_set_error("Cursor path probe must be configured once before a session");return -1;
    }
    configured=enabled!=0;return 0;
}
extern "C" void air_cursor_probe_ready(int ready) {
    if(!ready) {
        uint64_t old=generation.load();
        bool restorePosted=scheduled && started && NSThread.isMainThread
            && safe(old) && post(originalPointer);
        ++generation;
        if(scheduled)fprintf(stderr,"air_cursor_probe_end reason=lost_grab generation=%llu "
            "restore_posted=%d restored=0\n",(unsigned long long)old,restorePosted);
        scheduled=false;return;
    }
    if(!configured || started || scheduled.exchange(true))return;
    uint64_t token=++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(token!=generation.load())return;
        if(!safe(token) || !pointer(&originalPointer)) {
            fprintf(stderr,"air_cursor_probe_end reason=preflight restored=0\n");scheduled=false;return;
        }
        started=true;posted=observed=captured=0;firstRaster=0;
        startedAt=CFAbsoluteTimeGetCurrent();
        for(auto &status:captureState)status=0;
        for(unsigned i=0;i<6;i++)capturedWidth[i]=capturedHeight[i]=0;
        air_cursor_metrics(&baselineUploads,&baselineDraws,&baselineMoves);
        fprintf(stderr,"air_cursor_probe_start=1 duration_limit_seconds=45\n");
        step(token,0);
    });
}
extern "C" void air_cursor_probe_shutdown() {
    uint64_t token=generation.load();
    if(scheduled && started && NSThread.isMainThread) {
        bool restorePosted=safe(token) && post(originalPointer);
        fprintf(stderr,"air_cursor_probe_end reason=shutdown posted=%u observed=%u png=%u "
            "restore_posted=%d restored=0 scope=own_metal_drawable\n",
            posted,observed,captured,restorePosted);
    }
    ++generation;
    scheduled=false;configured=false;
}
