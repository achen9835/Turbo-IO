#include "nav_view.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct {bool busy;unsigned alloc,fail_at,destroyed,buffers,texts;uintptr_t objects[13];const uint8_t *pixels[2];const char *strings[10];} Mock;
static bool idle(void *p){return !((Mock *)p)->busy;}
static void *create(void *p,void *parent){assert(parent);Mock *m=p;unsigned n=++m->alloc;if(n==m->fail_at)return NULL;assert(n<=13);return &m->objects[n-1];}
static void *label(void *p,void *parent,unsigned size){assert(size>=16&&size<=32);return create(p,parent);}
static void place(void *p,void *obj,int x,int y,int w,int h){(void)p;assert(obj&&x>=0&&y>=0&&x+w<=540&&y+h<=180);}
static void buffer(void *p,void *obj,const uint8_t *bytes,unsigned w,unsigned h){assert(obj&&bytes);Mock *m=p;assert((w==64&&h==64)||(w==296&&h==148));m->pixels[m->buffers%2]=bytes;m->buffers++;}
static void text(void *p,void *obj,const char *s){assert(obj&&s);Mock *m=p;ptrdiff_t slot=(uintptr_t *)obj-m->objects-3; /* root+icon+map precede the labels */ assert(slot>=0&&slot<10);m->strings[slot]=s;m->texts++;}
static void visible(void *p,void *obj,bool yes){(void)p;(void)yes;assert(obj);}
static void destroy(void *p,void *obj){assert(obj);((Mock *)p)->destroyed++;}
static TNWidgets api(Mock *m){return (TNWidgets){m,idle,create,create,label,place,buffer,text,visible,destroy};}
int main(void){
 TNScene s={.icon=TN_RIGHT,.distance_m=80,.point_count=3,.position={512,512},.heading=90};
 strcpy(s.road,"测试道路");strcpy(s.turn,"前方右转");s.points[0]=(TNPoint){512,1023};s.points[1]=(TNPoint){512,512};s.points[2]=(TNPoint){1023,512};
 for(unsigned fail=1;fail<=13;fail++){Mock m={.fail_at=fail};TNWidgets a=api(&m);TNView v={0};
  assert(!tn_view_open(&v,&a,&m,&s));assert(!v.open&&!v.root);assert(m.destroyed==(fail!=1));}
 Mock m={0};TNWidgets a=api(&m);TNView v={0};assert(tn_view_open(&v,&a,&m,&s));assert(m.alloc==13&&m.buffers==2&&m.texts==6);
 assert(!strcmp(m.strings[0],"80 m"));const uint8_t *first=m.pixels[0];uint32_t original=tn_crc(first,64*64);
 assert(original!=tn_crc((const uint8_t[64*64]){0},64*64));
 m.busy=true;s.icon=TN_LEFT;s.distance_m=60;assert(!tn_view_update(&v,&s,false));assert(m.buffers==2&&tn_crc(first,64*64)==original);
 m.busy=false;assert(tn_view_update(&v,&s,false));assert(m.alloc==13&&m.pixels[0]!=first);assert(!strcmp(m.strings[0],"60 m"));
 for(unsigned i=0;i<1000;i++){s.icon=(uint8_t)(i%TN_ICON_COUNT);s.heading=(uint16_t)(i%360);s.distance_m=i;assert(tn_view_update(&v,&s,i%2));}
 assert(m.alloc==13);m.busy=true;assert(!tn_view_close(&v));assert(v.retiring&&m.destroyed==0);assert(!tn_view_update(&v,&s,false));
 m.busy=false;assert(tn_view_close(&v)&&m.destroyed==1);assert(tn_view_close(&v)&&m.destroyed==1);
 Mock cm={0};TNWidgets ca=api(&cm);TNView cv={0};assert(tn_view_open(&cv,&ca,&cm,&s));
 int64_t epoch=946684800+23*3600+59*60;
 assert(tn_view_clock(&cv,epoch,epoch+120,false));assert(strstr(cm.strings[4],"明日 预计 00:01"));
 const char *retained=cm.strings[4];char retained_copy[64];memcpy(retained_copy,retained,64);
 unsigned texts=cm.texts,buffers=cm.buffers;
 assert(tn_view_clock(&cv,epoch+1,epoch+120,false));assert(cm.texts==texts);
 cm.busy=true;assert(!tn_view_clock(&cv,epoch+60,epoch+120,false));assert(!memcmp(retained,retained_copy,64));
 cm.busy=false;assert(tn_view_clock(&cv,epoch+60,epoch+120,false));assert(cm.strings[4]!=retained&&cm.buffers==buffers&&cm.alloc==13);
 assert(tn_view_clock(&cv,epoch,epoch+120,true));assert(strstr(cm.strings[4],"过期"));
 const char *footer=cm.strings[4];char footer_copy[64];memcpy(footer_copy,footer,64);
 for(unsigned i=0;i<1000;i++){s.mode=i%2?TN_ALWAYS:TN_SMART;s.distance_m=i;assert(tn_view_update(&cv,&s,false));
  assert(cv.clock_shown&&cm.strings[4]==footer&&!memcmp(footer,footer_copy,64));
  assert(!strstr(cm.strings[4],"常亮")&&!strstr(cm.strings[4],"无更新息屏"));}
 assert(tn_view_clock(&cv,epoch,epoch+120,false));assert(strstr(cm.strings[4],"当前 23:59"));
 footer=cm.strings[4];memcpy(footer_copy,footer,64);
 assert(tn_view_update(&cv,&s,true)&&cm.strings[4]==footer&&!memcmp(footer,footer_copy,64));
 assert(tn_view_clock(&cv,epoch,epoch+120,true));assert(strstr(cm.strings[4],"过期"));
 assert(tn_view_close(&cv));assert(!tn_view_clock(&cv,epoch,epoch+120,false));
 /* Vector-map overlay: a minimal TNR scene + pose must light up map_markers
  * (camera/event/lights on the heading ray) without touching the widget
  * topology, and the speed label now carries its km/h unit. */
 {
  TNScene nav=s;Mock mm={0};TNWidgets ma=api(&mm);TNView mv={0};assert(tn_view_open(&mv,&ma,&mm,&nav));
  uint8_t sc[56]={0},pose[12]={0};
  sc[0]=1;sc[4]=0x40;sc[5]=0x01;sc[6]=2;sc[8]=6; /* gen=1, range=320, 2 paths, 6 points */
  sc[16]=3;sc[18]=6;sc[20]=8; /* route path: 3 pts, highlighted style, top layer */
  sc[24]=3;sc[26]=4; /* road path: 3 pts, residential style */
  sc[34]=0x90;sc[35]=0x01;sc[38]=0x20;sc[39]=0x03; /* (0,400),(0,800) */
  sc[40]=0x38;sc[41]=0xFF;sc[48]=0xC8;sc[49]=0x00; /* (-200,0),(200,0) */
  pose[0]=1;pose[8]=0; /* gen=1, origin, heading north */
  assert(tn_view_map(&mv,7,sc,sizeof sc,1000));assert(tn_view_map(&mv,8,pose,sizeof pose,1000));
  nav.camera_kind=1;nav.camera_m=60;nav.camera_limit=60;nav.event_kind=1;nav.event_m=300;
  nav.light_count=1;nav.light_m[0]=150;nav.speed_kmh=42;
  assert(tn_view_update(&mv,&nav,false));assert(!strcmp(mm.strings[5],"42km/h"));
  nav.camera_m=0;nav.event_m=700;nav.light_m[0]=65535; /* vehicle-on-marker and viewport edge must not crash */
  assert(tn_view_update(&mv,&nav,false));assert(tn_view_close(&mv));
 }
 printf("PASS bounded two-bank LVGL view facade, 13 allocation failures, immutable referenced points/text/pixels, 1000 updates no new objects, busy retirement; view=%zu bytes. Mock widgets only.\n",sizeof(TNView));
 return 0;
}
