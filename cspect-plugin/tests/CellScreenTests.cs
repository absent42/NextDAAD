using System.Linq;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class CellScreenTests
    {
        [Fact]
        public void FontLoads()
        {
            byte[] f = Font.Load();
            Assert.Equal(4096, f.Length);
            Assert.True(Enumerable.Range(0, 16).All(r => f[32 * 16 + r] == 0), "space is blank");
            Assert.True(Enumerable.Range(0, 16).All(r => f[0xDB * 16 + r] == 0xFF), "CP437 DB is a full block");
            int bitsA = Enumerable.Range(0, 16).Sum(r => Bits(f['A' * 16 + r]));
            Assert.InRange(bitsA, 20, 60);
        }

        static int Bits(byte b) { int n = 0; for (; b != 0; b >>= 1) n += b & 1; return n; }

        [Fact]
        public void TextClipsAndCounts()
        {
            var s = new CellScreen(10, 2);
            s.Clear(Theme.Bg);
            Assert.Equal(6, s.Text(8, 0, "abcdef", Theme.Text, Theme.Bg));   // 6 written, 2 visible
            Assert.Equal("        ab", s.RowText(0));
            Assert.Equal(3, s.Text(0, 1, "xyz123", Theme.Text, Theme.Bg, 3));
            Assert.Equal("xyz       ", s.RowText(1));
            s.Put(-1, 0, (byte)'Q', Theme.Text, Theme.Bg);
            s.Put(0, 5, (byte)'Q', Theme.Text, Theme.Bg);
            Assert.DoesNotContain("Q", s.RowText(0) + s.RowText(1));
        }

        [Fact]
        public void MapReplacesWideChars()
        {
            Assert.Equal((byte)'?', CellScreen.Map('\u20AC'));
            Assert.Equal((byte)' ', CellScreen.Map('\n'));
            Assert.Equal((byte)'A', CellScreen.Map('A'));
        }

        [Fact]
        public void FindLocatesText()
        {
            var s = new CellScreen(20, 3);
            s.Clear(Theme.Bg);
            s.Text(4, 2, "Step out", Theme.Text, Theme.Bg);
            int x, y;
            Assert.True(s.Find("out", out x, out y));
            Assert.Equal(9, x);
            Assert.Equal(2, y);
            Assert.False(s.Find("nope", out x, out y));
        }

        [Fact]
        public void RenderUsesPaletteAndGlyphBits()
        {
            var s = new CellScreen(2, 1);
            s.Clear(Theme.Bg);
            s.Put(0, 0, 0xDB, Theme.Error, Theme.Bg);
            var font = Font.Load();
            var pal = Theme.Palette(true);
            var px = new uint[16 * 16];
            s.Render(px, font, pal);
            Assert.Equal(pal[Theme.Error], px[0]);
            Assert.Equal(pal[Theme.Error], px[15 * 16 + 7]);
            Assert.Equal(pal[Theme.Bg], px[8]);                              // second cell is a space
            Assert.Equal(0xFF000000u, pal[0] & 0xFF000000u);
            var abgr = Theme.Palette(false);
            Assert.Equal(((pal[Theme.Error] & 0xFF) << 16) | (pal[Theme.Error] & 0xFF00) | ((pal[Theme.Error] >> 16) & 0xFF) | 0xFF000000u, abgr[Theme.Error]);
        }
    }
}
