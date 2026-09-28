#define AIR_SPACES_JOURNAL_TEST 1
#include "../spaces.mm"
#include <cassert>
#include <cstdio>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;

extern "C" void air_set_error(const char *) {}
extern "C" int air_display_restore(void) { return 0; }
static const char *unblocked() { return nullptr; }

static int child(const char *executable,const char *mode,const char *directory) {
    pid_t pid=0;
    char *args[]={const_cast<char *>(executable),const_cast<char *>(mode),
        const_cast<char *>(directory),nullptr};
    assert(posix_spawn(&pid,executable,nullptr,nullptr,args,environ)==0);
    int status=0;assert(waitpid(pid,&status,0)==pid && WIFEXITED(status));
    return WEXITSTATUS(status);
}

int main(int argc,char **argv) { @autoreleasepool {
    if(argc==3) {
        journalTestPath=[[NSString stringWithUTF8String:argv[2]] stringByAppendingPathComponent:@"recovery.json"];
        if(strcmp(argv[1],"--recover")==0)
            return air_spaces_recover()!=0 && journalIOError=="Another Host owns Spaces recovery" ? 3 : 5;
        bool obtained=acquireJournalLock();
        if(strcmp(argv[1],"--probe")==0) {
            if(obtained)releaseJournalLock();
            return obtained ? 0 : 3;
        }
        if(strcmp(argv[1],"--crash")==0)_exit(obtained ? 0 : 4);
        return 99;
    }
    NSString *parent=argc>1 ? [NSString stringWithUTF8String:argv[1]] : NSTemporaryDirectory();
    NSString *pattern=[parent stringByAppendingPathComponent:@"air-spaces-lock-XXXXXX"];
    std::string bytes=pattern.fileSystemRepresentation;
    std::vector<char> directory(bytes.begin(),bytes.end());directory.push_back('\0');
    assert(mkdtemp(directory.data()));
    NSString *base=[NSString stringWithUTF8String:directory.data()];
    journalTestPath=[base stringByAppendingPathComponent:@"recovery.json"];

    assert(acquireJournalLock());
    assert(child(argv[0],"--probe",directory.data())==3);
    saved.push_back(SavedWindow{});
    assert(air_spaces_prepare()!=0 && journalLockFD>=0);
    assert(child(argv[0],"--probe",directory.data())==3);
    saved.clear();
    RecoveryHooks hooks={};hooks.migrationBlocker=unblocked;recoveryHooks=&hooks;
    assert([@"{}" writeToFile:journalTestPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(air_spaces_prepare()!=0 && journalLockFD>=0);
    assert(child(argv[0],"--probe",directory.data())==3);
    assert(child(argv[0],"--recover",directory.data())==3);
    recoveryHooks=nullptr;
    assert([[NSFileManager defaultManager] removeItemAtPath:journalTestPath error:nil]);
    releaseJournalLock();
    assert(child(argv[0],"--crash",directory.data())==0);
    assert(acquireJournalLock());
    releaseJournalLock();
    assert(child(argv[0],"--probe",directory.data())==0);
    journalTestPath=nil;
    assert([[NSFileManager defaultManager] removeItemAtPath:base error:nil]);
    puts("Spaces ownership: second process refused; crash released advisory lock");
    return 0;
} }
