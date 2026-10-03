using System;
using System.Linq;
using System.Text;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class ParserTests
    {
        public static string Sym(string nl = "\n", bool bom = false, string version = "1", string dropHook = null, string flagsAddr = "A200")
        {
            var sb = new StringBuilder();
            if (bom) sb.Append('﻿');
            sb.Append("NEXTDAAD-SYM\t" + version + nl);
            sb.Append("# comment" + nl);
            sb.Append("build\tabc1234\tRelease  " + nl);
            string[] names = SymbolFile.RequiredSymbols;
            for (int i = 0; i < names.Length; i++)
            {
                string a = names[i] == "flags" ? flagsAddr : names[i] == "objTable" ? "A300" : names[i] == "numObj" ? "A900" : (0xAA00 + i * 0x40).ToString("X4");
                sb.Append("sym\t" + names[i] + "\t" + a + nl);
            }
            string chk = string.Concat(Enumerable.Range(0, 32).Select(i => (0xC0 + i).ToString("X2")));
            if (dropHook != "eng_exec") sb.Append("hook\teng_exec\t9E21\t04\t" + chk + nl);
            if (dropHook != "err_raise") sb.Append("hook\terr_raise\tA973\t05\t" + chk + nl);
            return sb.ToString();
        }

        [Fact]
        public void SymbolFileParses()
        {
            var s = SymbolFile.Parse(Sym());
            Assert.Equal("abc1234", s.Build);
            Assert.Equal("Release", s.Variant);
            Assert.Equal(0xA200, s["flags"]);
            Assert.Equal(0xA300, s["objTable"]);
            var h = s.Hook("eng_exec");
            Assert.Equal(0x9E21, h.Address);
            Assert.Equal(4, h.Page);
            Assert.Equal(32, h.Check.Length);
            Assert.Equal(0xC0, h.Check[0]);
            Assert.Equal(0xDF, h.Check[31]);
            Assert.Equal(0x9E21, s["eng_exec"]);
        }

        [Fact]
        public void ParsesCrlfAndBom()
        {
            var a = SymbolFile.Parse(Sym());
            var b = SymbolFile.Parse(Sym("\r\n", bom: true));
            Assert.Equal(a.Build, b.Build);
            Assert.Equal(a.Variant, b.Variant);
            Assert.Equal(a["cprops"], b["cprops"]);
            Assert.Equal(a.Hook("err_raise").Check, b.Hook("err_raise").Check);
            var m1 = SourceMap.Parse(Dsm("\n"));
            var m2 = SourceMap.Parse("﻿" + Dsm("\r\n"));
            Assert.Equal(m1.DdbCrc, m2.DdbCrc);
            Assert.Equal(m1.Files[0], m2.Files[0]);
            Assert.Equal(m1.Condacts.Count, m2.Condacts.Count);
        }

        [Fact]
        public void SymbolFileRejectsWrongVersion()
        {
            var ex = Assert.Throws<FormatException>(() => SymbolFile.Parse(Sym(version: "2")));
            Assert.Contains("version 2", ex.Message);
            Assert.Contains("version 1", ex.Message);
        }

        [Fact]
        public void SymbolFileRejectsMissingHook()
        {
            var ex = Assert.Throws<FormatException>(() => SymbolFile.Parse(Sym(dropHook: "err_raise")));
            Assert.Contains("err_raise", ex.Message);
        }

        [Fact]
        public void SymbolFileRejectsMovedAnchor()
        {
            var ex = Assert.Throws<FormatException>(() => SymbolFile.Parse(Sym(flagsAddr: "A100")));
            Assert.Contains("anchors", ex.Message);
        }

        [Fact]
        public void Crc32KnownValue()
        {
            var d = Encoding.ASCII.GetBytes("123456789");
            Assert.Equal(0xCBF43926u, Crc32.Compute(d, 0, d.Length));
        }

        public static string Dsm(string nl)
        {
            return "NDRC-DSM\t1" + nl +
                   "ddb\tCBF43926\t9" + nl +
                   "file\t0\tGAME.DSF" + nl +
                   "file\t1\tinc\\more.dsf" + nl +
                   "proc\t0\t0\t100" + nl +
                   "entry\t0120\t0\t101" + nl +
                   "cond\t0130\t0\t101\t9" + nl +
                   "cond\t0124\t0\t101\t20" + nl +
                   "cond\t0140\t1\t7\t9" + nl +
                   "sym\tfCounter\t100" + nl +
                   "sym\toLamp\t100" + nl +
                   "sym\tlCellar\t1" + nl;
        }

        [Fact]
        public void SourceMapParsesAndLooksUp()
        {
            var m = SourceMap.Parse(Dsm("\n"));
            Assert.Equal(0xCBF43926u, m.DdbCrc);
            Assert.Equal(9, m.DdbLength);
            Assert.Equal("inc\\more.dsf", m.Files[1]);
            Assert.Equal(100, m.Processes[0].Line);
            Assert.Equal(101, m.Entries[0x120].Line);
            SourceLoc loc;
            Assert.True(m.TryLocate(0x140, out loc));
            Assert.Equal(1, loc.File);
            Assert.Equal(7, loc.Line);
            Assert.False(m.TryLocate(0x141, out loc));
            Assert.Equal(new[] { 0x124, 0x130 }, m.OffsetsForLine(0, 101).ToArray());
            Assert.Equal(new[] { "fCounter", "oLamp" }, m.NamesForValue(100).ToArray());
            int v;
            Assert.True(m.TryResolveName("LCELLAR", out v));
            Assert.Equal(1, v);
            Assert.False(m.TryResolveName("nope", out v));
        }

        [Fact]
        public void SourceMapMatchesDdbByCrc()
        {
            var m = SourceMap.Parse(Dsm("\n"));
            var good = new byte[16];
            Encoding.ASCII.GetBytes("123456789").CopyTo(good, 0);
            Assert.True(m.Matches(good));
            good[0] = (byte)'0';
            Assert.False(m.Matches(good));
            Assert.False(m.Matches(new byte[4]));
        }

        [Fact]
        public void SourceMapNeedsDdbRecord()
        {
            Assert.Throws<FormatException>(() => SourceMap.Parse("NDRC-DSM\t1\nfile\t0\tA.DSF\n"));
        }
    }
}
