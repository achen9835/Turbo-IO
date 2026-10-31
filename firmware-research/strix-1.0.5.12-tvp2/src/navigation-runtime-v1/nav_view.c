#include "nav_view.h"
#include <string.h>
static int mag(int v){return v<0?-v:v;}
static TNXY xy(TNRPoint p){return (TNXY){p.x,p.y};} /* map-space point -> draw helper */
static void pixel(uint8_t *p,int w,int h,int x,int y,int radius,uint8_t gray){
 for(int yy=y-radius;yy<=y+radius;yy++)for(int xx=x-radius;xx<=x+radius;xx++)
 if(xx>=0&&xx<w&&yy>=0&&yy<h)p[(unsigned)yy*(unsigned)w+(unsigned)xx]=gray;
}
static void line(uint8_t *p,int w,int h,TNXY a,TNXY b,int radius,uint8_t gray){
 int dx=mag(b.x-a.x),dy=-mag(b.y-a.y),sx=a.x<b.x?1:-1,sy=a.y<b.y?1:-1,e=dx+dy;
 /* Input coordinates are generated from bounded normalized points, never
  * caller pixel coordinates. Bound iterations anyway against adapter errors. */
 for(unsigned n=0;n<1024;n++){pixel(p,w,h,a.x,a.y,radius,gray);if(a.x==b.x&&a.y==b.y)break;
  int e2=e*2;if(e2>=dy){e+=dy;a.x+=sx;}if(e2<=dx){e+=dx;a.y+=sy;}}
}
static void ring(uint8_t *p,int w,int h,int cx,int cy,int r,uint8_t gray){
 for(int dy=-r;dy<=r;dy++)for(int dx=-r;dx<=r;dx++){int d=dx*dx+dy*dy;
  if(d>=r*r-r&&d<=r*r+r)pixel(p,w,h,cx+dx,cy+dy,0,gray);}
}
/* Q14 sine via 0..90 degree symmetry: the AP payload has no libm. */
static const int16_t TN_SINQ14[91]={0,286,572,857,1143,1428,1713,1997,2280,2563,2845,3126,3406,3686,3964,4240,4516,4790,5063,5334,5604,5872,6138,6402,6664,6924,7182,7438,7692,7943,8192,8438,8682,8923,9162,9397,9630,9860,10087,10311,10531,10749,10963,11174,11381,11585,11786,11982,12176,12365,12551,12733,12911,13085,13255,13421,13583,13741,13894,14044,14189,14330,14466,14598,14726,14849,14968,15082,15191,15296,15396,15491,15582,15668,15749,15826,15897,15964,16026,16083,16135,16182,16225,16262,16294,16322,16344,16362,16374,16382,16384};
static int tsin(unsigned d){d%=360;return d<=90?TN_SINQ14[d]:d<=180?TN_SINQ14[180-d]:d<=270?-TN_SINQ14[d-180]:-TN_SINQ14[360-d];}
static int tcos(unsigned d){return tsin(d+90);}
/* 3x5 dot matrix: digits plus the few letters/symbols the marker labels need. */
static const uint8_t TN_GLYPH3X5[14][5]={{7,5,5,5,7},{2,6,2,2,7},{7,1,7,4,7},{7,1,7,1,7},{5,5,7,1,1},{7,4,7,1,7},{7,4,7,5,7},{7,1,1,2,2},{7,5,7,5,7},{7,5,7,1,7},
 {0,0,0,0,2},{5,6,4,6,5},{0,7,7,5,5},{0,5,2,5,0}}; /* 10='.' 11='k' 12='m' 13='×' */
static void glyph3x5_at(uint8_t *p,int w,int h,int x,int y,char c,uint8_t gray){
 if(c==' ')return; /* blank advances the label without drawing */
 unsigned g=c>='0'&&c<='9'?(unsigned)(c-'0'):c=='.'?10u:c=='k'?11u:c=='m'?12u:(unsigned char)c==0xD7?13u:(unsigned char)c==0xB7?10u:12u;
 for(int dy=0;dy<5;dy++)for(int dx=0;dx<3;dx++)
  if((TN_GLYPH3X5[g][dy]>>(2-dx))&1)pixel(p,w,h,x+dx,y+dy,0,gray);
}
static void text3x5_at(uint8_t *p,int w,int h,int x,int y,const char *s,unsigned n,uint8_t gray){
 for(unsigned i=0;i<n;i++)glyph3x5_at(p,w,h,x+(int)i*4,y,s[i],gray);
}
/* "300m" under a kilometre, "1.2km" past it, "12km" past ten; out holds 6. */
static unsigned dist3x5(char out[6],unsigned m){
 char *p=out;
 if(m<1000){char tmp[3];unsigned n=0;do{tmp[n++]=(char)('0'+m%10);m/=10;}while(m);
  while(n)*p++=tmp[--n];*p++='m';}
 else if(m<10000){*p++=(char)('0'+m/1000);*p++='.';*p++=(char)('0'+m%1000/100);*p++='k';*p++='m';}
 else{char tmp[2];unsigned n=0;m/=1000;do{tmp[n++]=(char)('0'+m%10);m/=10;}while(m);
  while(n)*p++=tmp[--n];*p++='k';*p++='m';}
 *p=0;return (unsigned)(p-out);
}
/* Camera, event and light distances follow the highlighted route. Labels yield
 * to existing road names, earlier alerts, the vehicle and the scale block. */
static bool label_clash(int x0,int y0,int x1,int y1,const int taken[][4],unsigned n){
 for(unsigned i=0;i<n;i++)if(x0<=taken[i][2]&&x1>=taken[i][0]&&y0<=taken[i][3]&&y1>=taken[i][1])return true;
 return false;
}
static unsigned small_uint(char out[4],unsigned v){
 char tmp[3];unsigned n=0,i=0;do{tmp[n++]=(char)('0'+v%10);v/=10;}while(v&&n<3);while(n)out[i++]=tmp[--n];return i;
}
static void map_markers(TNViewFrame *f,const TNRState *s,uint32_t now){
 TNRPose p;if(!s||!tnr_position(s,now,&p))return;
 bool stale=tnr_stale(s,now);uint8_t mg=stale?90:180;
 struct MK{uint16_t m;int16_t limit;char kind;}mk[10];unsigned n=0;
 if(f->visual.camera_kind&&f->visual.camera_m!=65535){mk[n].m=f->visual.camera_m;mk[n].limit=f->visual.camera_limit;mk[n].kind='c';n++;}
 if(f->visual.event_kind&&f->visual.event_m!=65535){mk[n].m=f->visual.event_m;mk[n].limit=0;mk[n].kind='e';n++;}
 if(!f->visual.light_count&&f->visual.lights!=255&&f->visual.lights_m!=65535){mk[n].m=f->visual.lights_m;mk[n].limit=0;mk[n].kind='l';n++;}
 for(unsigned i=0;i<f->visual.light_count&&n<10;i++){mk[n].m=f->visual.light_m[i];mk[n].limit=0;mk[n].kind='l';n++;}
 int taken[24][4];unsigned nt=0;TNRLabelView names[TNR_MAX_LABELS];unsigned names_n=tnr_labels(s,now,names);
 for(unsigned i=0;i<names_n;i++){taken[nt][0]=names[i].x;taken[nt][1]=names[i].y;taken[nt][2]=names[i].x+names[i].width;taken[nt][3]=names[i].y+20;nt++;}
 for(unsigned i=0;i<n;i++){
  if(mk[i].m>700u)continue;
  TNRPoint q=tnr_route_ahead(s,&p,mk[i].m);int radius=3;
  if(mk[i].kind=='c'){
   if(mk[i].limit>0){char number[4];unsigned digits=small_uint(number,(unsigned)mk[i].limit);radius=mk[i].limit>=100?8:7;
    for(int yy=-radius+1;yy<radius;yy++)for(int xx=-radius+1;xx<radius;xx++)if(xx*xx+yy*yy<(radius-1)*(radius-1))pixel(f->map,TN_MAP_W,TN_MAP_H,q.x+xx,q.y+yy,0,0);
    ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,radius,mg);text3x5_at(f->map,TN_MAP_W,TN_MAP_H,q.x-(int)(digits*4-1)/2,q.y-2,number,digits,mg);}
   else{ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,3,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);}
  }else if(mk[i].kind=='e'){
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x,q.y-4},(TNXY){q.x-4,q.y+3},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x,q.y-4},(TNXY){q.x+4,q.y+3},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-4,q.y+3},(TNXY){q.x+4,q.y+3},0,mg);
   pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);
  }else{
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-1,q.y-4},(TNXY){q.x+1,q.y-4},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-2,q.y-3},(TNXY){q.x-2,q.y+2},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x+2,q.y-3},(TNXY){q.x+2,q.y+2},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-1,q.y+3},(TNXY){q.x+1,q.y+3},0,mg);
   pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y-2,0,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,(uint8_t)(mg*2/3));pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y+2,0,(uint8_t)(mg/3));
  }
  char d[6];unsigned dn=dist3x5(d,mk[i].m);int gap=radius>3?radius+2:5,lx=q.x+gap,ly=q.y-2;
  if(q.x>=136&&q.x<=160&&q.y>=82&&q.y<=111)ly=q.y-13;
  if(lx+(int)dn*4-1>(int)TN_MAP_W-1)lx=q.x-gap-(int)dn*4+1;
  bool valid=lx>=0&&lx+(int)dn*4-1<(int)TN_MAP_W&&ly>=2&&ly+4<(int)TN_MAP_H-1&&!(lx<73&&ly+4>116);
  if(valid&&!label_clash(lx,ly,lx+(int)dn*4-1,ly+4,taken,nt)){
   taken[nt][0]=lx;taken[nt][1]=ly;taken[nt][2]=lx+(int)dn*4-1;taken[nt][3]=ly+4;nt++;text3x5_at(f->map,TN_MAP_W,TN_MAP_H,lx,ly,d,dn,stale?85:200);
  }
  taken[nt][0]=q.x-radius-1;taken[nt][1]=q.y-radius-1;taken[nt][2]=q.x+radius+1;taken[nt][3]=q.y+radius+1;nt++;
 }
}
/* Traffic levels use cumulative distance along the highlighted route, not
 * straight-line distance from the vehicle. A dim continuous guide preserves
 * route geometry between severity-specific dash patterns. */
static void dash_line(TNViewFrame *f,TNXY a,TNXY b,unsigned on,unsigned off,uint8_t gray){
 int dx=b.x-a.x,dy=b.y-a.y,total=mag(dx)>mag(dy)?mag(dx):mag(dy);
 if(total<=0){line(f->map,TN_MAP_W,TN_MAP_H,a,b,1,gray);return;}
 unsigned period=on+off;
 for(unsigned start=0;start<(unsigned)total;start+=period){
  unsigned end=start+on;if(end>(unsigned)total)end=(unsigned)total;
  if(end<=start)break;
  line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){a.x+dx*(int)start/total,a.y+dy*(int)start/total},(TNXY){a.x+dx*(int)end/total,a.y+dy*(int)end/total},1,gray);
 }
}
static void map_congestion(TNViewFrame *f,const TNRState *s,uint32_t now){
 if(!f->visual.bar_count)return;
 TNRPose p;if(!tnr_position(s,now,&p))return;
 const TNRScene *d=&s->scenes[s->bank];bool stale=tnr_stale(s,now);
 static const uint8_t tint[5]={0,0,205,175,150};
 for(unsigned i=0;i<d->path_count;i++){
  const TNRPath *r=&d->paths[i];if(r->style!=6)continue;int32_t base=tnr_route_base_qm(s,&p,r);unsigned walked=0;
  for(unsigned j=1;j<r->count;j++){
   TNRPoint a=d->points[r->first+j-1],b=d->points[r->first+j];int dx=b.x-a.x,dy=b.y-a.y,mx=mag(dx),my=mag(dy);unsigned len=(unsigned)((mx>my?mx:my)+((mx>my?my:mx)>>1));
   unsigned steps=(len+79u)/80u;if(steps<1u)steps=1u;if(steps>64u)steps=64u;
   for(unsigned k=0;k<steps;k++){
    TNRPoint p1={(int16_t)(a.x+dx*(int)k/(int)steps),(int16_t)(a.y+dy*(int)k/(int)steps)};
    TNRPoint p2={(int16_t)(a.x+dx*(int)(k+1)/(int)steps),(int16_t)(a.y+dy*(int)(k+1)/(int)steps)};
    int32_t along=base+(int32_t)walked+(int32_t)(len*(2*k+1)/(2*steps));if(along<0)continue;unsigned metres=(unsigned)along>>2;if(metres>=900)continue;
    unsigned bucket=metres*TN_BAR_MAX/900u,lv=bucket<f->visual.bar_count?f->visual.bar[bucket]:0;if(lv>4)lv=0;if(!tint[lv])continue;
    TNXY pa=xy(tnr_project(s,&p,p1)),pb=xy(tnr_project(s,&p,p2));uint8_t gray=stale?tint[lv]/3:tint[lv],guide=stale?30:90;
    line(f->map,TN_MAP_W,TN_MAP_H,pa,pb,1,guide);
    if(lv==2)dash_line(f,pa,pb,16,6,gray);else if(lv==3)dash_line(f,pa,pb,8,5,gray);else dash_line(f,pa,pb,4,4,gray);
   }
   walked+=len;
  }
 }
}
static void draw(TNViewFrame *f){
 memset(f->names,0,sizeof f->names);
 memset(f->icon,0,sizeof f->icon);memset(f->map,0,sizeof f->map);
 TNVisual *v=&f->visual;uint8_t gray=v->stale?100:255;
 for(unsigned i=1;i<v->icon_count;i++)
  line(f->icon,TN_ICON_W,TN_ICON_H,v->icon[i-1],v->icon[i],1,gray);
 /* Orientation: fixed heading-up (2026-10-26 真机拍板); the route always
  * rotates about the car pivot. The TNR3 vector map owns the canvas when one
  * is active (callers overlay tnr_draw + congestion tint + markers); this
  * fallback keeps the semantic route readable meanwhile. Map space comes from
  * nav_visual map(): x 406..518, y 10..122 for the 1024-point protocol box. */
 int cx=(v->nav_pos.x-406)*296/112,cy=(v->nav_pos.y-10)*148/112;
 int c=tcos(v->heading),s=tsin(v->heading),rm=25;
 TNXY tp[TN_POINTS_MAX];
 for(unsigned i=0;i<v->route_count;i++){
  int dx=(v->route[i].x-406)*296/112-cx,dy=(v->route[i].y-10)*148/112-cy;
  int rx=(dx*c+dy*s)>>14,ry=(-dx*s+dy*c)>>14;tp[i]=(TNXY){rx,ry};
  if(rx>rm)rm=rx;if(-rx>rm)rm=-rx;if(ry>rm)rm=ry;if(-ry>rm)rm=-ry;
 }
 for(unsigned i=0;i<v->route_count;i++)tp[i]=(TNXY){148+tp[i].x*70/rm,74+tp[i].y*70/rm};
 for(unsigned i=1;i<v->route_count;i++)
  line(f->map,TN_MAP_W,TN_MAP_H,tp[i-1],tp[i],2,v->stale?60:160);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){148,68},(TNXY){144,76},1,gray);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){148,68},(TNXY){152,76},1,gray);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){144,76},(TNXY){152,76},1,gray);
}
static void publish_names(TNView *v,TNViewFrame *f){
 TNWidgets *a=&v->api;
 (void)tnr_labels(&v->map_state,v->map_now,f->names);
 for(unsigned i=0;i<TNR_MAX_LABELS;i++){TNRLabelView *n=&f->names[i];
  if(n->width){a->place(a->ctx,v->map_text[i],238+n->x,4+n->y,n->width,20);a->text_static(a->ctx,v->map_text[i],n->text);}
  a->visible(a->ctx,v->map_text[i],n->width!=0);
 }
}
static void publish(TNView *v,TNViewFrame *f){
 TNWidgets *a=&v->api;
 a->buffer(a->ctx,v->icon,f->icon,TN_ICON_W,TN_ICON_H);
 a->buffer(a->ctx,v->map,f->map,TN_MAP_W,TN_MAP_H);
 const char *s[]={f->visual.distance,f->visual.turn,f->visual.road,f->visual.summary};
 for(unsigned i=0;i<4;i++)a->text_static(a->ctx,v->text[i],s[i]);
 a->text_static(a->ctx,v->text[5],f->visual.speed); /* text[4] stays clock-owned */
 /* Footer has a single owner: tn_view_clock. Semantic/map updates must not
  * replace its retained pointer with a power-mode hint between clock ticks. */
 if(!v->clock_shown){tn_clock_text(v->clocks[0],0,0,f->visual.stale);
  v->clock_bank=0;v->clock_shown=true;a->text_static(a->ctx,v->text[4],v->clocks[0]);}
 publish_names(v,f);
 /* Call on the single UI executor: no yields between mutations. Native LVGL
  * refresh occurs after this function; no ACK claims physical PRESENTED. */
}
bool tn_view_open(TNView *v,const TNWidgets *a,void *parent,const TNScene *s){
 if(!v||!a||!parent||!a->idle||!a->root||!a->canvas||!a->label||!a->place||!a->buffer||!a->text_static||!a->visible||!a->destroy||!a->idle(a->ctx))return false;
 if(v->root||v->open||v->retiring)return false;
 if(!tn_visual(s,false,&v->frames[0].visual))return false;v->api=*a;v->active=0;v->clock_shown=false;
 v->root=a->root(a->ctx,parent);if(!v->root)return false;a->visible(a->ctx,v->root,false);a->place(a->ctx,v->root,0,0,540,180);
 v->icon=a->canvas(a->ctx,v->root);v->map=a->canvas(a->ctx,v->root);
 static const unsigned sizes[]={32,20,16,16,16,16}; /* distance, turn, road, summary, clock, speed; 32/20/18/16 are the only sizes proven in the firmware font table */
 for(unsigned i=0;i<6;i++)v->text[i]=a->label(a->ctx,v->root,sizes[i]);
 for(unsigned i=0;i<TNR_MAX_LABELS;i++){v->map_text[i]=a->label(a->ctx,v->root,16);if(!v->map_text[i])goto fail;a->visible(a->ctx,v->map_text[i],false);}
 if(!v->icon||!v->map)goto fail;for(unsigned i=0;i<6;i++)if(!v->text[i])goto fail;
 /* The 296x148 map keeps its canvas. A 12px left rail and three distinct type
  * levels put the next manoeuvre first without shrinking the route canvas. */
 a->place(a->ctx,v->icon,12,12,TN_ICON_W,TN_ICON_H);a->place(a->ctx,v->map,238,4,TN_MAP_W,TN_MAP_H);
 a->place(a->ctx,v->text[0],84,10,138,34);a->place(a->ctx,v->text[5],86,48,120,20);
 a->place(a->ctx,v->text[1],12,82,210,24);
 a->place(a->ctx,v->text[2],12,110,210,20);a->place(a->ctx,v->text[3],12,134,210,18);
 a->place(a->ctx,v->text[4],12,158,516,18);
 draw(&v->frames[0]);publish(v,&v->frames[0]);v->open=true;a->visible(a->ctx,v->root,true);return true;
 fail:a->destroy(a->ctx,v->root);v->root=v->icon=v->map=NULL;memset(v->text,0,sizeof v->text);return false;
}
bool tn_view_update(TNView *v,const TNScene *s,bool stale){
 if(!v||!v->open||v->retiring||!v->api.idle(v->api.ctx))return false;
 unsigned next=v->active^1u;TNViewFrame *f=&v->frames[next];
 if(!tn_visual(s,stale,&f->visual))return false;draw(f);
 if(v->map_state.valid){tnr_draw(&v->map_state,v->map_now,f->map);map_congestion(f,&v->map_state,v->map_now);map_markers(f,&v->map_state,v->map_now);}
 publish(v,f);v->active=next;return true;
}
bool tn_view_close(TNView *v){
 if(!v)return false;if(!v->root)return true;
 v->retiring=true;v->open=false;v->api.visible(v->api.ctx,v->root,false);
 if(!v->api.idle(v->api.ctx))return false;v->api.destroy(v->api.ctx,v->root);
 v->root=v->icon=v->map=NULL;memset(v->text,0,sizeof v->text);v->retiring=false;return true;
}
bool tn_view_clock(TNView *v,int64_t local_epoch,int64_t eta_epoch,bool stale){
 if(!v||!v->open||v->retiring)return false;
 char text[64];tn_clock_text(text,local_epoch,eta_epoch,stale);
 if(v->clock_shown&&!memcmp(text,v->clocks[v->clock_bank],64))return true;
 if(!v->api.idle(v->api.ctx))return false;
 unsigned next=v->clock_bank^1u;
 memcpy(v->clocks[next],text,64);
 v->api.text_static(v->api.ctx,v->text[4],v->clocks[next]);
 v->clock_bank=next;v->clock_shown=true;return true;
}
bool tn_view_map(TNView *v,unsigned op,const uint8_t *body,size_t n,uint32_t now){
 if(!v||!v->open||v->retiring)return false;
 return tnr_receive(&v->map_state,op,body,n,now);
}
bool tn_view_map_tick(TNView *v,uint32_t now){
 if(!v||!v->open||v->retiring)return false;v->map_now=now;
 if(!tnr_needs_draw(&v->map_state,now))return true;
 if(!v->api.idle(v->api.ctx))return false;
 unsigned next=v->active^1u;TNViewFrame *f=&v->frames[next];
 f->visual=v->frames[v->active].visual; /* map tick repaints only; scene text untouched */
 if(v->map_state.valid){tnr_draw(&v->map_state,now,f->map);map_congestion(f,&v->map_state,now);map_markers(f,&v->map_state,now);}else draw(f);
 v->api.buffer(v->api.ctx,v->map,f->map,TN_MAP_W,TN_MAP_H);publish_names(v,f);v->active=next;tnr_presented(&v->map_state,now);return true;
}
