#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main() { @autoreleasepool {
    const CGRect cursor=CGRectMake(-1255,127,64,64);
    NSString *const bundle=@"com.apple.TextInputUI.xpc.CursorUIViewService";
    NSString *const owner=@"CursorUIViewService";
    auto recognized=[&](NSString *candidateBundle,NSString *candidateOwner,
                        NSString *title,int layer,double alpha,CGRect frame,
                        bool appleExecutable,bool stable,bool completeAX,bool hasAXWindows) {
        return cursorUIOverlayMetadata(candidateBundle,candidateOwner,title,layer,alpha,
            frame,appleExecutable,stable,completeAX,hasAXWindows);
    };
    assert(recognized(bundle,owner,@"",0,1,cursor,
        true,true,true,false));
    // A sticky user window, a same-named process outside Apple's sealed
    // executable, and an interactive AX window must all remain journaled.
    assert(!recognized(@"com.example.user",owner,@"",0,1,cursor,
        true,true,true,false));
    assert(!recognized(bundle,owner,@"",0,1,cursor,
        false,true,true,false));
    assert(!recognized(bundle,owner,@"",0,1,cursor,
        true,true,true,true));
    assert(!recognized(bundle,owner,@"",0,1,cursor,
        true,false,true,false));
    assert(!recognized(bundle,owner,@"",0,1,cursor,
        true,true,false,false));
    assert(!recognized(bundle,@"OtherService",@"",0,1,cursor,
        true,true,true,false));
    assert(!recognized(bundle,owner,@"Document",0,1,cursor,
        true,true,true,false));
    assert(!recognized(bundle,owner,@"",1,1,cursor,
        true,true,true,false));
    assert(!recognized(bundle,owner,@"",0,0.9,cursor,
        true,true,true,false));
    assert(!recognized(bundle,owner,@"",0,1,
        CGRectMake(0,0,640,480),true,true,true,false));
    assert(!appleCursorServiceExecutable(getpid()));
    NSDictionary *fake=@{(id)kCGWindowNumber:@101,(id)kCGWindowOwnerPID:@(getpid()),
        (id)kCGWindowLayer:@0,(id)kCGWindowOwnerName:@"CursorUIViewService",
        (id)kCGWindowName:@"",(id)kCGWindowAlpha:@1,
        (id)kCGWindowBounds:CFBridgingRelease(CGRectCreateDictionaryRepresentation(cursor))};
    DormantAXCache cache;
    assert(!verifiedCursorUIOverlay(fake,101,getpid(),cache));
    puts("PASS: only the exact Apple cursor service surface is eligible; sticky user windows remain guarded");
} }
