using System;

namespace NextDAADDebug
{
    public static class Font
    {
        public static byte[] Load()
        {
            using (var s = typeof(Font).Assembly.GetManifestResourceStream("NextDAADDebug.vga8x16.bin"))
            {
                if (s == null) throw new InvalidOperationException("font resource missing");
                var b = new byte[4096];
                int n = 0;
                while (n < b.Length)
                {
                    int r = s.Read(b, n, b.Length - n);
                    if (r <= 0) break;
                    n += r;
                }
                return b;
            }
        }
    }
}
