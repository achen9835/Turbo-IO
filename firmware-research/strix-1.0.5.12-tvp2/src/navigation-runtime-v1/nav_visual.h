#ifndef TURBO_NAV_VISUAL_H
#define TURBO_NAV_VISUAL_H
#include "nav_runtime.h"
/* Stable storage owned by a page; LVGL line point references must not point to
 * a stack temporary. Two visual slots permit idle-checked swap by the adapter. */
typedef struct {int32_t x,y;} TNXY;
typedef struct {
 TNXY icon[32],route[TN_POINTS_MAX],position[4]; /* icon 32：设施 pictogram 多笔画+抬笔哨兵最长 30 点 */
 unsigned icon_count,route_count;
 char distance[24],turn[TN_TURN_MAX+1],road[TN_ROAD_MAX+1],summary[48],status[64];
 bool stale;
 /* HUD extension (Turbo IO): heading + canvas-space car pivot drive the
  * hybrid heading-up map; the rest mirrors the scene tail for the traffic
  * bar panel. Absent tail fields keep their neutral values (bar empty,
  * speeds 65535, empty speed text). */
 unsigned heading;TNXY nav_pos;
 unsigned icon_kind; /* enum TNIcon of the current turn glyph (hybrid map orientation) */
 uint8_t bar_count;uint8_t bar[TN_BAR_MAX];
 uint8_t lights,light_count,camera_kind,event_kind;
 int16_t camera_limit;uint16_t camera_m,event_m,lights_m,light_m[8],speed_kmh;
 uint8_t road_limit; /* 255 = not reported, 0 = no speed limit, else km/h */
 uint8_t cam_count,cam_kind[TN_CAM_MAX],cam_limit[TN_CAM_MAX];uint16_t cam_m[TN_CAM_MAX];
 uint8_t fac_count,fac_kind[TN_FAC_MAX];uint16_t fac_m[TN_FAC_MAX];
 char speed[8];
} TNVisual;
bool tn_visual(const TNScene *,bool stale,TNVisual *);
/* local epoch is the already timezone-adjusted native system clock. ETA is
 * anchored at the last accepted scene, never advanced by a heartbeat. */
void tn_clock_text(char out[64],int64_t local_epoch,int64_t eta_epoch,bool stale);
#endif
