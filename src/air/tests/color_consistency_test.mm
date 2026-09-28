// Actual hardware encode -> decode -> production Metal shader, without screen capture.
#define main decoder_fixture_main
#define air_codec_selftest unused_codec_selftest_stub
#include "air_hardware_decoder_fixture.mm"
#undef air_codec_selftest
#undef main
#include "../capture.mm"
extern "C" int air_cursor_probe_enabled(void) { return 0; }
extern "C" void air_cursor_probe_capture_drawable(void *,void *) {}

int main() { @autoreleasepool {
    if (initializeMetal()) return 1;
    bool passed=true;
    for (int codec=1;codec<=2;codec++) {
        Capture capture; capture.width=512; capture.height=256;
        NSDictionary *attrs=@{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault,capture.width,capture.height,
            kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&capture.held)) return 1;
        auto color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CVBufferSetAttachment(capture.held,kCVImageBufferCGColorSpaceKey,color,kCVAttachmentMode_ShouldPropagate);
        CGColorSpaceRelease(color);
        CVBufferSetAttachment(capture.held,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(capture.held,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_sRGB,kCVAttachmentMode_ShouldPropagate);
        if (CVPixelBufferLockBaseAddress(capture.held,0)) return 1;
        auto pixels=(uint8_t *)CVPixelBufferGetBaseAddress(capture.held);
        size_t stride=CVPixelBufferGetBytesPerRow(capture.held);
        for (uint32_t y=0;y<capture.height;y++) for (uint32_t x=0;x<capture.width;x++) {
            auto p=pixels+y*stride+x*4;
            p[0]=x*255/(capture.width-1);p[1]=y*255/(capture.height-1);p[2]=91;p[3]=255;
        }
        CVPixelBufferUnlockBaseAddress(capture.held,0);
        for (uint32_t bitrate : {1000000u,12000000u,40000000u,1000000u}) {
            if (air_capture_set_video_bitrate(&capture,bitrate)) return 1;
            for (int i=0;i<3;i++) {
                const uint8_t *packet=nullptr;size_t size=0;
                if (air_encode(&capture,codec,&packet,&size,i==0) || air_decode(packet,size)) {
                    fprintf(stderr,"codec %d: %s\n",codec,air_last_error());return 1;
                }
                VTDecompressionSessionWaitForAsynchronousFrames(decoder);
            }
            auto transfer=CMFormatDescriptionGetExtension(decodeFormat,kCMFormatDescriptionExtension_TransferFunction);
            auto primaries=CMFormatDescriptionGetExtension(decodeFormat,kCMFormatDescriptionExtension_ColorPrimaries);
            auto matrix=CMFormatDescriptionGetExtension(decodeFormat,kCMFormatDescriptionExtension_YCbCrMatrix);
            bool profile=transfer&&CFEqual(transfer,kCVImageBufferTransferFunction_sRGB)
                &&primaries&&CFEqual(primaries,kCVImageBufferColorPrimaries_ITU_R_709_2)
                &&matrix&&CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2);
            auto decodedTransfer=CVBufferCopyAttachment(videoFrame->buffer,kCVImageBufferTransferFunctionKey,nullptr);
            bool decodedProfile=decodedTransfer&&CFEqual(decodedTransfer,kCVImageBufferTransferFunction_sRGB);
            if (decodedTransfer) CFRelease(decodedTransfer);
            profile=profile&&decodedProfile;
            PixelError error={};
            bool pixelsMatch=compareDecodedPixels(capture.width,capture.height,&error);
            printf("codec=%d bitrate=%u srgb_profile=%d mean_error=%.3f max_error=%u\n",codec,bitrate,profile,error.mean,error.maximum);
            passed=passed&&profile&&pixelsMatch&&error.mean<2.0&&error.maximum<=10;
        }
        air_decoder_reset();
    }
    return passed ? 0 : 1;
} }
