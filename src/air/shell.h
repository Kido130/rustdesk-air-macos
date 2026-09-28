#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int air_shell_startup_enabled(void);
int air_shell_get_startup_options(int *mode,int *remote_mode,int *remote_spaces,int *raw_contacts,int *match_display);
int air_shell_set_startup(int enabled);
int air_shell_set_startup_options(int enabled,int mode,int remote_mode,int remote_spaces,int raw_contacts,int match_display);
void air_shell_begin(void);
void air_shell_end(void);
#ifdef __cplusplus
}
#endif
