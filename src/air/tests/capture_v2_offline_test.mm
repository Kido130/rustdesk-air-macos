// This fixture includes capture internals; it never starts a tap or posts events.
extern "C" unsigned long long air_input_generation(void){return 0;}
extern "C" int air_input_grabbing(void){return 0;}
extern "C" int air_input_capture_mt(int){return 0;}
extern "C" int air_input_secure_active(void){return 0;}
#include "capture_v2.mm"
#include <cassert>
#include <sys/stat.h>
#include <string>

static CaptureRecord native(uint16_t type,uint64_t ns,uint32_t phase){
 CaptureRecord r;r.kind=kindCG;r.type=type;r.monotonicNs=ns;r.sourceTimestamp=ns-100;
 r.phase=phase;r.sender=42;r.payload={0x01,0x02,0x03};return r;
}
static CaptureRecord raw(uint64_t ns,int contacts){
 CaptureRecord r;r.kind=kindMT;r.monotonicNs=ns;r.sender=42;r.touches=contacts;
 r.payload={'R','D','A','F',1,(uint8_t)contacts,0,0};append64(r.payload,r.sender);
 for(int i=0;i<contacts;i++){
  append32(r.payload,(uint32_t)i);append32(r.payload,4);
  float values[]={.25f,.5f,.75f};for(float f:values){uint32_t bits;memcpy(&bits,&f,4);append32(r.payload,bits);}
 }
 return r;
}
int main(int argc,char **argv){
 if(argc!=2)return 2;
 const int allowed[]={18,19,20,22,29,30,31,32,34};
 for(int type=0;type<64;type++){
  bool expected=false;for(int candidate:allowed)expected|=type==candidate;
  assert(allowedGesture((CGEventType)type)==expected);
 }
 assert(air_capture_v2_start(0,argv[1])==-1);
 assert(air_capture_v2_status()==-1);
 CaptureRing small;
 assert(small.add(native(22,1'000'000'000,1)));
 assert(small.add(raw(1'001'000'000,2)));
 assert(small.add(native(29,1'002'000'000,0)));
 assert(small.add(native(30,1'003'000'000,1)));
 assert(small.add(raw(1'004'000'000,2)));
 assert(small.add(native(30,1'005'000'000,8)));
 assert(small.add(raw(1'006'000'000,0)));
 assert(small.add(native(22,1'007'000'000,8)));
 assert(small.bytes<=maxPayloadBytes&&small.records.size()==8);
 int fd=open(argv[1],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
 assert(fd>=0);
 assert(open(argv[1],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600)<0);
 assert(save(fd,argv[1],small,0));
 struct stat st{};assert(!stat(argv[1],&st));assert((st.st_mode&0777)==0600);
 std::string cancelled=std::string(argv[1])+".cancelled";
 capture.path=[NSString stringWithUTF8String:cancelled.c_str()];
 capture.fd=open(cancelled.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);assert(capture.fd>=0);
 assert(abortStart(-3)==-3&&access(cancelled.c_str(),F_OK));
 std::string replaced=std::string(argv[1])+".replaced";
 int original=open(replaced.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);assert(original>=0);
 assert(!unlink(replaced.c_str()));
 int replacement=open(replaced.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);assert(replacement>=0);
 assert(!save(original,replaced.c_str(),small,0));
 assert(!stat(replaced.c_str(),&st));close(replacement);assert(!unlink(replaced.c_str()));
 CaptureRing recordCap;
 for(uint64_t i=1;i<=maxRecords+3;i++)assert(recordCap.add(native(29,i,0)));
 assert(recordCap.records.size()==maxRecords&&recordCap.dropped==3);
 assert(recordCap.records.front().monotonicNs==4);
 CaptureRing byteCap;
 for(uint64_t i=1;i<=300;i++){
  auto record=native(29,i,0);record.payload.resize(maxCGBytes);
  assert(byteCap.add(std::move(record)));
 }
 assert(byteCap.bytes<=maxPayloadBytes&&byteCap.dropped>0);
 auto bytes=serialize(byteCap,0);assert(bytes.size()==fileHeaderBytes+byteCap.bytes);
 auto oversized=native(29,301,0);oversized.payload.resize(maxPayloadBytes);
 assert(!byteCap.add(std::move(oversized)));
 assert(byteCap.dropped>0);
 return 0;
}
