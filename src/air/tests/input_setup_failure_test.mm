// Failure injection is read-only: no event tap, device registration, or app activation.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <cassert>
#include <cstring>

static const char *lastError;
extern "C" void air_capture_v2_record_mt(const unsigned char *,unsigned long,double){}
#define CGPreflightListenEventAccess() true
#define AXIsProcessTrusted() true
#define CGEventTapCreate(...) ((CFMachPortRef)nullptr)
#define dlopen(...) nullptr
#define dlsym(...) nullptr
#include "../input.mm"
#undef CGPreflightListenEventAccess
#undef AXIsProcessTrusted
#undef CGEventTapCreate
#undef dlopen
#undef dlsym

extern "C" void air_set_error(const char *value){lastError=value;}
extern "C" void air_app_stop(void){}

int main(){
 for(int attempt=0;attempt<2;attempt++){
  assert(air_input_setup(nullptr,nullptr)==-1);
  assert(lastError&&strstr(lastError,"Input Monitoring"));
  assert(!clientInput&&!connected&&!enabled);
  assert(!inputTap&&!inputSource&&!inputObserver);
  assert(!mtDeviceList&&!mtRunning&&awakeAssertion==kIOPMNullAssertionID);
  assert(!sendNative&&!releaseRemote&&!sendQueue);
 }
 return 0;
}
