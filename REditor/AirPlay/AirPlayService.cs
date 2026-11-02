using System;
using System.Runtime.InteropServices;

namespace REditor.AirPlay;

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
    public void Start(string serverName = "REditor") {
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

    /// <summary>Called by AirPlayVideoHost when its NSView is created.</summary>
    internal void AttachVideoView(IntPtr view) => NativeBridge.airplay_set_video_view(view);

    internal IntPtr CreateVideoView() => NativeBridge.airplay_create_video_view();

    internal void ReleaseVideoView(IntPtr view) => NativeBridge.airplay_release_video_view(view);

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
        internal static extern IntPtr airplay_create_video_view();

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_release_video_view(IntPtr view);

        [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
        internal static extern void airplay_set_video_view(IntPtr view);
    }
}
