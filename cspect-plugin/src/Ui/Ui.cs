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

    // Turns polled iWindow mouse state into edge-triggered clicks and wheel steps.
    public sealed class MouseTracker
    {
        int lastButtons, lastWheel, lastCol = -2, lastRow = -2;
        bool first = true;

        public UiInput Next(int px, int py, int buttons, int wheel, int cols, int rows, int cellW, int cellH,
            int leftMask, int rightMask, bool wheelIsTotal, bool wheelUpPositive)
        {
            var u = new UiInput();
            if (px >= 0 && py >= 0 && px < cols * cellW && py < rows * cellH)
            {
                u.Col = px / cellW;
                u.Row = py / cellH;
            }
            u.LeftClick = u.Col >= 0 && (buttons & leftMask) != 0 && (lastButtons & leftMask) == 0;
            u.RightClick = u.Col >= 0 && (buttons & rightMask) != 0 && (lastButtons & rightMask) == 0;
            lastButtons = buttons;
            int delta = wheelIsTotal ? (first ? 0 : wheel - lastWheel) : wheel;
            lastWheel = wheel;
            first = false;
            u.Wheel = Math.Sign(delta) * (wheelUpPositive ? 1 : -1);
            u.HasEvent = u.LeftClick || u.RightClick || u.Wheel != 0 || u.Col != lastCol || u.Row != lastRow;
            lastCol = u.Col;
            lastRow = u.Row;
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
