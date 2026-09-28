// Link with src/air/display.mm. This changes only the built-in mode, then restores.
#import <AppKit/AppKit.h>
#include "../../src/air/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <vector>
#include <string>
struct Snapshot { CGDirectDisplayID id; CGRect bounds; size_t w,h,pw,ph; };
static std::vector<Snapshot> snapshot() {
    CGDirectDisplayID ids[32]; uint32_t n=0; std::vector<Snapshot> result;
    if(CGGetOnlineDisplayList(32,ids,&n))exit(2);
    for(uint32_t i=0;i<n;i++) {
        auto m=CGDisplayCopyDisplayMode(ids[i]); if(!m)exit(2);
        result.push_back({ids[i],CGDisplayBounds(ids[i]),CGDisplayModeGetWidth(m),CGDisplayModeGetHeight(m),CGDisplayModeGetPixelWidth(m),CGDisplayModeGetPixelHeight(m)});
        CGDisplayModeRelease(m);
    }
    return result;
}
extern "C" void air_set_error(const char *s) { fprintf(stderr,"%s\n",s); }
extern "C" uint32_t air_builtin_display() {
    CGDirectDisplayID ids[32]; uint32_t n=0;
    if(CGGetOnlineDisplayList(32,ids,&n))return 0;
    for(uint32_t i=0;i<n;i++)if(CGDisplayIsBuiltin(ids[i]))return ids[i]; return 0;
}
int main(int argc,char **argv) {
    if(argc!=6)return 2;
    const bool crash=std::string(argv[1])=="crash";
    AirDisplaySpec target={(uint32_t)atoi(argv[2]),(uint32_t)atoi(argv[3]),(uint32_t)atoi(argv[4]),(uint32_t)atoi(argv[5])};
    const auto before=snapshot();
    AirDisplaySpec invalid={0,640,2048,1280}; if(!air_display_match(&invalid))return 3;
    AirDisplaySpec missing={1023,637,2046,1274}; if(!air_display_match(&missing))return 4;
    if(air_display_match(&target)) { air_display_restore(); return 5; }
    AirDisplaySpec current={};
    if(air_display_current(&current) || memcmp(&target,&current,sizeof(target))) { air_display_restore(); return 6; }
    puts("MATCH_APPLIED"); fflush(stdout);
    if(crash) sleep(20);
    if(air_display_restore())return 7;
    const auto after=snapshot(); if(before.size()!=after.size())return 8;
    for(size_t i=0;i<before.size();i++) {
        auto a=before[i],b=after[i];
        if(a.id!=b.id || !CGRectEqualToRect(a.bounds,b.bounds) || a.w!=b.w || a.h!=b.h || a.pw!=b.pw || a.ph!=b.ph)return 9;
    }
    puts("ALL_MODES_AND_ORIGINS_RESTORED");
}
