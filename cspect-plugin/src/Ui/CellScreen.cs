using System;
using System.Text;

namespace NextDAADDebug
{
    public struct Cell
    {
        public byte Glyph, Fg, Bg;
    }

    // Character grid rendered with an 8x16 CP437 font; glyph bytes are CP437 codes.
    public sealed class CellScreen
    {
        public readonly int Cols, Rows;
        readonly Cell[] cells;

        public CellScreen(int cols, int rows)
        {
            Cols = cols;
            Rows = rows;
            cells = new Cell[cols * rows];
        }

        public Cell this[int x, int y] => cells[y * Cols + x];

        public void Clear(byte bg)
        {
            for (int i = 0; i < cells.Length; i++) cells[i] = new Cell { Glyph = 32, Fg = Theme.Text, Bg = bg };
        }

        public void Put(int x, int y, byte glyph, byte fg, byte bg)
        {
            if (x < 0 || y < 0 || x >= Cols || y >= Rows) return;
            cells[y * Cols + x] = new Cell { Glyph = glyph, Fg = fg, Bg = bg };
        }

        public int Text(int x, int y, string s, byte fg, byte bg, int max = int.MaxValue)
        {
            if (s == null) return 0;
            int n = 0;
            foreach (char ch in s)
            {
                if (n >= max) break;
                Put(x + n, y, Map(ch), fg, bg);
                n++;
            }
            return n;
        }

        public void Fill(int x, int y, int w, int h, byte glyph, byte fg, byte bg)
        {
            for (int j = 0; j < h; j++)
                for (int i = 0; i < w; i++) Put(x + i, y + j, glyph, fg, bg);
        }

        public static byte Map(char ch) => ch == '\n' || ch == '\t' ? (byte)32 : ch < 256 ? (byte)ch : (byte)'?';

        public string RowText(int y)
        {
            var sb = new StringBuilder(Cols);
            for (int x = 0; x < Cols; x++) sb.Append((char)cells[y * Cols + x].Glyph);
            return sb.ToString();
        }

        public bool Find(string text, out int x, out int y, int fromRow = 0, int toRow = int.MaxValue)
        {
            for (y = Math.Max(0, fromRow); y < Rows && y <= toRow; y++)
            {
                int i = RowText(y).IndexOf(text, StringComparison.Ordinal);
                if (i >= 0) { x = i; return true; }
            }
            x = y = -1;
            return false;
        }

        public void Render(uint[] dest, byte[] font, uint[] palette)
        {
            int width = Cols * 8;
            for (int cy = 0; cy < Rows; cy++)
                for (int cx = 0; cx < Cols; cx++)
                {
                    var c = cells[cy * Cols + cx];
                    uint fg = palette[c.Fg], bg = palette[c.Bg];
                    int g = c.Glyph * 16;
                    for (int r = 0; r < 16; r++)
                    {
                        byte bits = font[g + r];
                        int row = (cy * 16 + r) * width + cx * 8;
                        for (int b = 0; b < 8; b++) dest[row + b] = (bits & (0x80 >> b)) != 0 ? fg : bg;
                    }
                }
        }
    }
}
