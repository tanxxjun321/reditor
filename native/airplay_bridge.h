/*
 * airplay_bridge.h — C API bridging AirMirror (.NET) to the UxPlay AirPlay
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
 * Screen Mirroring list (NULL -> "AirMirror"). Returns 0 on success.
 */
int  airplay_start(const char *server_name, ap_event_cb cb, void *ctx);

/* Stop the receiver and free all resources. Safe to call more than once. */
void airplay_stop(void);

/*
 * Embed the video view into the Avalonia window (pass its NSWindow*), placed
 * BELOW Avalonia's own view so the managed overlay chrome renders above the
 * video. The window's contentView is swapped for a plain container: video
 * view at the bottom (its black layer doubles as the window backdrop and the
 * sink letterboxes inside it), Avalonia's view back on top. Requires
 * TransparencyLevelHint="Transparent" so Avalonia renders with alpha and the
 * video shows through; the window is flipped back to opaque inside (the
 * video view covers the whole content area), which keeps the
 * pre-transparency title bar behavior.
 * Returns the retained video view; pass it to airplay_detach_video_view
 * before the window closes.
 */
void *airplay_attach_video_view(void *nswindow);
void  airplay_detach_video_view(void *view);

/*
 * Re-assert the transparent-window chrome fixes (opaque window, Avalonia's
 * title bar backdrop hidden) after macOS undoes them on fullscreen exit.
 * Call from the UI thread once the window has settled back to normal.
 */
void  airplay_window_chrome_fixup(void *nswindow);

/* App-side gain multiplier, 0.0 .. 3.0 (1.0 = keep the client's volume). */
void  airplay_set_volume(double volume);

/*
 * Client access password (UxPlay's native RFC2617 digest auth): when set,
 * iOS prompts for it before mirroring starts. Empty/NULL disables. May be
 * called any time — it takes effect for NEW connections, the current
 * session is unaffected (no restart needed).
 */
void  airplay_set_password(const char *password);

/*
 * Cumulative mirror-stream counters: frames = video packets fed to the
 * decoder, bytes = their payload size. Reset at airplay_start and on every
 * new client connection. Poll ~1/s and diff for fps / bitrate.
 */
void  airplay_get_stats(unsigned long long *frames, unsigned long long *bytes);

/*
 * Post a macOS user notification (UNUserNotificationCenter). Authorization
 * is requested lazily on first use; a denial or failure is reported via
 * AP_EV_LOG. Outside an .app bundle (dotnet run) the call is a logged no-op
 * — the UserNotifications API crashes unbundled processes, so it is gated.
 */
void  airplay_show_notification(const char *title, const char *body);

/*
 * Hide the mouse cursor until the user moves it (NSCursor
 * setHiddenUntilMouseMoves:). Used when the overlay chrome auto-hides
 * during mirroring, e.g. in fullscreen. macOS no-op safe to call anytime.
 */
void  airplay_hide_cursor_until_move(void);

#ifdef __cplusplus
}
#endif

#endif /* AIRPLAY_BRIDGE_H */
