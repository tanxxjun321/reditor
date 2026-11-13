using System;
using System.Runtime.InteropServices;

namespace AirMirror.AirPlay;

/// <summary>
/// Thin P/Invoke wrapper over libairplaybridge.dylib (UxPlay core + GStreamer).
/// macOS only. The native event callback may fire on any thread — events are
/// re-raised here as-is; subscribers must marshal to the UI thread themselves.
/// </summary>
public sealed class AirPlayService : IDisposable {
    public enum EventType {
        Waiting = 0,
        Connected = 1,
        Disconnected = 2,
        VideoSize = 3,
        Log = 4,
        Error = 5,
        Stopped = 6,
    }

    public sealed class EventArgs : System.EventArgs {
        public EventType Type { get; }
        public string? Info { get; }
        public int Width { get; }
        public int Height { get; }
        public EventArgs(EventType type, string? info, int width, int height) {
            Type = type; Info = info; Width = width; Height = height;
        }
    }

    public event EventHandler<EventArgs>? ServerEvent;

    public bool IsRunning { get; private set; }

    // Keep the delegate rooted for the lifetime of the native registration.
    private readonly NativeBridge.EventCallback _callback;

    public AirPlayService() {
        _callback = OnNativeEvent;
    }

    /// <summary>Start the AirPlay receiver. Throws on failure.</summary>
    public void Start(string serverName = "AirMirror") {
        if (IsRunning) return;
        int rc = NativeBridge.airplay_start(serverName, _callback, IntPtr.Zero);
        if (rc != 0) {
            throw new InvalidOperationException($"airplay_start failed (code {rc})");
        }
        IsRunning = true;
    }

    public void Stop() {
        if (!IsRunning) return;
        NativeBridge.airplay_stop();
        IsRunning = false;
    }

    /// <summary>
    /// Embed the video view into the window (NSWindow handle), placed below
    /// Avalonia's view so the overlay chrome renders above the video.
    /// Returns the video view handle for <see cref="DetachVideoView"/>.
    /// </summary>
    internal IntPtr AttachVideoView(IntPtr nsWindow) => NativeBridge.airplay_attach_video_view(nsWindow);

    /// <summary>Remove the video view embedded by <see cref="AttachVideoView"/>.</summary>
    internal void DetachVideoView(IntPtr view) => NativeBridge.airplay_detach_video_view(view);

    /// <summary>
    /// Re-assert the transparent-window chrome fixes (opaque window, Avalonia's
    /// title bar backdrop hidden) after macOS undoes them on fullscreen exit.
    /// Must be called on the UI thread.
    /// </summary>
    internal void FixupWindowChrome(IntPtr nsWindow) => NativeBridge.airplay_window_chrome_fixup(nsWindow);

    /// <summary>App-side gain multiplier (1.0 = follow the phone's volume).</summary>
    public void SetGain(double gain) => NativeBridge.airplay_set_volume(gain);

    /// <summary>
    /// Client access password; empty/null disables. Takes effect for new
    /// connections only — safe to change while a session is running.
    /// </summary>
    public void SetPassword(string? password) => NativeBridge.airplay_set_password(password);

    /// <summary>Cumulative mirror-stream counters (frames, payload bytes) since the current client connected.</summary>
    public (ulong Frames, ulong Bytes) GetStats() {
        NativeBridge.airplay_get_stats(out ulong frames, out ulong bytes);
        return (frames, bytes);
    }

    /// <summary>Post a macOS user notification. Delivery requires running from an .app bundle.</summary>
    public void ShowNotification(string title, string body) =>
        NativeBridge.airplay_show_notification(title, body);

    /// <summary>Hide the cursor until the mouse moves (macOS NSCursor). Call when chrome auto-hides.</summary>
    public void HideCursorUntilMouseMoves() => NativeBridge.airplay_hide_cursor_until_move();

    private void OnNativeEvent(IntPtr ctx, NativeBridge.NativeEvent ev, IntPtr info, int width, int height) {
        string? text = info == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(info);
        var type = (EventType)ev;
        if (type == EventType.Stopped) IsRunning = false;
        ServerEvent?.Invoke(this, new EventArgs(type, text, width, height));
    }

    public void Dispose() => Stop();

    private static class NativeBridge {
        private const string Lib = "airplaybridge";

        internal enum NativeEvent {
            Waiting = 0, Connected = 1, Disconnected = 2,
            VideoSize = 3, Log = 4, Error = 5, Stopped = 6,
        }

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        internal delegate void EventCallback(IntPtr ctx, NativeEvent ev, IntPtr info, int width, int height);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern int airplay_start(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string? serverName, EventCallback cb, IntPtr ctx);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_stop();

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr airplay_attach_video_view(IntPtr nsWindow);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_detach_video_view(IntPtr view);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_window_chrome_fixup(IntPtr nsWindow);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_set_volume(double gain);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_set_password(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string? password);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_get_stats(out ulong frames, out ulong bytes);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_show_notification(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string title,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string body);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_hide_cursor_until_move();
    }
}
