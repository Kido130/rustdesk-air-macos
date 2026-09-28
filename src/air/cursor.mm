#import <AppKit/AppKit.h>
#include "native.h"

// The Air renders only the remote desktop. AppKit owns the local pointer,
// including its position, hotspot, appearance and accessibility scaling.
extern "C" int air_cursor_init(void *device) { (void)device; return 0; }
extern "C" int air_cursor_shape(uint64_t id,uint32_t w,uint32_t h,uint32_t hx,uint32_t hy,const uint8_t *rgba,size_t len) {
    (void)id;(void)w;(void)h;(void)hx;(void)hy;(void)rgba;(void)len;return 0;
}
extern "C" void air_cursor_select(uint64_t id) { (void)id; }
extern "C" void air_cursor_position(double x,double y,int local) { (void)x;(void)y;(void)local; }
extern "C" void air_cursor_draw(void *encoder,double w,double h,double fitX,double fitY,double scale) {
    (void)encoder;(void)w;(void)h;(void)fitX;(void)fitY;(void)scale;
}
extern "C" void air_cursor_reset() {}
extern "C" void air_cursor_metrics(uint64_t *uploads,uint64_t *draws,uint64_t *moves) {
    if(uploads)*uploads=0;if(draws)*draws=0;if(moves)*moves=0;
}
extern "C" void air_cursor_probe_shape(uint64_t *id,uint32_t *w,uint32_t *h,uint32_t *hx,uint32_t *hy) {
    if(id)*id=0;if(w)*w=0;if(h)*h=0;if(hx)*hx=0;if(hy)*hy=0;
}
extern "C" int air_cursor_selftest() {
    if(!NSApp)[NSApplication sharedApplication];
    if(NSCursor.arrowCursor)return 0;
    air_set_error("macOS system cursor is unavailable");return -1;
}
