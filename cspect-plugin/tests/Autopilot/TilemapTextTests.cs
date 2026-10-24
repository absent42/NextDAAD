using NextDAADDebug.Autopilot;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class TilemapTextTests
    {
        const ushort ColsAddr = 0x9000;
        const int Map = 0x16000;

        static void Put(FakeMachine m, int stride, int row, int col, string s)
        {
            for (int i = 0; i < s.Length; i++)
            {
                m.Phys[Map + row * stride + (col + i) * 2] = (byte)s[i];
                m.Phys[Map + row * stride + (col + i) * 2 + 1] = 0x77;
            }
        }

        static FakeMachine Make(int cols)
        {
            var m = new FakeMachine();
            m.Mem[ColsAddr] = (byte)cols;
            for (int i = 0; i < 32 * cols * 2; i += 2) m.Phys[Map + i] = (byte)' ';
            return m;
        }

        [Fact]
        public void Reads80ColumnRows()
        {
            var m = Make(80);
            Put(m, 160, 3, 0, "Hall.");
            string[] rows = TilemapText.Read(m, ColsAddr);
            Assert.Equal(32, rows.Length);
            Assert.All(rows, r => Assert.Equal(80, r.Length));
            Assert.StartsWith("Hall.", rows[3]);
        }

        [Fact]
        public void Reads40ColumnRows()
        {
            var m = Make(40);
            Put(m, 80, 5, 2, "Cave");
            Put(m, 80, 6, 0, "Next");
            string[] rows = TilemapText.Read(m, ColsAddr);
            Assert.Equal(32, rows.Length);
            Assert.All(rows, r => Assert.Equal(40, r.Length));
            Assert.Equal("Cave", rows[5].Substring(2, 4));
            Assert.StartsWith("Next", rows[6]);
        }

        [Fact]
        public void NonPrintableBecomesQuestionMark()
        {
            var m = Make(80);
            m.Phys[Map] = 0x01;
            m.Phys[Map + 2] = 0xFF;
            m.Phys[Map + 4] = 127;
            m.Phys[Map + 6] = (byte)'~';
            Assert.StartsWith("???~", TilemapText.Read(m, ColsAddr)[0]);
        }

        [Fact]
        public void ContainsSpansNoRows()
        {
            var m = Make(40);
            Put(m, 80, 0, 36, "ab");
            Put(m, 80, 1, 0, "cd");
            string[] rows = TilemapText.Read(m, ColsAddr);
            Assert.True(TilemapText.Contains(rows, "ab"));
            Assert.True(TilemapText.Contains(rows, "cd"));
            Assert.False(TilemapText.Contains(rows, "abcd"));
        }

        [Fact]
        public void BadColumnCountIsRejected()
        {
            var m = Make(80);
            m.Mem[ColsAddr] = 0;
            Assert.Throws<System.InvalidOperationException>(() => TilemapText.Read(m, ColsAddr));
        }
    }
}
