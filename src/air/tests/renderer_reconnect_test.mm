// Deterministic completion scheduling test, not GPU/video or Air evidence.
// Reuse the source-linked renderer fixture's non-renderer dependency stubs.
#define main hardware_fixture_main
#include "air_hardware_decoder_fixture.mm"
#undef main
#include <cassert>
#include <objc/runtime.h>

@interface ReconnectCommand : NSObject
@property(copy) void (^completion)(id<MTLCommandBuffer>);
@end
@implementation ReconnectCommand
- (id)renderCommandEncoderWithDescriptor:(id)descriptor { return self; }
- (void)endEncoding {}
- (void)presentDrawable:(id)drawable {}
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler { self.completion=handler; }
- (void)commit {}
@end
@interface ReconnectQueue : NSObject
@property(strong) NSMutableArray<ReconnectCommand *> *commands;
@end
@implementation ReconnectQueue
- (id)commandBuffer {
    ReconnectCommand *command=[ReconnectCommand new];
    [self.commands addObject:command];return command;
}
@end
@interface ReconnectView : NSObject
@property BOOL hasDrawable;
@end
@implementation ReconnectView
- (id)currentRenderPassDescriptor { return self.hasDrawable ? self : nil; }
- (id)currentDrawable { return self.hasDrawable ? self : nil; }
@end

int main() { @autoreleasepool {
    ReconnectQueue *queue=[ReconnectQueue new];queue.commands=NSMutableArray.array;
    commandQueue=(id<MTLCommandQueue>)queue;
    ReconnectView *fixture=[ReconnectView new];fixture.hasDrawable=YES;
    drawCredits=dispatch_semaphore_create(2);
    drawPending=false;drawQueued=false;
    auto draw=(void (*)(id,SEL,id))class_getMethodImplementation(AirView.class,@selector(drawInMTKView:));
    // Exercise the actual blank/disconnect branch with two delayed completions.
    draw(fixture,@selector(drawInMTKView:),fixture);
    draw(fixture,@selector(drawInMTKView:),fixture);
    assert(queue.commands.count==2 && !drawPending && !drawQueued);
    draw(fixture,@selector(drawInMTKView:),fixture);
    assert(drawPending && queue.commands.count==2);
    queue.commands[0].completion(nil);
    assert(!drawPending && drawQueued); // Next Exact frame now has a scheduled draw.
    queue.commands[1].completion(nil);
    assert(!drawPending && drawQueued);
    // Credits are balanced; no missing-drawable retry loop or phantom credit.
    assert(takeDrawCredit());assert(takeDrawCredit());assert(!takeDrawCredit());
    returnDrawCredit();returnDrawCredit();
    drawQueued=false;drawPending=false;fixture.hasDrawable=NO;
    draw(fixture,@selector(drawInMTKView:),fixture);
    assert(!drawPending && !drawQueued && queue.commands.count==2);
    assert(takeDrawCredit());assert(takeDrawCredit());assert(!takeDrawCredit());
    puts("blank completion reschedules pending draw; credits balanced; no drawable busy retry");
    // requestDraw has queued blocks; this process intentionally never runs AppKit.
    return 0;
} }
