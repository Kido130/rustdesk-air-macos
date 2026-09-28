#include "../capture.mm"

static std::string testError;
extern "C" void air_set_error(const char *message) { testError=message ?: ""; }
extern "C" int air_decode(const uint8_t *,size_t) { return -1; }
extern "C" void air_decoder_reset(void) {}

static_assert(sizeof(AirCaptureProfile)==9*sizeof(uint64_t),"Host profile ABI changed");

static bool encodeFixture(int codec,bool profile) {
    Capture capture;
    capture.width=256; capture.height=192; capture.profile=profile;
    NSDictionary *attributes=@{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault,capture.width,capture.height,
        kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&capture.held)) return false;
    const uint8_t *packet=nullptr; size_t length=0;
    for (int frame=0;frame<5;frame++) {
        if (air_encode(&capture,codec,&packet,&length,frame==0) || !packet || !length) return false;
    }
    auto calls=profile ? 5u : 0u;
    return capture.encodeSubmitCalls==calls && capture.encodeCompleteWaitCalls==calls &&
        capture.encodeSubmitMaxUs<=capture.encodeSubmitTotalUs &&
        capture.encodeCompleteWaitMaxUs<=capture.encodeCompleteWaitTotalUs;
}

int main() {
    @autoreleasepool {
        for (int codec=1;codec<=2;codec++) {
            if (!encodeFixture(codec,false) || !encodeFixture(codec,true)) {
                fprintf(stderr,"Encoder timing fixture failed (codec %d): %s\n",codec,testError.c_str());
                return 1;
            }
        }
        puts("hardware encoder stage timing: profiled and unprofiled H.264/HEVC passed");
        return 0;
    }
}
