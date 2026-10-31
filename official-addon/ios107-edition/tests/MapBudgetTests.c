/* Host test for the phone-side scene-budget helper in nav_map.c.
 * Pure C: runs where the macOS ObjC groups cannot (gcc/clang, no Foundation),
 * so the route-decimation budget can be verified without a device or Xcode.
 *
 *   cc -O2 -std=c99 -I.. nav_map.c nav_runtime.c tests/MapBudgetTests.c -o MapBudgetTests
 *   ./MapBudgetTests
 *
 * Covers the three properties the lens depends on: (1) a clipped, dense AMap
 * route is reduced into the TNR_MAX_POINTS budget without losing its endpoints
 * or its bends; (2) long decimated chords are densified again so the firmware
 * int32 projection (tnr_route_base_qm) cannot overflow; (3) the result still
 * encodes as a valid TNR scene whose style==6 route starts behind the vehicle,
 * so the route-ahead marker is projected in front of it. */
#include "nav_map.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void w16(uint8_t *p,unsigned v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void w32(uint8_t *p,uint32_t v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);p[2]=(uint8_t)(v>>16);p[3]=(uint8_t)(v>>24);}
static int same(TNRPoint a,TNRPoint b){return a.x==b.x&&a.y==b.y;}
static unsigned len_qm(TNRPoint a,TNRPoint b){int x=b.x-a.x,y=b.y-a.y;if(x<0)x=-x;if(y<0)y=-y;return (unsigned)((x>y?x:y)+(x>y?y:x)/2);}

/* Dense east-then-north route with a sharp corner and +/-1 quarter-metre jitter:
 * 2000 points, more than the 512-point route slice the scene reserves. */
static unsigned route_pts(TNRPoint *p,unsigned n){
 unsigned corner=n/2;
 for(unsigned i=0;i<n;i++){
  if(i<corner){p[i].x=(int16_t)(i*2);p[i].y=(int16_t)((int)(i%3)-1);}
  else{p[i].x=(int16_t)(corner*2+((int)(i%3)-1));p[i].y=(int16_t)((i-corner)*2);}
 }
 return corner;
}
static size_t scene_body(uint8_t *out,const TNRPoint *p,unsigned n,unsigned range){
 size_t len=16u+8u+4u*n;memset(out,0,len);
 w32(out,1);w16(out+4,range);w16(out+6,1);w16(out+8,n);w16(out+10,0);
 w16(out+16,n);out[18]=6;
 for(unsigned i=0;i<n;i++){w16(out+24+4*i,(unsigned)(uint16_t)p[i].x);w16(out+26+4*i,(unsigned)(uint16_t)p[i].y);}
 return len;
}
/* Squared distance from q to the original polyline (shape-preservation check). */
static double dist2_poly(TNRPoint q,const TNRPoint *p,unsigned n){
 double best=1e18;
 for(unsigned i=1;i<n;i++){
  double ax=p[i-1].x,ay=p[i-1].y,bx=p[i].x,by=p[i].y,dx=bx-ax,dy=by-ay,den=dx*dx+dy*dy,t=den?((q.x-ax)*dx+(q.y-ay)*dy)/den:0;
  if(t<0)t=0;if(t>1)t=1;double ex=q.x-(ax+dx*t),ey=q.y-(ay+dy*t),d=ex*ex+ey*ey;if(d<best)best=d;
 }
 return best;
}

int main(void){
 TNRPoint in[2048],out[2048],copy[2048];
 unsigned n=2000,corner=route_pts(in,n);
 memcpy(copy,in,sizeof in);

 /* 1. Dense >512 route is reduced into the reserved slice: endpoints and the
  *    junction bend survive, shape stays within a couple of metres of the
  *    original vertices, and straight chords are densified for int32 safety. */
 unsigned kept=tnr_path_budget(in,n,512);
 assert(kept>=2&&kept<=512);
 assert(same(in[0],copy[0])&&same(in[kept-1],copy[n-1]));
 int has_corner=0;
 for(unsigned i=0;i<kept;i++)if(same(in[i],copy[corner]))has_corner=1;
 assert(has_corner); /* a stride sampler would drop the junction bend */
 for(unsigned i=0;i<kept;i++)assert(dist2_poly(in[i],copy,n)<=24*24); /* <=6 m */
 for(unsigned i=1;i<kept;i++)assert(len_qm(in[i-1],in[i])<=512+4); /* firmware int32 bound */

 /* 2. Small paths keep their endpoints; the cap floor is two points. */
 memcpy(out,copy,sizeof out);
 unsigned small=tnr_path_budget(out,100,512);
 assert(small>=2&&small<=512&&same(out[0],copy[0])&&same(out[small-1],copy[99]));
 memcpy(out,copy,sizeof out);
 unsigned two=tnr_path_budget(out,1000,2);
 assert(two==2&&same(out[0],copy[0])&&same(out[1],copy[999]));

 /* 3. The same route also fits the full 768-point scene budget (route slice
  *    plus background) and keeps the junction bend. */
 {TNRPoint wide[2048];memcpy(wide,copy,sizeof wide);
  unsigned wk=tnr_path_budget(wide,n,768);
  assert(wk>=2&&wk<=768);assert(same(wide[0],copy[0])&&same(wide[wk-1],copy[n-1]));
  int bend=0;for(unsigned i=0;i<wk;i++)if(same(wide[i],copy[corner]))bend=1;assert(bend);
  for(unsigned i=1;i<wk;i++)assert(len_qm(wide[i-1],wide[i])<=512+4);
 }

 /* 4. The reduced route encodes as a valid scene. A route starting behind the
  *    vehicle reports a negative arc base (marker ahead); the densified chord
  *    must keep tnr_route_base_qm() away from its int32 overflow/0 fallback. */
 {TNRPoint route[512]={{-3000,0},{-2000,0},{-1000,0},{0,0},{500,0},{1000,0}}; /* buffer must hold cap: densify can grow */
  unsigned rn=6,rk=tnr_path_budget(route,rn,512);
  assert(rk>=2&&rk<=512&&same(route[0],(TNRPoint){-3000,0})&&same(route[rk-1],(TNRPoint){1000,0}));
  for(unsigned i=1;i<rk;i++)assert(len_qm(route[i-1],route[i])<=512+4);
  uint8_t body[TNR_MAX_BYTES];
  size_t len=scene_body(body,route,rk,520);
  assert(tnr_body_valid(TNR_SCENE,body,len));
  TNRState state={0};assert(tnr_receive(&state,TNR_SCENE,body,len,0));
  uint8_t pose[12]={0};w32(pose,1);w16(pose+4,0);w16(pose+6,0);w16(pose+8,90);w16(pose+10,0);
  assert(tnr_receive(&state,TNR_POSE,pose,12,0));
  TNRPose at;assert(tnr_position(&state,0,&at));
  const TNRScene *d=&state.scenes[state.bank];
  assert(d->path_count==1&&d->paths[0].style==6);
  int32_t base=tnr_route_base_qm(&state,&at,&d->paths[0]);
  assert(base<0); /* route begins 750 m behind the vehicle */
  TNRPoint ahead=tnr_route_ahead(&state,&at,100); /* 100 m stays on the 520 m canvas */
  assert(ahead.x>=0&&ahead.x<=295&&ahead.y>=0&&ahead.y<=147);
 }

 puts("PASS route budget: dense >512 route in budget with endpoints+bend kept; long chords densified (span<=128 m) so int32 base stays negative; valid scene");
 return 0;
}
