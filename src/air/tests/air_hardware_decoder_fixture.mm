#include "../renderer.mm"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" int air_cursor_init(void *) { return 0; }
extern "C" void air_cursor_draw(void *, double, double, double, double, double) {}
extern "C" void air_cursor_position(double, double, int) {}
extern "C" void air_cursor_reset(void) {}
extern "C" void air_cursor_metrics(uint64_t *a, uint64_t *b, uint64_t *c) { *a = *b = *c = 0; }
extern "C" void air_overlay_attach(void *) {}
extern "C" int air_overlay_pointer(double, double) { return 0; }
extern "C" int air_overlay_visible(void) { return 0; }
extern "C" void air_overlay_shutdown(void) {}
extern "C" int air_input_grabbing(void) { return 0; }
extern "C" int air_input_capture_test(int, const char *) { return -1; }
extern "C" void air_input_metrics(uint64_t *a, uint64_t *b, uint64_t *c, uint64_t *d, uint64_t *e) {
    *a = *b = *c = *d = *e = 0;
}
extern "C" void air_raw_metrics(uint64_t *a, uint64_t *b, uint64_t *c, uint64_t *d) { *a = *b = *c = *d = 0; }
extern "C" int air_shell_startup_enabled(void) { return 0; }
extern "C" int air_shell_set_startup(int) { return -1; }
extern "C" int air_shell_set_startup_options(int,int,int,int,int,int) { return -1; }
extern "C" int air_shell_get_startup_options(int *,int *,int *,int *,int *) { return 0; }
extern "C" int air_codec_selftest(int) { return -1; }

static std::vector<uint8_t> readPacket(const std::string &path) {
    FILE *file = fopen(path.c_str(), "rb");
    if (!file) return {};
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return {}; }
    long length = ftell(file);
    if (length <= 0 || length > 1048576 || fseek(file, 0, SEEK_SET) != 0) { fclose(file); return {}; }
    std::vector<uint8_t> packet(static_cast<size_t>(length));
    bool complete = fread(packet.data(), 1, packet.size(), file) == packet.size();
    fclose(file);
    return complete ? packet : std::vector<uint8_t>{};
}

struct PixelError {
    double mean;
    unsigned maximum;
};

static bool parseDimension(const char *value, uint32_t *dimension) {
    errno = 0;
    char *end = nullptr;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno || !value[0] || !end || *end || parsed < 64 || parsed > 4096) return false;
    *dimension = static_cast<uint32_t>(parsed);
    return true;
}

static bool compareDecodedPixels(uint32_t width, uint32_t height, PixelError *error) {
    std::shared_ptr<PixelFrame> frame;
    { std::lock_guard<std::mutex> lock(surfaceMutex); frame = videoFrame; }
    if (!frame || !frame->buffer || CVPixelBufferGetWidth(frame->buffer) != width ||
        CVPixelBufferGetHeight(frame->buffer) != height || !frame->y || !frame->uv) return false;

    auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:descriptor];
    size_t imageBytes = size_t(width) * height * 4;
    id<MTLBuffer> readback = [device newBufferWithLength:imageBytes options:MTLResourceStorageModeShared];
    if (!target || !readback) return false;
    auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> command = [commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:pass];
    Params params = frame->params;
    params.fit[0] = params.fit[1] = 1;
    [render setRenderPipelineState:yuvPipeline];
    [render setVertexBytes:&params length:sizeof(params) atIndex:0];
    [render setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [render setFragmentTexture:CVMetalTextureGetTexture(frame->y) atIndex:0];
    [render setFragmentTexture:CVMetalTextureGetTexture(frame->uv) atIndex:1];
    [render drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [render endEncoding];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(width, height, 1) toBuffer:readback destinationOffset:0
        destinationBytesPerRow:width * 4 destinationBytesPerImage:imageBytes];
    [blit endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) return false;

    auto pixels = static_cast<const uint8_t *>(readback.contents);
    uint64_t total = 0;
    unsigned maximum = 0;
    uint64_t count = 0;
    for (unsigned y = 4; y < height - 4; y++) {
        for (unsigned x = 4; x < width - 4; x++) {
            const uint8_t *pixel = pixels + (size_t(y) * width + x) * 4;
            const int expected[3] = {static_cast<int>(x * 255 / (width - 1)),
                                     static_cast<int>(y * 255 / (height - 1)), 91};
            for (int channel = 0; channel < 3; channel++) {
                unsigned difference = static_cast<unsigned>(std::abs(int(pixel[channel]) - expected[channel]));
                total += difference;
                maximum = std::max(maximum, difference);
                count++;
            }
        }
    }
    error->mean = double(total) / count;
    error->maximum = maximum;
    return error->mean <= 8.0 && maximum <= 45;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        uint32_t width = 0, height = 0;
        if (argc != 4 || argv[1][0] != '/' || !parseDimension(argv[2], &width) ||
            !parseDimension(argv[3], &height) || width % 64 || height % 2 ||
            uint64_t(width) * height > 10000000) {
            fprintf(stderr, "Usage: decoder-fixture /absolute/existing/packet-directory WIDTH HEIGHT (width multiple of 64, even height, at most 10 MP)\n");
            return 2;
        }
        if (initializeMetal()) { fprintf(stderr, "%s\n", air_last_error()); return 1; }
        for (int codec = 1; codec <= 2; codec++) {
            if (!air_hardware_support(codec)) {
                fprintf(stderr, "Hardware decoder support absent for codec %d\n", codec);
                return 1;
            }
            for (int index = 0; index < 5; index++) {
                std::string path = std::string(argv[1]) + (codec == 1 ? "/h264-" : "/hevc-")
                    + std::to_string(index) + ".rdv";
                std::vector<uint8_t> packet = readPacket(path);
                if (packet.empty() || air_decode(packet.data(), packet.size())) {
                    fprintf(stderr, "Decode failed for %s: %s\n", path.c_str(), air_last_error());
                    return 1;
                }
                if (decoder) VTDecompressionSessionWaitForAsynchronousFrames(decoder);
                if (decoded.load() != static_cast<uint64_t>((codec - 1) * 5 + index + 1) ||
                    hardwareSessions.load() != static_cast<uint64_t>(codec)) {
                    fprintf(stderr, "Decoded frame or verified hardware session count did not advance\n");
                    return 1;
                }
                PixelError error = {};
                if (!compareDecodedPixels(width, height, &error)) {
                    fprintf(stderr, "GPU pixel check failed: mean=%.3f max=%u\n", error.mean, error.maximum);
                    return 1;
                }
                printf("{\"codec\":\"%s\",\"frame\":%d,\"decoded\":%llu,\"hardware_sessions\":%llu,\"pixel_mean_error\":%.3f,\"pixel_max_error\":%u}\n",
                       codec == 1 ? "h264" : "hevc", index,
                       static_cast<unsigned long long>(decoded.load()),
                       static_cast<unsigned long long>(hardwareSessions.load()), error.mean, error.maximum);
            }
            air_decoder_reset();
        }
        return 0;
    }
}
