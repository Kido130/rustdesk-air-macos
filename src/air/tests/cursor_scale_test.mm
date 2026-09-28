#include <cassert>
#include <cstdint>
extern "C" void air_set_error(const char *) {}
#include "../cursor.mm"

int main() {
    @autoreleasepool {
        assert(air_cursor_selftest()==0);
        uint8_t rgba[4]={255,255,255,255};
        assert(air_cursor_init(nullptr)==0);
        assert(air_cursor_shape(1,1,1,0,0,rgba,sizeof(rgba))==0);
        air_cursor_select(1);
        air_cursor_position(100,200,1);
        air_cursor_draw(nullptr,2048,1280,1,1,2);
        uint64_t uploads=1,draws=1,moves=1,id=1;
        uint32_t width=1,height=1,hotX=1,hotY=1;
        air_cursor_metrics(&uploads,&draws,&moves);
        air_cursor_probe_shape(&id,&width,&height,&hotX,&hotY);
        assert(uploads==0 && draws==0 && moves==0);
        assert(id==0 && width==0 && height==0 && hotX==0 && hotY==0);
        air_cursor_reset();
    }
    return 0;
}
