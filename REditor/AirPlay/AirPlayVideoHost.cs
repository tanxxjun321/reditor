using Avalonia.Controls;
using Avalonia.Platform;

namespace REditor.AirPlay;

/// <summary>
/// Hosts the native NSView that GStreamer's osxvideosink renders into.
/// The view is created by the native bridge (black, layer-backed) and handed
/// to the AirPlay pipeline via GstVideoOverlay.
/// </summary>
public sealed class AirPlayVideoHost : NativeControlHost {
    private readonly AirPlayService _service;

    public AirPlayVideoHost() : this(new AirPlayService()) { }

    public AirPlayVideoHost(AirPlayService service) {
        _service = service;
    }

    public AirPlayService Service => _service;

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent) {
        var view = _service.CreateVideoView();
        _service.AttachVideoView(view);
        return new PlatformHandle(view, "NSView");
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control) {
        _service.ReleaseVideoView(control.Handle);
    }
}
