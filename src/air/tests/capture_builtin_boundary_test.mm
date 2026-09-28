#import <CoreGraphics/CoreGraphics.h>
#include "../native.h"
#include <cstdio>
#include <cstring>
#include <string>

static std::string lastError;
extern "C" void air_set_error(const char *message) { lastError=message ? message : ""; }
extern "C" int air_decode(const uint8_t *,size_t) { return -1; }
extern "C" void air_decoder_reset(void) {}

int main() {
    CGDirectDisplayID displays[32]={};
    uint32_t count=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return 2;
    CGDirectDisplayID builtin=air_builtin_display();
    if(!builtin || !CGDisplayIsBuiltin(builtin))return 3;
    unsigned externals=0;
    for(uint32_t index=0;index<count;index++) {
        CGDirectDisplayID display=displays[index];
        if(CGDisplayIsBuiltin(display))continue;
        externals++;
        lastError.clear();
        if(air_capture_start(display,0)!=nullptr)return 4;
        if(lastError!="Only the built-in Retina display may be captured")return 5;
    }
    if(externals!=2)return 6;
    lastError.clear();
    if(air_capture_start(0,0)!=nullptr)return 7;
    if(lastError!="Only the built-in Retina display may be captured")return 8;
    std::printf("capture boundary: built-in=%u externals_rejected=%u zero_rejected=1\n",
                builtin,externals);
    return 0;
}
