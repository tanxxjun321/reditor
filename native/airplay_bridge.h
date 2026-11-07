/*
 * airplay_bridge.h — C API bridging REditor (.NET) to the UxPlay AirPlay
 * receiver core (GPLv3) + GStreamer rendering pipeline.
 *
 * All functions are thread-safe to call from the .NET UI thread unless
 * noted. The event callback may fire on ANY thread — marshal to the UI
 * thread on the managed side.
 */
#ifndef AIRPLAY_BRIDGE_H
#define AIRPLAY_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ap_event_e {
    AP_EV_WAITING = 0,       /* server started, waiting for a client          */
    AP_EV_CONNECTED = 1,     /* client connected; info = device name          */
    AP_EV_DISCONNECTED = 2,  /* last client disconnected                      */
    AP_EV_VIDEO_SIZE = 3,    /* stream geometry known; width/height set       */
    AP_EV_LOG = 4,           /* log line from the native layer; info = text   */
    AP_EV_ERROR = 5,         /* recoverable error; info = description         */
    AP_EV_STOPPED = 6        /* server fully stopped                          */
} ap_event_t;

typedef void (*ap_event_cb)(void *ctx, ap_event_t event, const char *info,
                            int width, int height);

/*
 * Start the AirPlay receiver. server_name is the name shown in the iPhone's
 * Screen Mirroring list (NULL -> "REditor"). Returns 0 on success.
 */
int  airplay_start(const char *server_name, ap_event_cb cb, void *ctx);

/* Stop the receiver and free all resources. Safe to call more than once. */
void airplay_stop(void);

/*
 * Create / release the NSView that hosts the video. Must be paired:
 * the returned pointer is retained and ownership passes to the caller.
 * airplay_release_video_view releases it (on the main thread).
 */
void *airplay_create_video_view(void);
void  airplay_release_video_view(void *view);

/*
 * Hand the NSView to the video pipeline. May be called before or after
 * airplay_start; the handle is applied when the pipeline asks for a window.
 */
void  airplay_set_video_view(void *view);

/* App-side gain multiplier, 0.0 .. 3.0 (1.0 = keep the client's volume). */
void  airplay_set_volume(double volume);

#ifdef __cplusplus
}
#endif

#endif /* AIRPLAY_BRIDGE_H */
