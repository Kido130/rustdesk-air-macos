#import <AppKit/AppKit.h>
#include "native.h"
#include "shell.h"
#include <sys/stat.h>

static NSString *const agentLabel=@"dev.rustdesk.air.client";
static NSApplicationPresentationOptions previousPresentation=NSApplicationPresentationDefault;
static BOOL presenting=NO;
static BOOL startupRemote=YES,startupSpaces=YES,startupRaw=YES,startupMatch=YES;
static int startupMode=4;

static NSString *agentPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/dev.rustdesk.air.client.plist"];
}
static BOOL ownedAgent(void) {
    NSDictionary *agent=[NSDictionary dictionaryWithContentsOfFile:agentPath()];
    return [agent[@"Label"] isEqualToString:agentLabel];
}
extern "C" int air_shell_startup_enabled(void) {
    if (!ownedAgent()) return 0;
    NSDictionary *agent=[NSDictionary dictionaryWithContentsOfFile:agentPath()];
    NSArray *arguments=agent[@"ProgramArguments"];
    if (![arguments isKindOfClass:[NSArray class]] || !arguments.count
        || ![arguments[0] isKindOfClass:[NSString class]]) return 0;
    return [arguments[0] isEqualToString:NSBundle.mainBundle.executablePath] ? 1 : 0;
}
extern "C" int air_shell_get_startup_options(int *mode,int *remote_mode,int *remote_spaces,int *raw_contacts,int *match_display) {
    if(!mode||!remote_mode||!remote_spaces||!raw_contacts||!match_display||!ownedAgent())return 0;
    NSArray *arguments=[NSDictionary dictionaryWithContentsOfFile:agentPath()][@"ProgramArguments"];
    if(![arguments isKindOfClass:[NSArray class]]||arguments.count<4)return 0;
    for(id value in arguments)if(![value isKindOfClass:[NSString class]])return 0;
    if(![arguments[0] isEqualToString:NSBundle.mainBundle.executablePath]
        ||![arguments[1] isEqualToString:@"--mode"]||![arguments[3] isEqualToString:@"--reconnect"])return 0;
    NSString *quality=arguments[2];
    int selectedMode=[quality isEqualToString:@"exact"]?1:[quality isEqualToString:@"h264"]?2:
        [quality isEqualToString:@"hevc"]?3:[quality isEqualToString:@"adaptive"]?4:0;
    if(!selectedMode)return 0;
    NSMutableSet *seen=[NSMutableSet new];
    for(NSUInteger index=4;index<arguments.count;index++){
        NSString *option=arguments[index];
        if(![@[@"--no-remote-mode",@"--no-remote-spaces",@"--no-raw-contacts",@"--no-match-display",@"--windowed"] containsObject:option]
            ||[seen containsObject:option])return 0;
        [seen addObject:option];
    }
    BOOL windowed=[seen containsObject:@"--windowed"];
    BOOL unmatched=[seen containsObject:@"--no-match-display"];
    if(windowed!=unmatched)return 0;
    BOOL remote=![seen containsObject:@"--no-remote-mode"];
    if(!remote&&([seen containsObject:@"--no-remote-spaces"]||[seen containsObject:@"--no-raw-contacts"]))return 0;
    *mode=selectedMode;*remote_mode=remote;*remote_spaces=remote&&![seen containsObject:@"--no-remote-spaces"];
    *raw_contacts=remote&&![seen containsObject:@"--no-raw-contacts"];*match_display=!unmatched;
    return 1;
}
extern "C" int air_shell_set_startup(int enabled) {
    @autoreleasepool {
        NSString *path=agentPath();
        if (!enabled) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return 0;
            if (!ownedAgent()) { air_set_error("The Air startup item has changed; it was not removed."); return -1; }
            NSError *error=nil;
            if (![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
                air_set_error(error.localizedDescription.UTF8String); return -1;
            }
            return 0;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:path] && !ownedAgent()) {
            air_set_error("An unrelated startup item uses Air's path."); return -1;
        }
        NSString *executable=NSBundle.mainBundle.executablePath;
        if (!executable.length) { air_set_error("Cannot locate the Air executable."); return -1; }
        NSString *directory=[path stringByDeletingLastPathComponent];
        NSError *error=nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
            air_set_error(error.localizedDescription.UTF8String); return -1;
        }
        NSString *quality=startupMode==1?@"exact":startupMode==2?@"h264":startupMode==3?@"hevc":@"adaptive";
        NSMutableArray *arguments=[NSMutableArray arrayWithArray:@[executable,@"--mode",quality,@"--reconnect"]];
        if (!startupRemote) [arguments addObject:@"--no-remote-mode"];
        else {
            if (!startupSpaces) [arguments addObject:@"--no-remote-spaces"];
            if (!startupRaw) [arguments addObject:@"--no-raw-contacts"];
        }
        if (!startupMatch) [arguments addObjectsFromArray:@[@"--no-match-display",@"--windowed"]];
        NSDictionary *agent=@{
            @"Label":agentLabel,
            @"ProgramArguments":arguments,
            @"RunAtLoad":@YES,
            @"KeepAlive":@NO,
            @"ProcessType":@"Interactive"
        };
        if (![agent writeToFile:path atomically:YES] || chmod(path.fileSystemRepresentation,0600)!=0) {
            air_set_error("Cannot save the Air startup item."); return -1;
        }
        return 0;
    }
}
extern "C" int air_shell_set_startup_options(int enabled,int mode,int remote_mode,int remote_spaces,int raw_contacts,int match_display) {
    if(mode<1||mode>4){air_set_error("Choose a valid Air streaming quality for login startup.");return -1;}
    startupMode=mode;
    startupRemote=remote_mode!=0;
    startupSpaces=remote_spaces!=0;
    startupRaw=raw_contacts!=0;
    startupMatch=match_display!=0;
    return air_shell_set_startup(enabled);
}
extern "C" void air_shell_begin(void) {
    void (^begin)(void)=^{
        if (presenting) return;
        previousPresentation=NSApp.presentationOptions;
        // Keep the Air's menu bar available at the top, while reserving the
        // bottom edge for the Pro's streamed Dock. AppKit disallows combining
        // AutoHideDock with HideDock, including when fullscreen set the former.
        auto options=previousPresentation & ~(NSApplicationPresentationAutoHideDock|NSApplicationPresentationHideMenuBar);
        NSApp.presentationOptions=options|NSApplicationPresentationHideDock|NSApplicationPresentationAutoHideMenuBar|NSApplicationPresentationDisableProcessSwitching;
        presenting=YES;
    };
    if (NSThread.isMainThread) begin(); else dispatch_async(dispatch_get_main_queue(),begin);
}
extern "C" void air_shell_end(void) {
    void (^end)(void)=^{
        if (!presenting) return;
        NSApp.presentationOptions=previousPresentation;
        presenting=NO;
    };
    if (NSThread.isMainThread) end(); else dispatch_async(dispatch_get_main_queue(),end);
}
