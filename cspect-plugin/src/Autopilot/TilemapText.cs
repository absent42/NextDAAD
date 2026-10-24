using System;

namespace NextDAADDebug.Autopilot
{
    // Interpreter tilemap as text: 32 rows (TM_ROWS) at physical $16000, glyph byte then attribute byte per cell.
    public static class TilemapText
    {
        const int MapPhys = 0x16000;
        const int Rows = 32;

        public static string[] Read(IMachine m, ushort tmColsAddr)
        {
            int cols = m.Peek(tmColsAddr);
            if (cols != 40 && cols != 80) throw new InvalidOperationException("tmCols is " + cols);
            int stride = cols * 2;
            byte[] raw = m.PeekPhysicalUla(MapPhys, Rows * stride);
            var rows = new string[Rows];
            var line = new char[cols];
            for (int r = 0; r < Rows; r++)
            {
                for (int c = 0; c < cols; c++)
                {
                    byte g = raw[r * stride + c * 2];
                    line[c] = g >= 32 && g <= 126 ? (char)g : '?';
                }
                rows[r] = new string(line);
            }
            return rows;
        }

        public static bool Contains(string[] rows, string text)
        {
            foreach (string r in rows)
                if (r.IndexOf(text, StringComparison.Ordinal) >= 0) return true;
            return false;
        }
    }
}
