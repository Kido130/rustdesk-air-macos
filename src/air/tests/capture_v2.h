#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int air_capture_v2_start(int seconds,const char *absolute_path);
void air_capture_v2_schedule(int seconds,const char *absolute_path,unsigned long long input_generation);
void air_capture_v2_stop(void);
int air_capture_v2_status(void);
void air_capture_v2_record_mt(const unsigned char *packet,unsigned long length,double source_timestamp);

#ifdef __cplusplus
}
#endif
