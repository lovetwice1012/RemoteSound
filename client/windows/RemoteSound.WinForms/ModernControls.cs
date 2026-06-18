using System.Drawing.Drawing2D;

namespace RemoteSound.WinForms;

internal sealed class GlassPanel : Panel
{
    public int Radius { get; set; } = 18;
    public Color FillColor { get; set; } = Color.FromArgb(118, 28, 30, 38);
    public Color BorderColor { get; set; } = Color.FromArgb(80, 255, 255, 255);

    public GlassPanel()
    {
        DoubleBuffered = true;
        BackColor = Color.Transparent;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = CreateRoundedRectangle(new Rectangle(0, 0, Math.Max(0, Width - 1), Math.Max(0, Height - 1)), Radius);
        using var fill = new SolidBrush(FillColor);
        using var border = new Pen(BorderColor, 1f);
        e.Graphics.FillPath(fill, path);
        e.Graphics.DrawPath(border, path);
        base.OnPaint(e);
    }

    private static GraphicsPath CreateRoundedRectangle(Rectangle rectangle, int radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;
        var arc = new Rectangle(rectangle.Location, new Size(diameter, diameter));

        path.AddArc(arc, 180, 90);
        arc.X = rectangle.Right - diameter;
        path.AddArc(arc, 270, 90);
        arc.Y = rectangle.Bottom - diameter;
        path.AddArc(arc, 0, 90);
        arc.X = rectangle.Left;
        path.AddArc(arc, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal sealed class ModernButton : Button
{
    public Color AccentColor { get; set; } = Color.FromArgb(74, 144, 226);

    public ModernButton()
    {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        BackColor = AccentColor;
        ForeColor = Color.White;
        Font = new Font("Segoe UI Semibold", 10.5f, FontStyle.Regular, GraphicsUnit.Point);
        Cursor = Cursors.Hand;
        Height = 40;
        MinimumSize = new Size(0, 40);
        TextAlign = ContentAlignment.MiddleCenter;
    }

    protected override void OnPaint(PaintEventArgs pevent)
    {
        BackColor = Enabled ? AccentColor : Color.FromArgb(80, 90, 96, 110);
        base.OnPaint(pevent);
    }
}

internal sealed class LevelBar : Control
{
    private float _value;

    public float Value
    {
        get => _value;
        set
        {
            _value = Math.Clamp(value, 0f, 1f);
            Invalidate();
        }
    }

    public LevelBar()
    {
        DoubleBuffered = true;
        Height = 16;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var rect = new Rectangle(0, 0, Math.Max(0, Width - 1), Math.Max(0, Height - 1));
        using var background = new SolidBrush(Color.FromArgb(70, 255, 255, 255));
        using var border = new Pen(Color.FromArgb(80, 255, 255, 255));
        using var bgPath = Rounded(rect, 8);
        e.Graphics.FillPath(background, bgPath);
        e.Graphics.DrawPath(border, bgPath);

        var fillWidth = Math.Max(0, (int)((Width - 2) * _value));
        if (fillWidth > 0)
        {
            var fillRect = new Rectangle(1, 1, fillWidth, Height - 3);
            using var brush = new LinearGradientBrush(fillRect, Color.FromArgb(72, 211, 153), Color.FromArgb(56, 189, 248), 0f);
            using var path = Rounded(fillRect, 7);
            e.Graphics.FillPath(brush, path);
        }
    }

    private static GraphicsPath Rounded(Rectangle rectangle, int radius)
    {
        var path = new GraphicsPath();
        var diameter = radius * 2;
        var arc = new Rectangle(rectangle.Location, new Size(diameter, diameter));
        path.AddArc(arc, 180, 90);
        arc.X = rectangle.Right - diameter;
        path.AddArc(arc, 270, 90);
        arc.Y = rectangle.Bottom - diameter;
        path.AddArc(arc, 0, 90);
        arc.X = rectangle.Left;
        path.AddArc(arc, 90, 90);
        path.CloseFigure();
        return path;
    }
}
