#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main() { @autoreleasepool {
    CGRect ax=CGRectMake(-1799,110,320,198);
    CGRect content=CGRectMake(0,25,1147,720);
    NSString *window=(__bridge NSString *)kAXWindowRole;
    NSString *standard=(__bridge NSString *)kAXStandardWindowSubrole;
    assert(journalableAXFrame(@"com.apple.SystemProfiler",window,standard,
        ax,ax,true,false,content,false));
    assert(journalableAXFrame(@"com.google.Chrome",window,@"AXUnknown",
        ax,ax,true,false,content,true));
    assert(!journalableAXFrame(@"com.google.Chrome",window,@"AXUnknown",
        ax,CGRectOffset(ax,3,0),true,false,content,true));
    assert(!journalableAXFrame(@"com.google.Chrome",window,@"AXUnknown",
        ax,ax,true,false,content,false));
    assert(!journalableAXFrame(@"com.google.Chrome",window,@"AXUnknown",
        ax,ax,true,true,content,true));
    assert(!journalableAXFrame(@"com.example.other",window,@"AXUnknown",
        ax,ax,true,false,content,true));
    assert(!journalableAXFrame(@"com.google.Chrome",window,@"AXUnknown",
        ax,ax,false,false,content,true));
    assert(!journalableAXFrame(@"com.google.Chrome",window,@"AXUnknown",
        ax,ax,true,false,CGRectMake(0,0,300,180),true));
    NSString *layout=@"AXLayoutArea",*floating=@"AXFloatingWindow";
    NSString *afterEffects=@"com.adobe.AfterEffects.application";
    assert(journalableAXFrame(afterEffects,layout,floating,ax,ax,true,true,content,true));
    assert(!journalableAXFrame(@"com.example.other",layout,floating,ax,ax,true,true,content,true));
    assert(!journalableAXFrame(afterEffects,window,floating,ax,ax,true,true,content,true));
    assert(!journalableAXFrame(afterEffects,layout,standard,ax,ax,true,true,content,true));
    assert(!journalableAXFrame(afterEffects,layout,floating,ax,ax,false,true,content,true));
    assert(!journalableAXFrame(afterEffects,layout,floating,ax,ax,true,false,content,true));
    assert(!journalableAXFrame(afterEffects,layout,floating,ax,CGRectOffset(ax,3,0),true,true,content,true));
    assert(!journalableAXFrame(afterEffects,layout,floating,ax,ax,true,true,content,false));
    puts("position-only AX policy passed");
    return 0;
} }
