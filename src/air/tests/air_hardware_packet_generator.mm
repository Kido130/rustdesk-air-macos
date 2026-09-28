#include "../capture.mm"

#include <fcntl.h>
#include <cerrno>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>

static std::string testError;
extern "C" void air_set_error(const char *message) { testError = message ?: ""; }
extern "C" int air_decode(const uint8_t *, size_t) { return -1; }
extern "C" void air_decoder_reset(void) {}

static bool parseDimension(const char *value, uint32_t *dimension) {
    errno = 0;
    char *end = nullptr;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno || !value[0] || !end || *end || parsed < 64 || parsed > 4096) return false;
    *dimension = static_cast<uint32_t>(parsed);
    return true;
}

static bool savePacket(const std::string &path, const uint8_t *bytes, size_t length) {
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    bool ok = fchmod(fd, 0600) == 0;
    size_t sent = 0;
    while (ok && sent < length) {
        ssize_t count = write(fd, bytes + sent, length - sent);
        if (count <= 0) ok = false;
        else sent += static_cast<size_t>(count);
    }
    ok = close(fd) == 0 && ok;
    if (!ok) unlink(path.c_str());
    return ok;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        uint32_t width = 0, height = 0;
        if (argc != 4 || argv[1][0] != '/' || !parseDimension(argv[2], &width) ||
            !parseDimension(argv[3], &height) || width % 64 || height % 2 ||
            uint64_t(width) * height > 10000000) {
            fprintf(stderr, "Usage: packet-generator /absolute/existing/output-directory WIDTH HEIGHT (width multiple of 64, even height, at most 10 MP)\n");
            return 2;
        }
        if (air_set_video_bitrate(25000000)) return 1;
        for (int codec = 1; codec <= 2; codec++) {
            Capture capture;
            capture.width = width;
            capture.height = height;
            NSDictionary *attributes = @{
                (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            };
            if (CVPixelBufferCreate(kCFAllocatorDefault, capture.width, capture.height,
                                    kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes,
                                    &capture.held)) {
                fprintf(stderr, "Synthetic pixel buffer allocation failed\n");
                return 1;
            }
            if (CVPixelBufferLockBaseAddress(capture.held, 0)) return 1;
            auto *pixels = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(capture.held));
            size_t stride = CVPixelBufferGetBytesPerRow(capture.held);
            for (uint32_t y = 0; y < capture.height; y++) {
                for (uint32_t x = 0; x < capture.width; x++) {
                    uint8_t *pixel = pixels + y * stride + x * 4;
                    pixel[0] = static_cast<uint8_t>(x * 255 / (width - 1));
                    pixel[1] = static_cast<uint8_t>(y * 255 / (height - 1));
                    pixel[2] = 91;
                    pixel[3] = 255;
                }
            }
            CVPixelBufferUnlockBaseAddress(capture.held, 0);
            for (int frame = 0; frame < 5; frame++) {
                const uint8_t *packet = nullptr;
                size_t length = 0;
                if (air_encode(&capture, codec, &packet, &length, frame == 0)) {
                    fprintf(stderr, "Hardware encode failed: %s\n", testError.c_str());
                    return 1;
                }
                CFTypeRef hardware = nullptr;
                OSStatus status = VTSessionCopyProperty(capture.encoder,
                    kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                    kCFAllocatorDefault, &hardware);
                bool verified = !status && hardware && CFEqual(hardware, kCFBooleanTrue);
                if (hardware) CFRelease(hardware);
                if (!verified) {
                    fprintf(stderr, "Encoder did not verify hardware use\n");
                    return 1;
                }
                std::string path = std::string(argv[1]) + (codec == 1 ? "/h264-" : "/hevc-")
                    + std::to_string(frame) + ".rdv";
                if (!savePacket(path, packet, length)) {
                    fprintf(stderr, "Could not save exclusive packet\n");
                    return 1;
                }
                printf("{\"codec\":\"%s\",\"frame\":%d,\"bytes\":%zu,\"hardware_encoder\":true}\n",
                       codec == 1 ? "h264" : "hevc", frame, length);
            }
        }
        return 0;
    }
}
