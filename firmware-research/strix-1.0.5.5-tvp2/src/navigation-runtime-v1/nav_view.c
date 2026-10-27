#include "nav_view.h"
#include <string.h>
static int mag(int v){return v<0?-v:v;}
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
/* --- HUD panel primitives (carried from the TNV1 1.0.4.12 line) --- */
static void rect(uint8_t *p,int w,int h,int x0,int y0,int x1,int y1,uint8_t gray){
 for(int yy=y0;yy<y1;yy++)for(int xx=x0;xx<x1;xx++)
 if(xx>=0&&xx<w&&yy>=0&&yy<h)p[(unsigned)yy*(unsigned)w+(unsigned)xx]=gray;
}
/* 1 px rounded outline: straight edges plus quarter-circle corner arcs. */
static void frame(uint8_t *p,int w,int h,int x0,int y0,int x1,int y1,int r,uint8_t gray){
 static const int8_t qx[4]={-1,1,-1,1},qy[4]={-1,-1,1,1}; /* i&1 picks x side, i&2 picks y side */
 for(int x=x0+r;x<=x1-r;x++){pixel(p,w,h,x,y0,0,gray);pixel(p,w,h,x,y1,0,gray);}
 for(int y=y0+r;y<=y1-r;y++){pixel(p,w,h,x0,y,0,gray);pixel(p,w,h,x1,y,0,gray);}
 for(int i=0;i<4;i++){int cx=i&1?x1-r:x0+r,cy=i&2?y1-r:y0+r;
  for(int dy=0;dy<=r;dy++)for(int dx=0;dx<=r;dx++){int d=dx*dx+dy*dy;
   if(d>=r*r-r&&d<=r*r+r)pixel(p,w,h,cx+qx[i]*dx,cy+qy[i]*dy,0,gray);}}
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
 unsigned g=c>='0'&&c<='9'?(unsigned)(c-'0'):c=='.'?10u:c=='k'?11u:c=='m'?12u:(unsigned char)c==0xD7?13u:(unsigned char)c==0xB7?10u:12u; /* 0xD7=× 0xB7=·, bar labels are bytes not UTF-8 */
 for(int dy=0;dy<5;dy++)for(int dx=0;dx<3;dx++)
  if((TN_GLYPH3X5[g][dy]>>(2-dx))&1)pixel(p,w,h,x+dx,y+dy,0,gray);
}
static void glyph3x5(TNViewFrame *f,int x,int y,char c,uint8_t gray){glyph3x5_at(f->bar,TN_BAR_W,TN_BAR_H,x,y,c,gray);}
static void text3x5_at(uint8_t *p,int w,int h,int x,int y,const char *s,unsigned n,uint8_t gray){
 for(unsigned i=0;i<n;i++)glyph3x5_at(p,w,h,x+(int)i*4,y,s[i],gray);
}
static void text3x5(TNViewFrame *f,int x,int y,const char *s,unsigned n,uint8_t gray){text3x5_at(f->bar,TN_BAR_W,TN_BAR_H,x,y,s,n,gray);}
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
/* Vector-map overlay (Turbo IO): the camera, the road event and the traffic
 * lights ride the heading-up TNR map as compact glyphs on the straight-ahead
 * ray, each carrying its 3x5 distance label. TNV1 carries distances, not
 * bearings, so the heading ray is the honest placement. Labels keep clear of
 * each other, the vehicle triangle and the bottom-left scale block; markers
 * beyond the scene viewport drop off the top like real geography would. */
static bool label_clash(int x0,int y0,int x1,int y1,const int taken[][4],unsigned n){
 for(unsigned i=0;i<n;i++)if(x0<=taken[i][2]&&x1>=taken[i][0]&&y0<=taken[i][3]&&y1>=taken[i][1])return true;
 return false;
}
static void map_markers(TNViewFrame *f,const TNRState *s,uint32_t now){
 TNRPose p;if(!s||!tnr_position(s,now,&p))return;
 bool stale=tnr_stale(s,now);uint8_t mg=stale?90:180;
 struct MK{uint16_t m;int16_t limit;char kind;}mk[10];unsigned n=0;
 if(f->visual.camera_kind&&f->visual.camera_m!=65535){mk[n].m=f->visual.camera_m;mk[n].limit=f->visual.camera_limit;mk[n].kind='c';n++;}
 if(f->visual.event_kind&&f->visual.event_m!=65535){mk[n].m=f->visual.event_m;mk[n].limit=0;mk[n].kind='e';n++;}
 if(!f->visual.light_count&&f->visual.lights!=255&&f->visual.lights_m!=65535){mk[n].m=f->visual.lights_m;mk[n].limit=0;mk[n].kind='l';n++;}
 for(unsigned i=0;i<f->visual.light_count&&n<10;i++){mk[n].m=f->visual.light_m[i];mk[n].limit=0;mk[n].kind='l';n++;}
 int taken[10][4];unsigned nt=0;
 for(unsigned i=0;i<n;i++){
  if(mk[i].m>700u)continue; /* beyond the scene viewport */
  TNRPoint q=tnr_ahead(s,&p,mk[i].m);
  if(mk[i].kind=='c'){ /* camera: ring + centre dot */
   ring(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,3,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);
  }else if(mk[i].kind=='e'){ /* event: triangle over its base */
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x,q.y-4},(TNXY){q.x-4,q.y+3},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x,q.y-4},(TNXY){q.x+4,q.y+3},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-4,q.y+3},(TNXY){q.x+4,q.y+3},0,mg);
   pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,mg);
  }else{ /* light: 3-wide lamp housing, three lit tiers */
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-1,q.y-4},(TNXY){q.x+1,q.y-4},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-2,q.y-3},(TNXY){q.x-2,q.y+2},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x+2,q.y-3},(TNXY){q.x+2,q.y+2},0,mg);
   line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){q.x-1,q.y+3},(TNXY){q.x+1,q.y+3},0,mg);
   pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y-2,0,mg);pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y,0,(uint8_t)(mg*2/3));pixel(f->map,TN_MAP_W,TN_MAP_H,q.x,q.y+2,0,(uint8_t)(mg/3));
  }
  char d[6];unsigned dn=dist3x5(d,mk[i].m);
  int lx=q.x+5,ly=q.y-2;
  if(q.x>=84&&q.x<=108&&q.y>=82&&q.y<=111)ly=q.y-11; /* clear of the vehicle triangle */
  if(lx<0||(lx+(int)dn*4-1)>(int)TN_MAP_W-1||ly<2||(ly+4)>(int)TN_MAP_H-2)continue;
  if(lx<71&&ly+4>116)continue; /* scale block owns the bottom-left corner */
  if(label_clash(lx,ly,lx+(int)dn*4-1,ly+4,taken,nt))continue;
  taken[nt][0]=lx;taken[nt][1]=ly;taken[nt][2]=lx+(int)dn*4-1;taken[nt][3]=ly+4;nt++;
  text3x5_at(f->map,TN_MAP_W,TN_MAP_H,lx,ly,d,dn,stale?85:200);
 }
}
#define TN_BAR_BASE ((int)TN_BAR_H-10) /* columns sit on this row; km ticks and scale digits drop below */
static int anchor(unsigned m){return 8+(int)(m>5000?5000:m)*(int)(TN_BAR_W-16u)/5000;}
static void marker(TNViewFrame *f,int x,uint8_t gray,bool round){
 uint8_t stem=(uint8_t)(gray>>1);
 if(round){ring(f->bar,TN_BAR_W,TN_BAR_H,x,10,4,gray);pixel(f->bar,TN_BAR_W,TN_BAR_H,x,10,0,gray);}
 else{line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x,7},(TNXY){x-4,13},0,gray);
  line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x,7},(TNXY){x+4,13},0,gray);
  line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x-4,13},(TNXY){x+4,13},0,gray);
  line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x,8},(TNXY){x,12},0,gray);} /* "!" rides the base line */
 line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x,14},(TNXY){x,TN_BAR_BASE-1},0,stem);
}
/* Traffic-light marker: 5x9 vertical lamp housing with three lit tiers. */
static void light(TNViewFrame *f,int x,uint8_t gray){
 line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x-1,5},(TNXY){x+1,5},0,gray);
 line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x-2,6},(TNXY){x-2,12},0,gray);
 line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x+2,6},(TNXY){x+2,12},0,gray);
 line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x-1,13},(TNXY){x+1,13},0,gray);
 pixel(f->bar,TN_BAR_W,TN_BAR_H,x,7,0,gray);
 pixel(f->bar,TN_BAR_W,TN_BAR_H,x,9,0,(uint8_t)(gray*2/3));
 pixel(f->bar,TN_BAR_W,TN_BAR_H,x,11,0,(uint8_t)(gray/3));
 line(f->bar,TN_BAR_W,TN_BAR_H,(TNXY){x,14},(TNXY){x,TN_BAR_BASE-1},0,(uint8_t)(gray>>1));
}
static void draw(TNViewFrame *f){
 memset(f->names,0,sizeof f->names);
 memset(f->icon,0,sizeof f->icon);memset(f->map,0,sizeof f->map);memset(f->bar,0,sizeof f->bar);
 TNVisual *v=&f->visual;uint8_t gray=v->stale?100:255,shift=v->stale?1:0;
 for(unsigned i=1;i<v->icon_count;i++){
  TNXY a=v->icon[i-1],b=v->icon[i];a.x-=8;a.y-=12;b.x-=8;b.y-=12;
  line(f->icon,TN_ICON_W,TN_ICON_H,a,b,2,gray);
 }
 /* Orientation: fixed heading-up (2026-10-26 真机拍板). The hybrid north-up
  * fallback read badly in practice; the route now always rotates about the
  * car pivot. The TNR3 vector map owns the canvas when one is active
  * (callers overlay tnr_draw + traffic markers); this fallback keeps the
  * semantic route readable meanwhile. */
 int cx=(v->nav_pos.x-400)*192/128,cy=(v->nav_pos.y-4)*144/128;
 int c=tcos(v->heading),s=tsin(v->heading),rm=25;
 TNXY tp[TN_POINTS_MAX];
 for(unsigned i=0;i<v->route_count;i++){
  int dx=(v->route[i].x-400)*192/128-cx,dy=(v->route[i].y-4)*144/128-cy;
  int rx=(dx*c+dy*s)>>14,ry=(-dx*s+dy*c)>>14;tp[i]=(TNXY){rx,ry};
  if(rx>rm)rm=rx;if(-rx>rm)rm=-rx;if(ry>rm)rm=ry;if(-ry>rm)rm=-ry;
 }
 for(unsigned i=0;i<v->route_count;i++)tp[i]=(TNXY){96+tp[i].x*64/rm,72+tp[i].y*64/rm};
 for(unsigned i=1;i<v->route_count;i++)
  line(f->map,TN_MAP_W,TN_MAP_H,tp[i-1],tp[i],2,v->stale?60:160);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){96,66},(TNXY){92,74},1,gray);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){96,66},(TNXY){100,74},1,gray);
 line(f->map,TN_MAP_W,TN_MAP_H,(TNXY){92,74},(TNXY){100,74},1,gray);
 /* Traffic bar chart: per-segment columns encode congestion in both height
  * and brightness (severe adds a dark hatch), over a 1 px baseline with
  * whole-kilometre ticks and 3x5 scale digits, all inside a rounded panel.
  * Camera/event markers anchor on a fixed 5 km window; each marker carries a
  * 3x5 label in the free strip above the columns, so distances need no text
  * line and can never overflow the way a 16 px label would. */
 frame(f->bar,TN_BAR_W,TN_BAR_H,0,0,TN_BAR_W-1,TN_BAR_H-1,8,(uint8_t)(40>>shift));
 rect(f->bar,TN_BAR_W,TN_BAR_H,0,TN_BAR_BASE,TN_BAR_W,TN_BAR_BASE+1,(uint8_t)(48>>shift));
 static const uint8_t congestion[5]={0,168,198,226,255},height[5]={0,4,7,10,13}; /* 真机反馈畅通档(112)亮度不可见，整体提亮并拉开档差 */
 for(unsigned i=0;i<v->bar_count&&i<TN_BAR_MAX;i++){
  if(!v->bar[i]||v->bar[i]>4)continue;
  int x0=(int)(4u+i*(TN_BAR_W-8u)/TN_BAR_MAX),x1=(int)(4u+(i+1u)*(TN_BAR_W-8u)/TN_BAR_MAX);
  if(x1<=x0)x1=x0+1;
  int top=TN_BAR_BASE-height[v->bar[i]];
  rect(f->bar,TN_BAR_W,TN_BAR_H,x0,top,x1-1,TN_BAR_BASE,(uint8_t)(congestion[v->bar[i]]>>shift));
  if(v->bar[i]==4)for(int y=top;y<TN_BAR_BASE;y++)for(int x=x0;x<x1-1;x++)
   if(((x-y)&3)==0)pixel(f->bar,TN_BAR_W,TN_BAR_H,x,y,0,(uint8_t)(40>>shift));
 }
 for(unsigned km=0;km<=5;km++){int x=(int)(4u+km*(TN_BAR_W-8u)/5u);
  for(int y=TN_BAR_BASE+1;y<=TN_BAR_BASE+3;y++)pixel(f->bar,TN_BAR_W,TN_BAR_H,x,y,0,(uint8_t)(70>>shift));
  glyph3x5(f,x-1,TN_BAR_BASE+4,(char)('0'+km),(uint8_t)(90>>shift));}
 uint8_t mg=v->stale?100:200;
 int occ[3][2];unsigned nocc=0; /* occupied label spans in the top strip (rows 0..4) */
 int cm=0,em=-100; /* co-located markers nudge sideways instead of stacking */
 if(v->camera_kind&&v->camera_m!=65535){
  cm=anchor(v->camera_m);
  marker(f,cm,mg,true);
  char d[6];unsigned n=dist3x5(d,v->camera_m);
  int lx=cm+5;if(lx+(int)n*4-1>(int)TN_BAR_W-2)lx=cm-3-(int)n*4;
  if(lx>=0){occ[nocc][0]=lx;occ[nocc][1]=lx+(int)n*4-1;nocc++;text3x5(f,lx,0,d,n,mg);}
  if(v->camera_limit>0){ /* speed limit sits inside the ring, 3x5 digits */
   int lim=v->camera_limit>999?999:v->camera_limit;uint8_t dd[3];unsigned nd=0;
   do{dd[nd++]=(uint8_t)(lim%10);lim/=10;}while(lim);
   int dx0=cm-(int)(nd*4-1)/2;
   for(unsigned k=0;k<nd;k++)glyph3x5(f,dx0+(int)k*4,8,(char)('0'+dd[nd-1-k]),mg);
  }
 }
 if(v->event_kind&&v->event_m!=65535){
  int mx=anchor(v->event_m);
  if(v->camera_kind&&v->camera_m!=65535&&mx>cm-10&&mx<cm+10)mx=cm+11<(int)TN_BAR_W-4?cm+11:cm-11;
  em=mx;
  marker(f,mx,mg,false);
  char d[6];unsigned n=dist3x5(d,v->event_m);
  int lx=mx+6,lr=lx+(int)n*4-1; /* triangle label prefers the east side */
  bool clash=lr>(int)TN_BAR_W-2;
  for(unsigned k=0;k<nocc;k++)clash|=lx<=occ[k][1]&&lr>=occ[k][0];
  if(clash){lx=mx-4-(int)n*4;lr=lx+(int)n*4-1;clash=lx<2;
   for(unsigned k=0;k<nocc;k++)clash|=lx<=occ[k][1]&&lr>=occ[k][0];}
  if(!clash){occ[nocc][0]=lx;occ[nocc][1]=lr;nocc++;text3x5(f,lx,0,d,n,mg);}
 }
 unsigned nl=v->light_count;if(nl>8)nl=8;
 if(!nl&&v->lights!=255&&v->lights_m!=65535)nl=1; /* legacy phone: single nearest light */
 int lm[8];
 for(unsigned i=0;i<nl;i++){ /* one housing per light, staggered by its own distance */
  int mx=anchor(v->light_count?v->light_m[i]:v->lights_m);
  if(v->camera_kind&&v->camera_m!=65535&&mx>cm-10&&mx<cm+10)mx=cm+11<(int)TN_BAR_W-4?cm+11:cm-11;
  if(v->event_kind&&v->event_m!=65535&&mx>em-10&&mx<em+10)mx=em+11<(int)TN_BAR_W-4?em+11:em-11;
  for(unsigned j=0;j<i;j++)if(mx>lm[j]-8&&mx<lm[j]+8)mx=lm[j]+11<(int)TN_BAR_W-4?lm[j]+11:lm[j]-11;
  lm[i]=(int)mx;
  light(f,mx,mg);
  char d[6];unsigned n=dist3x5(d,v->light_count?v->light_m[i]:v->lights_m);
  int lx=mx+5,lr=lx+(int)n*4-1; /* lamp label tries east first, then west */
  bool clash=lr>(int)TN_BAR_W-2;
  for(unsigned k=0;k<nocc;k++)clash|=lx<=occ[k][1]&&lr>=occ[k][0];
  if(clash){lx=mx-3-(int)n*4;lr=lx+(int)n*4-1;clash=lx<0;
   for(unsigned k=0;k<nocc;k++)clash|=lx<=occ[k][1]&&lr>=occ[k][0];}
  if(!clash)text3x5(f,lx,0,d,n,mg);
 }
}
static void publish_names(TNView *v,TNViewFrame *f){
 TNWidgets *a=&v->api;
 (void)tnr_labels(&v->map_state,v->map_now,f->names);
 for(unsigned i=0;i<TNR_MAX_LABELS;i++){TNRLabelView *n=&f->names[i];
  if(n->width){a->place(a->ctx,v->map_text[i],340+n->x,4+n->y,n->width,20);a->text_static(a->ctx,v->map_text[i],n->text);}
  a->visible(a->ctx,v->map_text[i],n->width!=0);
 }
}
static void publish(TNView *v,TNViewFrame *f){
 TNWidgets *a=&v->api;
 a->buffer(a->ctx,v->icon,f->icon,TN_ICON_W,TN_ICON_H);
 a->buffer(a->ctx,v->map,f->map,TN_MAP_W,TN_MAP_H);
 a->buffer(a->ctx,v->bar,f->bar,TN_BAR_W,TN_BAR_H);
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
 v->icon=a->canvas(a->ctx,v->root);v->map=a->canvas(a->ctx,v->root);v->bar=a->canvas(a->ctx,v->root);
 static const unsigned sizes[]={32,20,18,16,16,20}; /* text[5]=speed readout */
 for(unsigned i=0;i<6;i++)v->text[i]=a->label(a->ctx,v->root,sizes[i]);
 for(unsigned i=0;i<TNR_MAX_LABELS;i++){v->map_text[i]=a->label(a->ctx,v->root,16);if(!v->map_text[i])goto fail;a->visible(a->ctx,v->map_text[i],false);}
 if(!v->icon||!v->map||!v->bar)goto fail;for(unsigned i=0;i<6;i++)if(!v->text[i])goto fail;
 a->place(a->ctx,v->icon,8,12,TN_ICON_W,TN_ICON_H);a->place(a->ctx,v->map,340,4,TN_MAP_W,TN_MAP_H);
 /* Left column tightened by 2-4px per row vs upstream so the 280x40 traffic
  * bar fits at y110..150 above the clock footer; fonts stay <= box heights. */
 a->place(a->ctx,v->text[0],112,4,220,40);a->place(a->ctx,v->text[5],240,4,100,40); /* distance left, speed+km/h right */
 a->place(a->ctx,v->text[1],112,44,220,24);
 a->place(a->ctx,v->text[2],112,68,220,22);a->place(a->ctx,v->text[3],112,90,220,20);
 a->place(a->ctx,v->bar,112,110,TN_BAR_W,TN_BAR_H);
 a->place(a->ctx,v->text[4],8,150,524,26);
 draw(&v->frames[0]);publish(v,&v->frames[0]);v->open=true;a->visible(a->ctx,v->root,true);return true;
 fail:a->destroy(a->ctx,v->root);v->root=v->icon=v->map=v->bar=NULL;memset(v->text,0,sizeof v->text);return false;
}
bool tn_view_update(TNView *v,const TNScene *s,bool stale){
 if(!v||!v->open||v->retiring||!v->api.idle(v->api.ctx))return false;
 unsigned next=v->active^1u;TNViewFrame *f=&v->frames[next];
 if(!tn_visual(s,stale,&f->visual))return false;draw(f);if(v->map_state.valid){tnr_draw(&v->map_state,v->map_now,f->map);map_markers(f,&v->map_state,v->map_now);}publish(v,f);v->active=next;return true;
}
bool tn_view_close(TNView *v){
 if(!v)return false;if(!v->root)return true;
 v->retiring=true;v->open=false;v->api.visible(v->api.ctx,v->root,false);
 if(!v->api.idle(v->api.ctx))return false;v->api.destroy(v->api.ctx,v->root);
 v->root=v->icon=v->map=v->bar=NULL;memset(v->text,0,sizeof v->text);v->retiring=false;return true;
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
 /* Map ticks do not need to copy/repaint the 16 KiB arrow or semantic text.
  * Retained text pointers stay valid until a full semantic publish. */
 f->visual=v->frames[v->active].visual;
 if(v->map_state.valid){tnr_draw(&v->map_state,now,f->map);map_markers(f,&v->map_state,now);}else draw(f);v->api.buffer(v->api.ctx,v->map,f->map,TN_MAP_W,TN_MAP_H);publish_names(v,f);v->active=next;tnr_presented(&v->map_state,now);return true;
}
