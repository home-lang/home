#define _GNU_SOURCE
#include <sys/syscall.h>
#include <sys/mman.h>
#include <linux/dma-heap.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

extern int capture_backing_fixture_run(uint32_t);
static unsigned scenario, heap_opens, allocs, maps, unmaps, dma_closes, heap_closes;
static int heap=-1, dma[16], live_dma, live_maps, injected;
static void *addresses[32];
static size_t lengths[32];
static size_t page_size;
static void require(int yes,const char *what) {
    if(!yes){fprintf(stderr,"capture peer scenario %u: %s\n",scenario,what);exit(1);}
}
static int is_dma(int fd) {for(unsigned i=0;i<16;i++)if(dma[i]==fd)return 1;return 0;}
int open(const char *path,int flags,...) {
    if(strncmp(path,"/dev/dma_heap/",14)!=0) {
        mode_t mode=0;if(flags&O_CREAT){va_list ap;va_start(ap,flags);mode=va_arg(ap,unsigned);va_end(ap);}
        return (int)syscall(SYS_openat,AT_FDCWD,path,flags,mode);
    }
    heap_opens++;
    require(flags==(O_RDWR|O_CLOEXEC),"heap flags");
    if(scenario==12){errno=EACCES;return -1;}
    if((scenario==10||scenario==11)&&strstr(path,"vidbuf_cached")){errno=ENOENT;return -1;}
    if(scenario==11&&strstr(path,"default_cma_region")){errno=ENOENT;return -1;}
    require(heap<0,"duplicate heap owner");
    heap=(int)syscall(SYS_memfd_create,"capture-heap",1);
    require(heap>=0,"heap memfd");return heap;
}
int ioctl(int fd,unsigned long request,...) {
    va_list ap;va_start(ap,request);void *arg=va_arg(ap,void*);va_end(ap);
    if(fd!=heap)return (int)syscall(SYS_ioctl,fd,request,arg);
    struct dma_heap_allocation_data *value=arg;
    require(request==DMA_HEAP_IOCTL_ALLOC,"heap allocation UAPI");
    require(value->len==page_size&&value->fd==0&&value->fd_flags==(O_RDWR|O_CLOEXEC)&&value->heap_flags==0,"allocation fields");
    allocs++;
    if((scenario==1&&allocs==1)||(scenario==2&&allocs==2)){errno=ENOMEM;return -1;}
    int owned=(int)syscall(SYS_memfd_create,"capture-buffer",1);
    require(owned>=0,"buffer memfd");
    require(syscall(SYS_ftruncate,owned,(off_t)value->len)==0,"buffer length");
    for(unsigned i=0;i<16;i++)if(dma[i]<0){dma[i]=owned;live_dma++;value->fd=(uint32_t)owned;return 0;}
    require(0,"descriptor bound");return -1;
}
void *mmap(void *address,size_t length,int prot,int flags,int fd,off_t offset) {
    if(!is_dma(fd))return (void*)syscall(SYS_mmap,address,length,prot,flags,fd,offset);
    maps++;
    require(address==NULL&&length==page_size&&flags==MAP_SHARED&&offset==0,"mapping fields");
    require(prot==PROT_READ||prot==(PROT_READ|PROT_WRITE),"read or explicit separate write mapping");
    if((scenario==3&&maps==1)||(scenario==8&&maps==2)||(scenario==6&&prot==(PROT_READ|PROT_WRITE))){errno=ENOMEM;return MAP_FAILED;}
    void *result=(void*)syscall(SYS_mmap,address,length,prot,flags,fd,offset);
    require(result!=MAP_FAILED,"real shared mapping");
    for(unsigned i=0;i<32;i++)if(!addresses[i]){addresses[i]=result;lengths[i]=length;live_maps++;return result;}
    require(0,"mapping bound");return MAP_FAILED;
}
int munmap(void *address,size_t length) {
    for(unsigned i=0;i<32;i++)if(addresses[i]==address) {
        require(length==lengths[i],"unmap length");unmaps++;
        if((scenario==4||scenario==8)&&!injected){injected=1;errno=EBUSY;return -1;}
        require(syscall(SYS_munmap,address,length)==0,"real unmap");addresses[i]=NULL;live_maps--;return 0;
    }
    return (int)syscall(SYS_munmap,address,length);
}
int close(int fd) {
    if(fd==heap) {
        heap_closes++;heap=-1;require(syscall(SYS_close,fd)==0,"heap close once");
        if(scenario==7&&!injected){injected=1;errno=EINTR;return -1;}return 0;
    }
    for(unsigned i=0;i<16;i++)if(dma[i]==fd) {
        dma[i]=-1;live_dma--;dma_closes++;require(syscall(SYS_close,fd)==0,"buffer close once");
        if(scenario==5&&!injected){injected=1;errno=EINTR;return -1;}return 0;
    }
    return (int)syscall(SYS_close,fd);
}
int main(void) {
    long page=sysconf(_SC_PAGESIZE);require(page>0,"page size");page_size=(size_t)page;
    const unsigned cases[]={0,1,2,3,4,5,6,7,8,9,10,11,12};
    for(unsigned n=0;n<sizeof(cases)/sizeof(cases[0]);n++) {
        scenario=cases[n];heap_opens=allocs=maps=unmaps=dma_closes=heap_closes=0;injected=0;
        for(unsigned i=0;i<16;i++)dma[i]=-1;
        require(capture_backing_fixture_run(scenario)==0,"Zig owner contract");
        require(heap==-1&&live_dma==0&&live_maps==0,"all owners retired");
        require(heap_closes==(scenario==12?0u:1u),"heap lifetime");
        if(scenario==0||scenario==9)require(allocs==4&&maps==5&&unmaps==5&&dma_closes==4,"reuse or discarded backing and concurrent replacement ownership");
        if(scenario==10)require(heap_opens==2,"modern CMA fallback");
        if(scenario==11)require(heap_opens==3,"legacy CMA fallback");
        if(scenario==12)require(heap_opens==1,"permission failure preserves reason");
    }
    puts("13 Linux DMA heap ownership scenarios passed (independent memfd peer)");return 0;
}
