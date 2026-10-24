using System;

namespace NextDAADDebug
{
    // One frame of input in cell coordinates; Col = -1 when the mouse is outside.
    public sealed class UiInput
    {
        public int Col = -1, Row = -1;
        public bool LeftClick, RightClick;
        public int Wheel;                        // +1 = wheel up (scroll towards the top)
        public bool HasEvent;
    }

    // Turns polled mouse state into edge-triggered clicks. Buttons: bit 0 left, bit 1 right; wheel: steps this frame, +up, clamped to MaxWheel.
    public sealed class MouseTracker
    {
        public const int MaxWheel = 5;
        int lastButtons, lastCol = -2, lastRow = -2;

        public UiInput Next(int px, int py, int buttons, int wheel, int cols, int rows, int cellW, int cellH)
        {
            int pressed = buttons & ~lastButtons;
            lastButtons = buttons;
            return Pressed(px, py, pressed, wheel, cols, rows, cellW, cellH);
        }

        // pressed: buttons that went down since the last call.
        public UiInput Pressed(int px, int py, int pressed, int wheel, int cols, int rows, int cellW, int cellH)
        {
            var u = new UiInput();
            if (px >= 0 && py >= 0 && px < cols * cellW && py < rows * cellH)
            {
                u.Col = px / cellW;
                u.Row = py / cellH;
            }
            u.LeftClick = u.Col >= 0 && (pressed & 1) != 0;
            u.RightClick = u.Col >= 0 && (pressed & 2) != 0;
            u.Wheel = Math.Max(-MaxWheel, Math.Min(MaxWheel, wheel));
            u.HasEvent = u.LeftClick || u.RightClick || u.Wheel != 0 || u.Col != lastCol || u.Row != lastRow;
            lastCol = u.Col;
            lastRow = u.Row;
            return u;
        }
    }

    // ImGui IO samples from the draw action, folded into one UiInput per OSTick.
    // MousePos is -FLT_MAX when the window is not hovered; a press on the image in any sample counts once,
    // a press made off the image never does.
    public sealed class ImGuiMouse
    {
        readonly MouseTracker tracker = new MouseTracker();
        readonly int cols, rows, cellW, cellH;
        int px = -1, py = -1, down, pressed;
        float wheel;

        public ImGuiMouse(int cols, int rows, int cellW, int cellH)
        {
            this.cols = cols;
            this.rows = rows;
            this.cellW = cellW;
            this.cellH = cellH;
        }

        public void Sample(float mouseX, float mouseY, float imageX, float imageY, bool left, bool right, float wheelDelta)
        {
            bool off = float.IsNaN(mouseX) || float.IsNaN(mouseY) || mouseX < -1e30f || mouseY < -1e30f;
            px = off ? -1 : (int)Math.Floor(mouseX - imageX);
            py = off ? -1 : (int)Math.Floor(mouseY - imageY);
            bool inside = px >= 0 && py >= 0 && px < cols * cellW && py < rows * cellH;
            int now = (left ? 1 : 0) | (right ? 2 : 0);
            pressed = inside ? pressed | (now & ~down) : 0;
            down = now;
            if (!float.IsNaN(wheelDelta)) wheel += wheelDelta;
        }

        public UiInput Take()
        {
            int steps = (int)Math.Max(-MouseTracker.MaxWheel, Math.Min(MouseTracker.MaxWheel, wheel));
            if (steps == 0 && wheel != 0) steps = Math.Sign(wheel);
            var u = tracker.Pressed(px, py, pressed, steps, cols, rows, cellW, cellH);
            pressed = 0;
            wheel = 0;
            return u;
        }
    }

    // Immediate-mode widgets: draw and test input in one call. Blocked = a popup owns input.
    public sealed class Ui
    {
        public readonly CellScreen S;
        public UiInput In = new UiInput();
        public bool Blocked;

        public Ui(CellScreen s) { S = s; }

        public void Begin(UiInput input)
        {
            In = input ?? new UiInput();
            Blocked = false;
            S.Clear(Theme.Bg);
        }

        public bool Hover(int x, int y, int w, int h) => !Blocked && In.Col >= x && In.Col < x + w && In.Row >= y && In.Row < y + h;
        public bool Click(int x, int y, int w, int h) => In.LeftClick && Hover(x, y, w, h);
        public int Wheel(int x, int y, int w, int h) => Hover(x, y, w, h) ? In.Wheel : 0;

        public bool Button(int x, int y, string label, bool enabled = true)
        {
            int w = label.Length + 2;
            bool hot = enabled && Hover(x, y, w, 1);
            S.Text(x, y, " " + label + " ", enabled ? Theme.Text : Theme.Dim, !enabled ? Theme.ButtonOff : hot ? Theme.ButtonHot : Theme.Button);
            return enabled && Click(x, y, w, 1);
        }

        public int Tabs(int x, int y, string[] names, int current)
        {
            int cx = x, result = current;
            for (int i = 0; i < names.Length; i++)
            {
                int w = names[i].Length + 2;
                byte bg = i == current ? Theme.TabOn : Hover(cx, y, w, 1) ? Theme.ButtonHot : Theme.Tab;
                S.Text(cx, y, " " + names[i] + " ", Theme.Text, bg);
                if (Click(cx, y, w, 1)) result = i;
                cx += w + 1;
            }
            return result;
        }

        // Scrolls 'top' with the wheel (3 rows a step) and clamps it; returns the clicked row index or -1.
        public int List(ref int top, int x, int y, int w, int h, int count)
        {
            top -= Wheel(x, y, w, h) * 3;
            top = Math.Max(0, Math.Min(top, Math.Max(0, count - h)));
            if (!Click(x, y, w, h)) return -1;
            int idx = top + (In.Row - y);
            return idx < count ? idx : -1;
        }

        public char AzStrip(int x, int y)
        {
            char hit = '\0';
            for (int i = 0; i < 26; i++)
            {
                char ch = (char)('A' + i);
                S.Put(x + i, y, (byte)ch, Theme.Accent, Hover(x + i, y, 1, 1) ? Theme.ButtonHot : Theme.Tab);
                if (Click(x + i, y, 1, 1)) hit = ch;
            }
            return hit;
        }

        public void Box(int x, int y, int w, int h, string title)
        {
            S.Fill(x, y, w, h, 32, Theme.Text, Theme.PopupBg);
            for (int i = 1; i < w - 1; i++)
            {
                S.Put(x + i, y, 0xC4, Theme.Accent, Theme.PopupBg);
                S.Put(x + i, y + h - 1, 0xC4, Theme.Accent, Theme.PopupBg);
            }
            for (int j = 1; j < h - 1; j++)
            {
                S.Put(x, y + j, 0xB3, Theme.Accent, Theme.PopupBg);
                S.Put(x + w - 1, y + j, 0xB3, Theme.Accent, Theme.PopupBg);
            }
            S.Put(x, y, 0xDA, Theme.Accent, Theme.PopupBg);
            S.Put(x + w - 1, y, 0xBF, Theme.Accent, Theme.PopupBg);
            S.Put(x, y + h - 1, 0xC0, Theme.Accent, Theme.PopupBg);
            S.Put(x + w - 1, y + h - 1, 0xD9, Theme.Accent, Theme.PopupBg);
            S.Text(x + 2, y, " " + title + " ", Theme.Accent, Theme.PopupBg, w - 4);
        }
    }
}
