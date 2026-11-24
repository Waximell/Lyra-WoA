using System.Diagnostics;
using Lyra.UI;
using Lyra.UI.Components;
using Lyra.UI.Components.Controls.Button;
using Lyra.UI.Components.Primitives;
using Lyra.UI.SupportingTypes;
using SkiaSharp;

namespace Lyra.Renderer.GUI.Layers;

/// <summary>
/// Everything the nav layer needs to know each frame.  A record struct so the
/// equality check in <see cref="NavOverlay.SetState"/> is free and a no-op frame
/// does not invalidate the layout.
/// </summary>
public readonly record struct NavState(
    bool HasPrevious,
    bool HasNext,
    bool InfoVisible,
    bool SidebarVisible,
    bool HelpVisible,
    bool IsFullscreen,
    bool UiHidden);

// ============================================================================
//  NavLayer - the on-screen chrome: chevrons, corner buttons, hide toggle.
// ----------------------------------------------------------------------------
//  Left / right chevrons, vertically centred, flush with the image area:
//    click        -> previous / next image (same path as the Left / Right keys)
//    hold 1s      -> first / last image   (same path as Home / End)
//    right click  -> first / last image
//
//  Bottom right, a row of three small buttons (one third of a chevron):
//    info        -> i   (info pane)
//    dashboard   -> u   (sidebar)
//    maximise    -> f   (enter fullscreen; becomes minimise while fullscreen)
//
//  Bottom left, stop:
//    -> closes every open pane (info / help / sidebar) and hides the three
//       corner buttons; the chevrons and stop itself stay.  Pressing it again
//       only brings the corner buttons back, panes stay closed, and the state
//       is never remembered across launches.  While the help pane is visible
//       stop stacks directly above it instead of sitting on the text.
//
//  The layer root is Transient, so the empty space still pans the image.
// ============================================================================
public sealed class NavLayer : IDisposable
{
    private readonly NavOverlay _root;

    public event Action? PreviousRequested;
    public event Action? NextRequested;
    public event Action? FirstRequested;
    public event Action? LastRequested;
    public event Action? InfoToggleRequested;
    public event Action? SidebarToggleRequested;
    public event Action? FullscreenToggleRequested;
    public event Action? UiToggleRequested;

    public NavLayer(UIContext context, Func<float> contentRightEdge, Func<float> helpTopEdge)
    {
        _root = new NavOverlay(contentRightEdge, helpTopEdge);
        _root.PreviousClicked += () => PreviousRequested?.Invoke();
        _root.NextClicked += () => NextRequested?.Invoke();
        _root.FirstRequested += () => FirstRequested?.Invoke();
        _root.LastRequested += () => LastRequested?.Invoke();
        _root.InfoClicked += () => InfoToggleRequested?.Invoke();
        _root.SidebarClicked += () => SidebarToggleRequested?.Invoke();
        _root.FullscreenClicked += () => FullscreenToggleRequested?.Invoke();
        _root.UiClicked += () => UiToggleRequested?.Invoke();

        // Added after MainLayer, so the chrome draws above the panes while
        // staying below any popup or modal created later.
        var layer = context.AddLayer("Nav");
        layer.Root = _root;
    }

    public void SetState(NavState state) => _root.SetState(state);

    /// <summary>Right click on a chevron: jump to the first / last image.</summary>
    public bool TryHandleSecondaryClick(SKPoint point) => _root.TryHandleSecondaryClick(point);

    public void Dispose() => _root.Dispose();
}

internal sealed class NavOverlay : ComponentBase, IContainer
{
    private const float EdgeMargin = 8f;
    private const float ButtonGap = 4f;
    private const float HeightFraction = 0.10f;
    private const float MinSize = 36f;
    private const float MaxSize = 96f;

    private readonly NavChevronButton _previous;
    private readonly NavChevronButton _next;

    private readonly Button _info;
    private readonly Button _sidebar;
    private readonly Button _enterFullscreen;
    private readonly Button _exitFullscreen;
    private readonly Button _stop;

    private readonly SvgImage _previousIcon;
    private readonly SvgImage _nextIcon;
    private readonly SvgImage _infoIcon;
    private readonly SvgImage _sidebarIcon;
    private readonly SvgImage _maximiseIcon;
    private readonly SvgImage _minimiseIcon;
    private readonly SvgImage _stopIcon;

    private readonly Func<float> _contentRightEdge;
    private readonly Func<float> _helpTopEdge;
    private readonly IComponent[] _children;

    private NavState _state;

    public event Action? PreviousClicked;
    public event Action? NextClicked;
    public event Action? FirstRequested;
    public event Action? LastRequested;
    public event Action? InfoClicked;
    public event Action? SidebarClicked;
    public event Action? FullscreenClicked;
    public event Action? UiClicked;

    public NavOverlay(Func<float> contentRightEdge, Func<float> helpTopEdge)
    {
        _contentRightEdge = contentRightEdge;
        _helpTopEdge = helpTopEdge;

        // ResourceLoader owns the SKPictures; each SvgImage only wraps one for
        // layout, so the same artwork can be shown at any button size.
        _previousIcon = new SvgImage(ResourceLoader.GetSvg("chevron_left"), MinSize, MinSize);
        _nextIcon = new SvgImage(ResourceLoader.GetSvg("chevron_right"), MinSize, MinSize);
        _infoIcon = new SvgImage(ResourceLoader.GetSvg("info"), MinSize, MinSize);
        _sidebarIcon = new SvgImage(ResourceLoader.GetSvg("dashboard"), MinSize, MinSize);
        _maximiseIcon = new SvgImage(ResourceLoader.GetSvg("maximise"), MinSize, MinSize);
        _minimiseIcon = new SvgImage(ResourceLoader.GetSvg("minimise"), MinSize, MinSize);
        _stopIcon = new SvgImage(ResourceLoader.GetSvg("stop"), MinSize, MinSize);

        _previous = BuildChevron(_previousIcon);
        _next = BuildChevron(_nextIcon);

        _info = BuildSmall(_infoIcon);
        _sidebar = BuildSmall(_sidebarIcon);
        _enterFullscreen = BuildSmall(_maximiseIcon);
        _exitFullscreen = BuildSmall(_minimiseIcon);
        _stop = BuildSmall(_stopIcon);

        _previous.Click += () => PreviousClicked?.Invoke();
        _next.Click += () => NextClicked?.Invoke();
        _previous.LongPress += () => FirstRequested?.Invoke();
        _next.LongPress += () => LastRequested?.Invoke();

        _info.Click += () => InfoClicked?.Invoke();
        _sidebar.Click += () => SidebarClicked?.Invoke();
        _enterFullscreen.Click += () => FullscreenClicked?.Invoke();
        _exitFullscreen.Click += () => FullscreenClicked?.Invoke();
        _stop.Click += () => UiClicked?.Invoke();

        _children =
        [
            _previous, _next,
            _info, _sidebar, _enterFullscreen, _exitFullscreen,
            _stop
        ];

        foreach (var child in _children)
            child.Parent = this;

        // Transient keeps the empty middle of the layer click-through so the
        // image can still be panned; the buttons are non-transient children.
        Transient = true;
        HorizontalSize = SizeMode.Expand;
        VerticalSize = SizeMode.Expand;
    }

    public IReadOnlyList<IComponent> Children => _children;

    public void AddComponent(IComponent child) =>
        throw new NotSupportedException("Nav overlay children are fixed.");

    public void AddComponents(params IComponent[] children) =>
        throw new NotSupportedException("Nav overlay children are fixed.");

    private static NavChevronButton BuildChevron(SvgImage icon) => new()
    {
        // Ghost is fully transparent at rest and only tints on hover, which is
        // the "no background, just the arrow" look while keeping feedback.
        Variant = ButtonVariant.Ghost,
        Icon = ButtonIcon.Only,
        IconImage = icon,
        CornerRadius = 6f,
        MinWidth = 0f,
        MinHeight = 0f
    };

    private static Button BuildSmall(SvgImage icon) => new()
    {
        Variant = ButtonVariant.Ghost,
        Icon = ButtonIcon.Only,
        IconImage = icon,
        CornerRadius = 3f,
        MinWidth = 0f,
        MinHeight = 0f
    };

    public bool TryHandleSecondaryClick(SKPoint point)
    {
        if (_previous.Present && _previous.ArrangedBounds.Contains(point))
        {
            FirstRequested?.Invoke();
            return true;
        }

        if (_next.Present && _next.ArrangedBounds.Contains(point))
        {
            LastRequested?.Invoke();
            return true;
        }

        return false;
    }

    public void SetState(NavState state)
    {
        if (state == _state)
            return;

        _state = state;

        _previous.Present = state.HasPrevious;
        _next.Present = state.HasNext;

        // Everything below is chrome that the stop button hides.
        var showCorner = !state.UiHidden;
        _info.Present = showCorner;
        _sidebar.Present = showCorner;
        _enterFullscreen.Present = showCorner && !state.IsFullscreen;
        _exitFullscreen.Present = showCorner && state.IsFullscreen;

        // The stop button is always available - it is the way back.
        _stop.Present = true;

        Context?.Invalidate();
    }

    protected override SKSize MeasureContent(SKSize availableSize)
    {
        foreach (var child in _children)
            child.Measure(availableSize);

        return availableSize;
    }

    protected override void ResolveContent()
    {
        foreach (var child in _children)
            child.Resolve();
    }

    protected override void ArrangeContent(SKRect contentBounds)
    {
        var size = Math.Clamp(contentBounds.Height * HeightFraction, MinSize, MaxSize);
        var small = MathF.Max(12f, MathF.Round(size / 3f));
        var midTop = contentBounds.MidY - size / 2f;

        if (_previous.Present)
        {
            var left = contentBounds.Left + EdgeMargin;
            _previous.Arrange(new SKRect(left, midTop, left + size, midTop + size));
            SquareIcon(_previous, _previousIcon);
        }

        if (_next.Present)
        {
            // float.MaxValue means "no sidebar", i.e. the window edge.
            var right = Math.Min(contentBounds.Right, _contentRightEdge()) - EdgeMargin;
            _next.Arrange(new SKRect(right - size, midTop, right, midTop + size));
            SquareIcon(_next, _nextIcon);
        }

        // Bottom-right row, laid out from the right edge leftwards so the
        // fullscreen button stays anchored to the corner.
        var rowBottom = contentBounds.Bottom - EdgeMargin;
        var rowTop = rowBottom - small;
        var cornerRight = Math.Min(contentBounds.Right, _contentRightEdge()) - EdgeMargin;

        ArrangeSmall(_enterFullscreen, _maximiseIcon, cornerRight, rowTop, small);
        ArrangeSmall(_exitFullscreen, _minimiseIcon, cornerRight, rowTop, small);

        var listRight = cornerRight - small - ButtonGap;
        ArrangeSmall(_sidebar, _sidebarIcon, listRight, rowTop, small);

        var infoRight = listRight - small - ButtonGap;
        ArrangeSmall(_info, _infoIcon, infoRight, rowTop, small);

        // Bottom-left stop.  While the help pane is open it stacks directly
        // above it (never on top of the text) and drops back to the corner once
        // the pane is closed.  The result is clamped to the canvas so a tall
        // help table cannot push the button out of the window.
        var stopLeft = contentBounds.Left + EdgeMargin;
        var stopTop = rowTop;
        var helpTop = _state.HelpVisible ? _helpTopEdge() : 0f;
        if (helpTop > 0f)
            stopTop = Math.Max(contentBounds.Top + EdgeMargin, helpTop - EdgeMargin - small);
        ArrangeSmall(_stop, _stopIcon, stopLeft + small, stopTop, small);
    }

    private static void ArrangeSmall(Button button, SvgImage icon, float right, float top, float side)
    {
        button.Arrange(new SKRect(right - side, top, right, top + side));
        SquareIcon(button, icon);
    }

    /// <summary>
    /// Button stretches its icon to the full inner height, which would squash a
    /// square glyph.  Re-arrange it to a centred square after the button has
    /// laid itself out; the button only renders the icon, it does not re-place it.
    /// </summary>
    private static void SquareIcon(Button button, SvgImage icon)
    {
        var b = button.ArrangedBounds;
        var side = Math.Min(b.Width, b.Height);
        var cx = b.MidX;
        var cy = b.MidY;
        icon.Arrange(new SKRect(cx - side / 2f, cy - side / 2f, cx + side / 2f, cy + side / 2f));
    }

    protected override void RenderContent(SKCanvas canvas, SKRect contentBounds)
    {
        // ComponentBase.Render does not consult Present (the framework expects
        // containers to skip hidden children themselves).
        foreach (var child in _children)
        {
            if (child.Present)
                child.Render(canvas);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            foreach (var child in _children)
                child.Dispose();

            // Button does not own IconImage; these are ours.
            _previousIcon.Dispose();
            _nextIcon.Dispose();
            _infoIcon.Dispose();
            _sidebarIcon.Dispose();
            _maximiseIcon.Dispose();
            _minimiseIcon.Dispose();
            _stopIcon.Dispose();
        }

        base.Dispose(disposing);
    }

    /// <summary>
    /// Chevron with a long-press action: holding the button for a second fires
    /// <see cref="LongPress"/> instead of a click.  The check runs from the
    /// render pass, which is the only per-frame hook a component gets.
    /// </summary>
    private sealed class NavChevronButton : Button
    {
        private static readonly TimeSpan HoldDuration = TimeSpan.FromSeconds(1);

        private long _pressedAt;
        private bool _pressed;
        private bool _longFired;

        public event Action? LongPress;

        protected override void OnPointerDownCore(SKPoint point)
        {
            base.OnPointerDownCore(point);
            _pressedAt = Stopwatch.GetTimestamp();
            _pressed = true;
            _longFired = false;
        }

        protected override void OnPointerUpCore(SKPoint point)
        {
            _pressed = false;
            base.OnPointerUpCore(point);
        }

        protected override void OnClick()
        {
            // The hold already did its work; do not also step one image.
            if (_longFired)
                return;

            base.OnClick();
        }

        protected override void RenderContent(SKCanvas canvas, SKRect contentBounds)
        {
            if (_pressed && !_longFired && Stopwatch.GetElapsedTime(_pressedAt) >= HoldDuration)
            {
                _longFired = true;
                LongPress?.Invoke();
            }

            base.RenderContent(canvas, contentBounds);
        }
    }
}
