#include "native_capture.h"
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
int main(void) {
    home_capture_config cfg={48000,2,480};
    home_audio_capture *capture=NULL;
    assert(home_audio_open(&cfg,"null",&capture)==0);
    uint8_t bytes[1920];uint32_t frames=0;uint64_t timestamp=0;int64_t error=0;
    assert(home_audio_read(capture,bytes,480,100,&frames,&timestamp,&error)==0);
    assert(frames>0 && frames<=480 && timestamp>0 && error==0);
    home_audio_close(capture);
    capture=NULL;cfg.channels=3;
    assert(home_audio_open(&cfg,"null",&capture)==-1 && !capture);
    return 0;
}
