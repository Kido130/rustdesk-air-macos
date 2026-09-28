#import <AppKit/AppKit.h>
#include <sys/stat.h>

static NSString *fixtureHome;
static NSString *lastError;
static NSString *airTestHomeDirectory(void) { return fixtureHome; }
extern "C" void air_set_error(const char *message) {
    lastError = message ? [NSString stringWithUTF8String:message] : nil;
}

// Redirect only this translation unit's call; the process HOME and real
// LaunchAgents directory are never changed or opened by the fixture.
#define NSHomeDirectory airTestHomeDirectory
#include "../shell.mm"
#undef NSHomeDirectory

static int failures = 0;
static void check(BOOL condition, NSString *label) {
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL %s\n", label.UTF8String);
    } else {
        printf("PASS %s\n", label.UTF8String);
    }
}

int main(void) {
    @autoreleasepool {
        NSString *actualHome = NSHomeDirectory();
        NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"air-startup-fixture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        fixtureHome = [base copy];
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        if (![files createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "Cannot create isolated fixture: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        @try {
            NSString *path = [base stringByAppendingPathComponent:@"Library/LaunchAgents/dev.rustdesk.air.client.plist"];
            check(![base isEqualToString:actualHome] && ![path hasPrefix:[actualHome stringByAppendingString:@"/Library/LaunchAgents/"]], @"isolated home");
            check(air_shell_startup_enabled() == 0, @"initially disabled");
            int mode=99,remote=99,spaces=99,raw=99,match=99;
            check(air_shell_get_startup_options(&mode,&remote,&spaces,&raw,&match)==0 && mode==99 && remote==99, @"absent startup leaves chooser defaults untouched");
            check(air_shell_set_startup(1) == 0, @"create startup item");
            NSDictionary *item = [NSDictionary dictionaryWithContentsOfFile:path];
            NSDictionary *attributes = [files attributesOfItemAtPath:path error:&error];
            check(item != nil && [item[@"Label"] isEqualToString:@"dev.rustdesk.air.client"], @"own label");
            check([item[@"ProgramArguments"] isEqualToArray:@[NSBundle.mainBundle.executablePath, @"--mode", @"adaptive", @"--reconnect"]], @"current executable and reconnect arguments");
            check([item[@"RunAtLoad"] boolValue] && ![item[@"KeepAlive"][@"SuccessfulExit"] boolValue]
                && [item[@"ThrottleInterval"] integerValue]==15, @"runs at login and retries unexpected exits");
            check([attributes[NSFilePosixPermissions] unsignedShortValue] == 0600, @"plist permissions 0600");
            check(air_shell_startup_enabled() == 1, @"created item reported enabled");
            check(air_shell_get_startup_options(&mode,&remote,&spaces,&raw,&match)==1
                && mode==4 && remote==1 && spaces==1 && raw==1 && match==1, @"read default selected settings");

            check(air_shell_set_startup_options(1,1,0,0,0,0)==0, @"save selected exact quality without remote input");
            item=[NSDictionary dictionaryWithContentsOfFile:path];
            check([item[@"ProgramArguments"] isEqualToArray:@[NSBundle.mainBundle.executablePath,@"--mode",@"exact",@"--reconnect",@"--no-remote-mode",@"--no-match-display",@"--windowed"]], @"startup preserves exact, remote off, windowed");
            check(air_shell_get_startup_options(&mode,&remote,&spaces,&raw,&match)==1
                && mode==1 && remote==0 && spaces==0 && raw==0 && match==0, @"read remote-off startup choices");
            check(air_shell_set_startup_options(1,3,1,0,0,0)==0, @"refresh selected HEVC startup");
            item=[NSDictionary dictionaryWithContentsOfFile:path];
            check([item[@"ProgramArguments"] isEqualToArray:@[NSBundle.mainBundle.executablePath,@"--mode",@"hevc",@"--reconnect",@"--no-remote-spaces",@"--no-raw-contacts",@"--no-match-display",@"--windowed"]], @"startup preserves remote Spaces and raw opt-outs");
            check(air_shell_get_startup_options(&mode,&remote,&spaces,&raw,&match)==1
                && mode==3 && remote==1 && spaces==0 && raw==0 && match==0, @"read remote opt-outs from owned startup");
            NSMutableDictionary *invalidArguments=[item mutableCopy];
            invalidArguments[@"ProgramArguments"]=[item[@"ProgramArguments"] arrayByAddingObject:@"--unknown"];
            check([invalidArguments writeToFile:path atomically:YES], @"write malformed own startup fixture");
            mode=remote=spaces=raw=match=99;
            check(air_shell_get_startup_options(&mode,&remote,&spaces,&raw,&match)==0
                && mode==99 && remote==99 && spaces==99 && raw==99 && match==99, @"malformed own startup does not set chooser state");
            check(air_shell_set_startup_options(1,3,1,0,0,0)==0, @"restore valid selected startup");
            item=[NSDictionary dictionaryWithContentsOfFile:path];
            lastError=nil;
            check(air_shell_set_startup_options(1,0,1,1,1,1)==-1 && lastError.length>0, @"invalid quality refused");
            check([[NSDictionary dictionaryWithContentsOfFile:path][@"ProgramArguments"] isEqualToArray:item[@"ProgramArguments"]], @"invalid quality preserves startup item");
            check(air_shell_set_startup_options(1,2,1,1,1,1)==0, @"save selected H.264 startup");
            item=[NSDictionary dictionaryWithContentsOfFile:path];
            check([item[@"ProgramArguments"] isEqualToArray:@[NSBundle.mainBundle.executablePath,@"--mode",@"h264",@"--reconnect"]], @"H.264 selection has no opt-out flags");
            check(air_shell_set_startup_options(1,4,1,1,1,1)==0, @"restore default adaptive selection");

            NSMutableDictionary *stale = [item mutableCopy];
            stale[@"ProgramArguments"] = @[@"/nonexistent/stale-rustdesk-air", @"--mode", @"adaptive", @"--reconnect"];
            check([stale writeToFile:path atomically:YES], @"write stale executable fixture");
            check(air_shell_startup_enabled() == 0, @"stale executable reported disabled");
            check(air_shell_get_startup_options(&mode,&remote,&spaces,&raw,&match)==0, @"stale executable does not preload chooser");
            check(air_shell_set_startup(1) == 0, @"regenerate stale own item");
            item = [NSDictionary dictionaryWithContentsOfFile:path];
            check([item[@"ProgramArguments"][0] isEqualToString:NSBundle.mainBundle.executablePath], @"regenerated current executable");

            check(air_shell_set_startup(0) == 0 && ![files fileExistsAtPath:path], @"disable removes own item");
            check(air_shell_set_startup(0) == 0, @"disable is idempotent");

            NSDictionary *unrelated = @{@"Label": @"unrelated.agent", @"ProgramArguments": @[@"/usr/bin/true"]};
            check([unrelated writeToFile:path atomically:YES], @"write unrelated item fixture");
            lastError = nil;
            check(air_shell_set_startup(0) == -1 && lastError.length > 0 && [files fileExistsAtPath:path], @"disable refuses unrelated item");
            lastError = nil;
            check(air_shell_set_startup(1) == -1 && lastError.length > 0, @"enable refuses unrelated item");
            check([[NSDictionary dictionaryWithContentsOfFile:path][@"Label"] isEqualToString:@"unrelated.agent"], @"unrelated item preserved");
            check(air_shell_startup_enabled() == 0, @"unrelated item reported disabled");
        } @finally {
            NSError *cleanupError = nil;
            if (![files removeItemAtPath:base error:&cleanupError]) {
                fprintf(stderr, "Fixture cleanup failed: %s\n", cleanupError.localizedDescription.UTF8String);
                failures++;
            }
            fixtureHome = nil;
        }
        printf("RESULT %d failure(s)\n", failures);
        return failures ? 1 : 0;
    }
}
