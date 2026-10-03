using System;
using System.Collections.Generic;

namespace NextDAADDebug
{
    public enum PopupResult { Open, Ok, Cancel }

    public abstract class Popup
    {
        public abstract PopupResult Draw(Ui ui);
    }

    // Number entry without a keyboard: digits, back, clear, +/-1, wheel.
    public sealed class DigitPad : Popup
    {
        public readonly string Title;
        public readonly int Min, Max;
        public int Value;
        bool fresh = true;

        public DigitPad(string title, int value, int min, int max)
        {
            Title = title;
            Min = min;
            Max = max;
            Value = Clamp(value);
        }

        public override PopupResult Draw(Ui ui)
        {
            const int w = 24, h = 12;
            int x = (ui.S.Cols - w) / 2, y = (ui.S.Rows - h) / 2;
            ui.Box(x, y, w, h, Title);
            ui.S.Text(x + 2, y + 2, Value.ToString().PadLeft(6), Theme.Changed, Theme.PopupBg);
            string[] rows = { "789", "456", "123" };
            for (int r = 0; r < 3; r++)
                for (int c = 0; c < 3; c++)
                    if (ui.Button(x + 2 + c * 4, y + 4 + r, rows[r][c].ToString())) Digit(rows[r][c] - '0');
            if (ui.Button(x + 2, y + 7, "0")) Digit(0);
            if (ui.Button(x + 6, y + 7, "<")) { Value = Clamp(Value / 10); fresh = false; }
            if (ui.Button(x + 10, y + 7, "C")) { Value = Min; fresh = false; }
            if (ui.Button(x + 15, y + 4, "-1")) { Value = Clamp(Value - 1); fresh = false; }
            if (ui.Button(x + 15, y + 5, "+1")) { Value = Clamp(Value + 1); fresh = false; }
            int wheel = ui.Wheel(x, y, w, h);
            if (wheel != 0) { Value = Clamp(Value + wheel); fresh = false; }
            if (ui.Button(x + 2, y + 9, "OK")) return PopupResult.Ok;
            if (ui.Button(x + 8, y + 9, "Cancel") || ui.In.RightClick) return PopupResult.Cancel;
            return PopupResult.Open;
        }

        void Digit(int d)
        {
            int v = fresh ? d : Value * 10 + d;
            fresh = false;
            Value = Clamp(v > Max ? d : v);
        }

        int Clamp(int v) => Math.Max(Min, Math.Min(Max, v));
    }

    public struct PickItem
    {
        public string Label;
        public int Value;

        public PickItem(string label, int value)
        {
            Label = label;
            Value = value;
        }
    }

    // Scrolling choice list with an A-Z jump strip.
    public sealed class Picker : Popup
    {
        public readonly string Title;
        public readonly List<PickItem> Items;
        public int Top;
        public int Selected = -1;

        public Picker(string title, List<PickItem> items)
        {
            Title = title;
            Items = items;
        }

        public override PopupResult Draw(Ui ui)
        {
            const int w = 60, h = 30;
            int x = (ui.S.Cols - w) / 2, y = (ui.S.Rows - h) / 2;
            ui.Box(x, y, w, h, Title);
            char ch = ui.AzStrip(x + 2, y + 1);
            if (ch != '\0')
            {
                int i = Items.FindIndex(p => p.Label.Length > 0 && char.ToUpperInvariant(p.Label[0]) == ch);
                if (i >= 0) Top = i;
            }
            int listY = y + 3, listH = h - 6, listW = w - 4;
            int hit = ui.List(ref Top, x + 2, listY, listW, listH, Items.Count);
            for (int r = 0; r < listH && Top + r < Items.Count; r++)
                ui.S.Text(x + 2, listY + r, Items[Top + r].Label.PadRight(listW), Theme.Text, ui.Hover(x + 2, listY + r, listW, 1) ? Theme.ButtonHot : Theme.PopupBg, listW);
            if (hit >= 0)
            {
                Selected = Items[hit].Value;
                return PopupResult.Ok;
            }
            if (ui.Button(x + 2, y + h - 2, "Cancel") || ui.In.RightClick) return PopupResult.Cancel;
            return PopupResult.Open;
        }
    }
}
