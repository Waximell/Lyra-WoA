using Lyra.UI;
using Lyra.UI.Components;
using Lyra.UI.Components.Controls.Button;
using Lyra.UI.Components.Primitives;
using Lyra.UI.SupportingTypes;
using SkiaSharp;

namespace Lyra.Renderer.GUI.Layers;

// ============================================================================
//  NavLayer - previous / next chevrons pinned to the window edges.
// ----------------------------------------------------------------------------
//  Two icon buttons, vertically centred, one against each side of the image
//  area.  They are the mouse equivalent of the Left / Right arrow keys:
//  a click walks the directory exactly like the keyboard does, including
//  the end-of-directory checks (the buttons disappear at the first and the
//  last image instead of sitting there disabled).
//
//  The layer root is Transient, so only the buttons themselves are
//  hit-testable - the empty space between them still pans the image.
//
//  Button size follows the window height (10%, clamped to a sane range),
//  which is why the layout is computed here rather than expressed with
//  stack alignment: LyraUI has no percentage sizes.
//
//  The right button tracks the left edge of the sidebar when it is open,
//  so it never sits on top of the panel; the caller supplies that edge
//  through a provider because MainLayer owns the sidebar.
// ============================================================================
public sealed class NavLayer : IDisposable
{
    private readonly NavOverlay _root;

    public event Action? PreviousRequested;
    public event Action? NextRequested;

    public NavLayer(UIContext context, Func<float> contentRightEdge)
    {
        _root = new NavOverlay(contentRightEdge);
        _root.PreviousClicked += () => PreviousRequested?.Invoke();
        _root.NextClicked += () => NextRequested?.Invoke();

        // Added after MainLayer, so the chevrons draw above the panes while
        // staying below any popup or modal created later.
        var layer = context.AddLayer("Nav");
        layer.Root = _root;
    }

    /// <summary>
    /// Mirrors the current navigation bounds: a chevron is only shown when
    /// there is somewhere to go in that direction.
    /// </summary>
    public void SetState(bool hasPrevious, bool hasNext) => _root.SetState(hasPrevious, hasNext);

    public void Dispose() => _root.Dispose();
}

internal sealed class NavOverlay : ComponentBase, IContainer
{
    private const float EdgeMargin = 8f;
    private const float HeightFraction = 0.10f;
    private const float MinSize = 36f;
    private const float MaxSize = 96f;

    private readonly Button _previous;
    private readonly Button _next;
    private readonly SvgImage _previousIcon;
    private readonly SvgImage _nextIcon;
    private readonly Func<float> _contentRightEdge;
    private readonly IComponent[] _children;

    public event Action? PreviousClicked;
    public event Action? NextClicked;

    public NavOverlay(Func<float> contentRightEdge)
    {
        _contentRightEdge = contentRightEdge;

        // ResourceLoader owns the SKPictures; each SvgImage only wraps one for
        // layout, so the same chevron can be shown at any button size.
        _previousIcon = new SvgImage(ResourceLoader.GetSvg("chevron_left"), MinSize, MinSize);
        _nextIcon = new SvgImage(ResourceLoader.GetSvg("chevron_right"), MinSize, MinSize);

        _previous = BuildButton(_previousIcon);
        _next = BuildButton(_nextIcon);

        _previous.Click += () => PreviousClicked?.Invoke();
        _next.Click += () => NextClicked?.Invoke();

        _children = [_previous, _next];
        _previous.Parent = this;
        _next.Parent = this;

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

    private static Button BuildButton(SvgImage icon) => new()
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

    public void SetState(bool hasPrevious, bool hasNext)
    {
        if (_previous.Present == hasPrevious && _next.Present == hasNext)
            return;

        _previous.Present = hasPrevious;
        _next.Present = hasNext;
        Context?.Invalidate();
    }

    protected override SKSize MeasureContent(SKSize availableSize)
    {
        _previous.Measure(availableSize);
        _next.Measure(availableSize);
        return availableSize;
    }

    protected override void ResolveContent()
    {
        _previous.Resolve();
        _next.Resolve();
    }

    protected override void ArrangeContent(SKRect contentBounds)
    {
        var size = Math.Clamp(contentBounds.Height * HeightFraction, MinSize, MaxSize);
        var top = contentBounds.MidY - size / 2f;
        var bottom = top + size;

        if (_previous.Present)
        {
            var left = contentBounds.Left + EdgeMargin;
            _previous.Arrange(new SKRect(left, top, left + size, bottom));
            SquareIcon(_previous, _previousIcon);
        }

        if (_next.Present)
        {
            // float.MaxValue means "no sidebar", i.e. the window edge.
            var right = Math.Min(contentBounds.Right, _contentRightEdge()) - EdgeMargin;
            _next.Arrange(new SKRect(right - size, top, right, bottom));
            SquareIcon(_next, _nextIcon);
        }
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
        _previous.Render(canvas);
        _next.Render(canvas);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _previous.Dispose();
            _next.Dispose();
            // Button does not own IconImage; these two are ours.
            _previousIcon.Dispose();
            _nextIcon.Dispose();
        }

        base.Dispose(disposing);
    }
}
