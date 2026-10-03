using System.Collections.Generic;
using System.IO;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class CondactsTests
    {
        [Fact]
        public void TableShape()
        {
            Assert.Equal(128, Condacts.Table.Length);
            var names = new HashSet<string>();
            foreach (var c in Condacts.Table)
            {
                Assert.True(names.Add(c.Name), "duplicate " + c.Name);
                Assert.Equal(c.Argc, c.Kinds.Length);
            }
            Assert.Equal("PARSE", Condacts.Table[Condacts.Parse].Name);
            Assert.Equal("INDIR", Condacts.Table[Condacts.Indir].Name);
            Assert.Equal(1, Condacts.Table[Condacts.Indir].Argc);
            Assert.Equal(ArgKind.Signed, Condacts.Table[116].Kinds[0]);
            Assert.Equal(ArgKind.Message, Condacts.Table[77].Kinds[0]);
            Assert.Equal(ArgKind.Object, Condacts.Table[46].Kinds[0]);
            Assert.Equal(ArgKind.Location, Condacts.Table[46].Kinds[1]);
        }

        [Fact]
        public void Terminators()
        {
            foreach (byte t in new byte[] { 22, 23, 103, 116, 117, 108 }) Assert.True(Condacts.IsTerminatorByte(t));
            Assert.False(Condacts.IsTerminatorByte(116 | 0x80));
            Assert.False(Condacts.IsTerminatorByte(51));
        }

        // Needs a built interpreter: run build.ps1 first.
        [Fact]
        public void MatchesInterpreterCprops()
        {
            string symPath = Path.Combine(Repo.Root, "build", "NEXTDAAD.SYM");
            string nexPath = Path.Combine(Repo.Root, "build", "nextdaad.nex");
            Assert.True(File.Exists(symPath) && File.Exists(nexPath), "run build.ps1 first: " + symPath);
            var sym = SymbolFile.Parse(File.ReadAllText(symPath));
            byte[] cprops = NexImage.ReadLogical(nexPath, sym["cprops"], 128);
            for (int n = 0; n < 128; n++)
            {
                Assert.True((cprops[n] & 3) == Condacts.Table[n].Argc, "argc of " + n + " " + Condacts.Table[n].Name);
                Assert.True(((cprops[n] & 0x80) != 0) == Condacts.Table[n].IsAction, "action of " + n + " " + Condacts.Table[n].Name);
            }
        }
    }
}
