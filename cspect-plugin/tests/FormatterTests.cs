using System.IO;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class FormatterTests
    {
        static Ddb Fix() => new Ddb(File.ReadAllBytes(Repo.Fixture("DBGFIX.DDB")));
        static DecodedCondact D(params byte[] bytes) => new Ddb(bytes).DecodeAt(0);

        [Fact]
        public void Plain()
        {
            Assert.Equal("LET @100 3", CondactFormatter.Plain(D(0xB3, 100, 3)));
            Assert.Equal("SKIP -2", CondactFormatter.Plain(D(116, 254)));
            Assert.Equal("DEBUG", CondactFormatter.Plain(D(0xDC)));
            Assert.Equal("(end)", CondactFormatter.Plain(D(0xFF)));
            Assert.Equal("CLS", CondactFormatter.Plain(D(29)));
        }

        [Fact]
        public void Rich()
        {
            var d = Fix();
            var flags = new byte[256];
            flags[38] = 1;
            Assert.Equal("MES 1 \"The lamp glows.\"", CondactFormatter.Rich(D(77, 1), d, flags));
            Assert.Equal("GET 0 (lamp)", CondactFormatter.Rich(D(40, 0), d, flags));
            Assert.Equal("DESC @38(=1)", CondactFormatter.Rich(D(0x80 | 19, 38), d, flags));
            Assert.Equal("PLACE 0 (lamp) 254 (carried)", CondactFormatter.Rich(D(46, 0, 254), d, flags));
            Assert.Equal("SYSMESS 6 \"I didn't understand.\"", CondactFormatter.Rich(D(54, 6), d, flags));
            Assert.Equal("NOUN2 LAMP", CondactFormatter.Rich(D(69, 50), d, flags));
            Assert.Equal("GOTO 1 (Cellar.)", CondactFormatter.Rich(D(37, 1), d, flags));
            Assert.Equal("LET 100 7", CondactFormatter.Rich(D(51, 100, 7), d, flags));
            Assert.Equal("MES 9", CondactFormatter.Rich(D(77, 9), null, null));
            Assert.Equal("DESC @38", CondactFormatter.Rich(D(0x80 | 19, 38), d, null));
        }

        [Fact]
        public void TraceWritesMarkerAndFollower()
        {
            var d = Fix();
            var e = d.Entries(0)[0];
            var list = d.EntryCondacts(e.CondactOffset);
            string path = Path.GetTempFileName();
            using (var t = new TraceWriter(path)) t.Write(new ProcFrame(0, e.HeaderOffset, list[2].Offset), list[2], d);
            string[] lines = File.ReadAllLines(path);
            Assert.Equal(2, lines.Length);
            Assert.Equal("P0 E" + e.HeaderOffset.ToString("X4") + " C" + list[2].Offset.ToString("X4") + " DEBUG", lines[0]);
            Assert.Equal("P0 E" + e.HeaderOffset.ToString("X4") + " C" + list[3].Offset.ToString("X4") + " PROCESS 1", lines[1]);
        }
    }
}
