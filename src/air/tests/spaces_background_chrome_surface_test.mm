#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }

int main() { @autoreleasepool {
    CGRect display=CGRectMake(-3840,0,1920,1080);
    CGRect owner=CGRectMake(-3840,0,1920,1080);
    CGRect root=CGRectMake(-3840,0,1920,124);
    CGRect middle=CGRectMake(-3840,41,1920,47);
    CGRect leaf=CGRectMake(-3840,0,1920,41);
    assert(backgroundChromeFourSurfaceGeometry(display,owner,root,middle,leaf));
    assert(backgroundChromeFourSurfaceGeometry(display,owner,
        CGRectMake(-3840,30,1920,124),CGRectMake(-3840,-17,1920,47),
        CGRectMake(-3840,-11,1920,41)));
    assert(!backgroundChromeFourSurfaceGeometry(display,owner,
        CGRectMake(-3840,0,1920,1080),middle,leaf));
    assert(!backgroundChromeFourSurfaceGeometry(display,
        CGRectMake(-3840,0,1920,900),root,middle,leaf));
    assert(!backgroundChromeFourSurfaceGeometry(display,owner,root,
        CGRectMake(-3840,41,1920,300),leaf));
    assert(!backgroundChromeFourSurfaceGeometry(display,owner,root,middle,
        CGRectMake(-3800,0,1920,41)));
    assert(!backgroundChromeFourSurfaceGeometry(display,owner,root,middle,
        CGRectMake(-3840,400,1920,41)));
    assert(!backgroundChromeFourSurfaceGeometry(display,owner,
        CGRectMake(-3840,80,1920,124),middle,leaf));
    assert(!backgroundChromeFourSurfaceGeometry(display,owner,root,
        CGRectMake(-3840,-100,1920,47),leaf));
    puts("background Chrome full-screen geometry: observed cohort and shared/ambiguous shapes passed");
    return 0;
}}
