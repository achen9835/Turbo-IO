#include "nav_view.h"
#include <string.h>
static int mag(int v){return v<0?-v:v;}
static TNXY xy(TNRPoint p){return (TNXY){p.x,p.y};}
static void pixel(uint8_t *p,int w,int h,int x,int y,int radius,uint8_t gray){
 for(int yy=y-radius;yy<=y+radius;yy++)for(int xx=x-radius;xx<=x+radius;xx++)
 if(xx>=0&&xx<w&&yy>=0&&yy<h)p[(unsigned)yy*(unsigned)w+(unsigned)xx]=gray;
}
static void line(uint8_t *p,int w,int h,TNXY a,TNXY b,int radius,uint8_t gray){
 int dx=mag(b.x-a.x),dy=-mag(b.y-a.y),sx=a.x<b.x?1:-1,sy=a.y<b.y?1:-1,e=dx+dy;
 for(unsigned n=0;n<1024;n++){pixel(p,w,h,a.x,a.y,radius,gray);if(a.x==b.x&&a.y==b.y)break;
  int e2=e*2;if(e2>=dy){e+=dy;a.x+=sx;}if(e2<=dx){e+=dx;a.y+=sy;}}
}
static void ring(uint8_t *p,int w,int h,int cx,int cy,int r,uint8_t gray){
 for(int dy=-r;dy<=r;dy++)for(int dx=-r;dx<=r;dx++){int d=dx*dx+dy*dy;
  if(d>=r*r-r&&d<=r*r+r)pixel(p,w,h,cx+dx,cy+dy,0,gray);}
}
static const int16_t TN_SINQ14[91]={0,286,572,857,1143,1428,1713,1997,2280,2563,2845,3126,3406,3686,3964,4240,4516,4790,5063,5334,5604,5872,6138,6402,6664,6924,7182,7438,7692,7943,8192,8438,8682,8923,9162,9397,9630,9860,10087,10311,10531,10749,10963,11174,11381,11585,11786,11982,12176,12365,12551,12733,12911,13085,13255,13421,13583,13741,13894,14044,14189,14330,14466,14598,14726,14849,14968,15082,15191,15296,15396,15491,15582,15668,15749,15826,15897,15964,16026,16083,16135,16182,16225,16262,16294,16322,16344,16362,16374,16382,16384};
static int tsin(unsigned d){d%=360;return d<=90?TN_SINQ14[d]:d<=180?TN_SINQ14[180-d]:d<=270?-TN_SINQ14[d-180]:-TN_SINQ14[360-d];}
static int tcos(unsigned d){return tsin(d+90);}
static const uint8_t TN_GLYPH3X5[14][5]={{7,5,5,5,7},{2,6,2,2,7},{7,1,7,4,7},{7,1,7,1,7},{5,5,7,1,1},{7,4,7,1,7},{7,4,7,5,7},{7,1,1,2,2},{7,5,7,5,7},{7,5,7,1,7},
 {0,0,0,0,2},{5,6,4,6,5},{0,7,7,5,5},{0,5,2,5,0}};
static void glyph3x5_at(uint8_t *p,int w,int h,int x,int y,char c,uint8_t gray){
 if(c==' ')return;
 unsigned g=c>='0'&&c<='9'?(unsigned)(c-'0'):c=='.'?10u:c=='k'?11u:c=='m'?12u:(unsigned char)c==0xD7?13u:(unsigned char)c==0xB7?10u:12u;
 for(int dy=0;dy<5;dy++)for(int dx=0;dx<3;dx++)
  if((TN_GLYPH3X5[g][dy]>>(2-dx))&1)pixel(p,w,h,x+dx,y+dy,0,gray);
}
static void text3x5_at(uint8_t *p,int w,int h,int x,int y,const char *s,unsigned n,uint8_t gray){
 for(unsigned i=0;i<n;i++)glyph3x5_at(p,w,h,x+(int)i*4,y,s[i],gray);
}
static unsigned dist3x5(char out[6],unsigned m){
 char *p=out;
 if(m<1000){char tmp[3];unsigned n=0;do{tmp[n++]=(char)('0'+m%10);m/=10;}while(m);
  while(n)*p++=tmp[--n];*p++='m';}
 else if(m<10000){*p++=(char)('0'+m/1000);*p++='.';*p++=(char)('0'+m%1000/100);*p++='k';*p++='m';}
 else{char tmp[2];unsigned n=0;m/=1000;do{tmp[n++]=(char)('0'+m%10);m/=10;}while(m);
  while(n)*p++=tmp[--n];*p++='k';*p++='m';}
 *p=0;return (unsigned)(p-out);
}
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
 /* 真导航语义：每个标记钉在沿路真实位置；画不画由"投影后是否还在画布内"决定，
  * 不再有固定 700m 门槛——地图可视多远就能看到多远，随地图滚动自然出现/消失。
  * kind: 0=红绿灯 255=事件 1..5=电子眼(enum TNCamera)。cam_count>0 时沿路相机
  * 全量来自 EXT5 camList，旧的单槽 camera 仅作无列表时的兜底。 */
 struct MK{uint16_t m;int16_t limit;uint8_t kind;}mk[22];unsigned n=0;
 if(f->visual.cam_count)for(unsigned i=0;i<f->visual.cam_count&&n<16;i++){if(f->visual.cam_m[i]==65535)continue;mk[n].m=f->visual.cam_m[i];mk[n].limit=f->visual.cam_limit[i];mk[n].kind=f->visual.cam_kind[i];n++;}
 else if(f->visual.camera_kind&&f->visual.camera_m!=65535){mk[n].m=f->visual.camera_m;mk[n].limit=f->visual.camera_limit;mk[n].kind=(uint8_t)f->visual.camera_kind;n++;}
 if(f->visual.event_kind&&f->visual.event_m!=65535&&n<21){mk[n].m=f->visual.event_m;mk[n].limit=0;mk[n].kind=255;n++;}
 if(!f->visual.light_count&&f->visual.lights!=255&&f->visual.lights_m!=65535&&n<21){mk[n].m=f->visual.lights_m;mk[n].limit=0;mk[n].kind=0;n++;}
 for(unsigned i=0;i<f->visual.light_count&&n<21;i++){mk[n].m=f->visual.light_m[i];mk[n].limit=0;mk[n].kind=0;n++;}
 int taken[52][4];unsigned nt=0;TNRLabelView names[TNR_MAX_LABELS];unsigned names_n=tnr_labels(s,now,names);
 for(unsigned i=0;i<names_n&&nt<48;i++){taken[nt][0]=names[i].x;taken[nt][1]=names[i].y;taken[nt][2]=names[i].x+names[i].width;taken[nt][3]=names[i].y+20;nt++;}
 for(unsigned i=0;i<n;i++){
  TNRPoint q=tnr_route_ahead(s,&p,mk[i].m);int radius=3;
  if(q.x<-10||q.x>(int)TN_MAP_W+10||q.y<-10||q.y>(int)TN_MAP_H+10)continue; /* 画布门：可视范围之外不画 */
  if(mk[i].kind==255){ /* 事件：三角 */
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x,q.y-4},(TNXY){q.x-4,q.y+3},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x,q.y-4},(TNXY){q.x+4,q.y+3},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-4,q.y+3},(TNXY){q.x+4,q.y+3},0,mg);
   pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);
  }else if(mk[i].kind==0){ /* 红绿灯 glyph（加粗） */
   radius=6; /* 占位同步放大，距离文字让位 */
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-2,q.y-6},(TNXY){q.x+2,q.y-6},1,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-3,q.y-5},(TNXY){q.x-3,q.y+4},1,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x+3,q.y-5},(TNXY){q.x+3,q.y+4},1,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-2,q.y+5},(TNXY){q.x+2,q.y+5},1,mg);
   pixel(f->map,TN_MAP_W,TN_MAP_H,q.x-1,q.y-4,1,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x-1,q.y-1,1,(uint8_t)(mg*2/3));pixel(f->map,TN_MAP_W,TN_MAP_H,q.x-1,q.y+2,1,(uint8_t)(mg/3));
  }else if(mk[i].kind==TN_CAMERA_SPEED){ /* 测速：限速圈+数字 */
   if(mk[i].limit>0){char number[4];unsigned digits=small_uint(number,(unsigned)mk[i].limit);radius=mk[i].limit>=100?8:7;
    for(int yy=-radius+1;yy<radius;yy++)for(int xx=-radius+1;xx<radius;xx++)if(xx*xx+yy*yy<(radius-1)*(radius-1))pixel(f->map,TN_MAP_W,TN_MAP_H,q.x+xx,q.y+yy,0,0);
    ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,radius,mg);text3x5_at(f->map,TN_MAP_W,TN_MAP_H,q.x-(int)(digits*4-1)/2,q.y-2,number,digits,mg);}
   else{ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,3,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);}
  }else if(mk[i].kind==TN_CAMERA_INTERVAL){ /* 区间测速：双环 */
   radius=5;ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,5,mg);ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,3,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);
  }else if(mk[i].kind==TN_CAMERA_SURVEILLANCE){ /* 监控：小环+心点 */
   ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,3,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);
  }else{ /* 其他电子眼：微环 */
   radius=2;ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,2,mg);
  }
  char d[6];unsigned dn=dist3x5(d,mk[i].m);int gap=radius>3?radius+2:5,lx=q.x+gap,ly=q.y-2;
  if(q.x>=136&&q.x<=160&&q.y>=82&&q.y<=111)ly=q.y-13;
  if(lx+(int)dn*4-1>(int)TN_MAP_W-1)lx=q.x-gap-(int)dn*4+1;
  bool valid=lx>=0&&lx+(int)dn*4-1<(int)TN_MAP_W&&ly>=2&&ly+4<(int)TN_MAP_H-1&&!(lx<73&&ly+4>116);
  if(valid&&nt<50&&!label_clash(lx,ly,lx+(int)dn*4-1,ly+4,taken,nt)){
   taken[nt][0]=lx;taken[nt][1]=ly;taken[nt][2]=lx+(int)dn*4-1;taken[nt][3]=ly+4;nt++;text3x5_at(f->map,TN_MAP_W,TN_MAP_H,lx,ly,d,dn,stale?85:200);
  }
  if(nt<51){taken[nt][0]=q.x-radius-1;taken[nt][1]=q.y-radius-1;taken[nt][2]=q.x+radius+1;taken[nt][3]=q.y+radius+1;nt++;}
 }
}
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
static void glyph3x5_2x(uint8_t *p,int w,int h,int x,int y,unsigned g,uint8_t gray){
 for(unsigned dy=0;dy<5;dy++)for(unsigned dx=0;dx<3;dx++)
  if((TN_GLYPH3X5[g][dy]>>(2-dx))&1)for(unsigned sy=0;sy<2;sy++)for(unsigned sx=0;sx<2;sx++)pixel(p,w,h,x+(int)(2*dx+sx),y+(int)(2*dy+sy),0,gray);}
/* Road-section speed limit, always on while the phone reports one (EXT4
 * road_limit). This is the standard circular sign beside the speed readout;
 * the in-map limit circle stays camera-bound and unchanged. 255 = not
 * reported, 0 = section has no limit: both hide the badge. */
/* 超速判定：优先路段限速（EXT4 road_limit），未上报时回落到占槽测速相机的
 * 限速值，两者皆无则不判。常显牌与相机限速圈语义不受影响。 */
static unsigned overspeed_limit(const TNVisual *v){
 if(v->road_limit!=255u&&v->road_limit>0)return v->road_limit;
 if(v->camera_kind==TN_CAMERA_SPEED&&v->camera_limit>0)return (unsigned)v->camera_limit;
 return 0;
}
static bool overspeeding(const TNVisual *v){
 unsigned lim=overspeed_limit(v);
 return lim&&v->speed_kmh!=65535u&&v->speed_kmh>lim;
}
static void badge_draw(TNViewFrame *f,bool invert){
 memset(f->badge,0,sizeof f->badge);unsigned lim=(unsigned)f->visual.road_limit;
 if(lim==255u||lim==0u)return;
 uint8_t gray=f->visual.stale?100:255;
 char num[4];unsigned digits=small_uint(num,lim);
 if(!invert){
  ring(f->badge,TN_BADGE_W,TN_BADGE_H,14,9,9,gray);
  if(digits<=2){int total=(int)digits*8-2,x=14-total/2,y=4;
   for(unsigned i=0;i<digits;i++)glyph3x5_2x(f->badge,TN_BADGE_W,TN_BADGE_H,x+(int)i*8,y,(unsigned)(num[i]-'0'),gray);}
  else{int total=(int)digits*4-1,x=14-total/2,y=6;
   for(unsigned i=0;i<digits;i++)glyph3x5_at(f->badge,TN_BADGE_W,TN_BADGE_H,x+(int)i*4,y,num[i],gray);}
 }else{ /* 超速警报相位：实心圆盘 + 镂空数字，与常显空心限速牌一眼区分 */
  for(int dy=-9;dy<=9;dy++)for(int dx=-9;dx<=9;dx++)if(dx*dx+dy*dy<81)pixel(f->badge,TN_BADGE_W,TN_BADGE_H,14+dx,9+dy,0,gray);
  if(digits<=2){int total=(int)digits*8-2,x=14-total/2,y=4;
   for(unsigned i=0;i<digits;i++)glyph3x5_2x(f->badge,TN_BADGE_W,TN_BADGE_H,x+(int)i*8,y,(unsigned)(num[i]-'0'),0);}
  else{int total=(int)digits*4-1,x=14-total/2,y=6;
   for(unsigned i=0;i<digits;i++)glyph3x5_at(f->badge,TN_BADGE_W,TN_BADGE_H,x+(int)i*4,y,num[i],0);}
 }
}static void draw(TNViewFrame *f){
 memset(f->names,0,sizeof f->names);
 memset(f->icon,0,sizeof f->icon);memset(f->map,0,sizeof f->map);
 TNVisual *v=&f->visual;uint8_t gray=v->stale?100:255;
 for(unsigned i=1;i<v->icon_count;i++)line(f->icon,TN_ICON_W,TN_ICON_H,v->icon[i-1],v->icon[i],1,gray);
 int cx=(v->nav_pos.x-406)*296/112,cy=(v->nav_pos.y-10)*148/112;
 int c=tcos(v->heading),s=tsin(v->heading),rm=25;
 TNXY tp[TN_POINTS_MAX];
 for(unsigned i=0;i<v->route_count;i++){
  int dx=(v->route[i].x-406)*296/112-cx,dy=(v->route[i].y-10)*148/112-cy;
  int rx=(dx*c+dy*s)>>14,ry=(-dx*s+dy*c)>>14;tp[i]=(TNXY){rx,ry};
  if(rx>rm)rm=rx;if(-rx>rm)rm=-rx;if(ry>rm)rm=ry;if(-ry>rm)rm=-ry;
 }
 for(unsigned i=0;i<v->route_count;i++)tp[i]=(TNXY){148+tp[i].x*70/rm,74+tp[i].y*70/rm};
 for(unsigned i=1;i<v->route_count;i++)line(f->map,TN_MAP_W,TN_MAP_H,tp[i-1],tp[i],2,v->stale?60:160);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){148,68},(TNXY){144,76},1,gray);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){148,68},(TNXY){152,76},1,gray);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){144,76},(TNXY){152,76},1,gray);
 badge_draw(f,false);
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
 a->buffer(a->ctx,v->badge,f->badge,TN_BADGE_W,TN_BADGE_H);
 const char *s[]={f->visual.distance,f->visual.turn,f->visual.road,f->visual.summary};
 for(unsigned i=0;i<4;i++)a->text_static(a->ctx,v->text[i],s[i]);
 a->text_static(a->ctx,v->text[5],f->visual.speed);
 if(!v->clock_shown){tn_clock_text(v->clocks[0],0,0,f->visual.stale);
  v->clock_bank=0;v->clock_shown=true;a->text_static(a->ctx,v->text[4],v->clocks[0]);}
 publish_names(v,f);
}
bool tn_view_open(TNView *v,const TNWidgets *a,void *parent,const TNScene *s){
 if(!v||!a||!parent||!a->idle||!a->root||!a->canvas||!a->label||!a->place||!a->buffer||!a->text_static||!a->visible||!a->destroy||!a->idle(a->ctx))return false;
 if(v->root||v->open||v->retiring)return false;
 if(!tn_visual(s,false,&v->frames[0].visual))return false;v->api=*a;v->active=0;v->clock_shown=false;
 v->root=a->root(a->ctx,parent);if(!v->root)return false;a->visible(a->ctx,v->root,false);a->place(a->ctx,v->root,0,0,540,180);
 v->icon=a->canvas(a->ctx,v->root);v->map=a->canvas(a->ctx,v->root);v->badge=a->canvas(a->ctx,v->root);
 static const unsigned sizes[]={32,20,16,16,16,16};
 for(unsigned i=0;i<6;i++)v->text[i]=a->label(a->ctx,v->root,sizes[i]);
 for(unsigned i=0;i<TNR_MAX_LABELS;i++){v->map_text[i]=a->label(a->ctx,v->root,16);if(!v->map_text[i])goto fail;a->visible(a->ctx,v->map_text[i],false);}
 if(!v->icon||!v->map||!v->badge)goto fail;for(unsigned i=0;i<6;i++)if(!v->text[i])goto fail;
 a->place(a->ctx,v->icon,12,12,TN_ICON_W,TN_ICON_H);a->place(a->ctx,v->map,238,4,TN_MAP_W,TN_MAP_H);
 a->place(a->ctx,v->badge,148,44,TN_BADGE_W,TN_BADGE_H);
 a->place(a->ctx,v->text[0],84,10,138,34);a->place(a->ctx,v->text[5],86,48,120,20);
 a->place(a->ctx,v->text[1],12,82,210,24);
 a->place(a->ctx,v->text[2],12,110,210,20);a->place(a->ctx,v->text[3],12,134,210,18);
 a->place(a->ctx,v->text[4],12,158,516,18);
 draw(&v->frames[0]);publish(v,&v->frames[0]);v->badge_shown=0;v->open=true;a->visible(a->ctx,v->root,true);return true;
 fail:a->destroy(a->ctx,v->root);v->root=v->icon=v->map=NULL;memset(v->text,0,sizeof v->text);return false;
}
bool tn_view_update(TNView *v,const TNScene *s,bool stale){
 if(!v||!v->open||v->retiring||!v->api.idle(v->api.ctx))return false;
 unsigned next=v->active^1u;TNViewFrame *f=&v->frames[next];
 if(!tn_visual(s,stale,&f->visual))return false;draw(f);
 if(v->map_state.valid){tnr_draw(&v->map_state,v->map_now,f->map);map_congestion(f,&v->map_state,v->map_now);map_markers(f,&v->map_state,v->map_now);}
 publish(v,f);v->badge_half=0;v->badge_shown=(uint8_t)next;v->active=next;return true; /* 整帧重绘回到常显相位 */
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
 if(!tnr_receive(&v->map_state,op,body,n,now))return false;
 (void)tn_view_map_tick(v,now);return true;
}
bool tn_view_map_tick(TNView *v,uint32_t now){
 if(!v||!v->open||v->retiring)return false;v->map_now=now;
 /* 超速警报：1Hz 双相闪烁（空心常显牌 ↔ 实心圆盘），就地重写 widget 当前
  * 挂载帧（badge_shown）的徽章缓冲并重推同一指针，与矢量图双缓冲翻转无关。
  * 渲染忙时跳过本拍。 */
 if(v->api.idle(v->api.ctx)){
  const TNVisual *vis=&v->frames[v->badge_shown].visual;
  unsigned want=overspeeding(vis)?(now/500u)%2u+1u:0u;
  if(v->badge_half!=want){v->badge_half=(uint8_t)want;TNViewFrame *bf=&v->frames[v->badge_shown];badge_draw(bf,want==2u);v->api.buffer(v->api.ctx,v->badge,bf->badge,TN_BADGE_W,TN_BADGE_H);}
 }
 if(!tnr_needs_draw(&v->map_state,now))return true;
 if(!v->api.idle(v->api.ctx))return false;
 unsigned next=v->active^1u;TNViewFrame *f=&v->frames[next];
 f->visual=v->frames[v->active].visual;
 if(v->map_state.valid){tnr_draw(&v->map_state,now,f->map);map_congestion(f,&v->map_state,now);map_markers(f,&v->map_state,now);}else draw(f);
 v->api.buffer(v->api.ctx,v->map,f->map,TN_MAP_W,TN_MAP_H);publish_names(v,f);v->active=next;tnr_presented(&v->map_state,now);return true;
}
