using System;
using System.IO;
using System.Linq;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class DdbTests
    {
        static Ddb Fix() => new Ddb(File.ReadAllBytes(Repo.Fixture("DBGFIX.DDB")));

        static string[] Texts(Ddb d, int start) => d.EntryCondacts(start).Select(c => CondactText(c)).ToArray();

        // Plain text without the formatter (Task 7) so this task stands alone.
        static string CondactText(DecodedCondact c)
        {
            if (c.IsEnd) return "(end)";
            if (c.IsMarker) return "DEBUG";
            string s = c.Info.Name;
            for (int i = 0; i < c.Args.Length; i++) s += " " + (i == 0 && c.Indirect ? "@" : "") + c.Args[i];
            return s;
        }

        [Fact]
        public void Header()
        {
            var d = Fix();
            Assert.Equal(3, d.Version);
            Assert.Equal(0x0C, d.Machine);
            Assert.Equal(2, d.NumObjects);
            Assert.Equal(2, d.NumLocations);
            Assert.Equal(2, d.NumMessages);
            Assert.Equal(61, d.NumSysMessages);
            Assert.Equal(4, d.NumProcesses);
            Assert.True(Ddb.LooksLikeNextDaad(d.Image));
            Assert.False(Ddb.LooksLikeNextDaad(new byte[34]));
        }

        [Fact]
        public void Texts_()
        {
            var d = Fix();
            Assert.Equal("The lamp glows.", d.Message(1));
            Assert.Equal("Hello.", d.Message(0));
            Assert.Equal("Cellar.", d.Location(1));
            Assert.Equal("a brass lamp", d.ObjectText(0));
            Assert.Equal("I didn't understand.", d.SysMessage(6));
            Assert.Null(d.Message(2));
            Assert.Null(d.Location(-1));
            Assert.False(string.IsNullOrEmpty(d.Token(0)));
        }

        [Fact]
        public void MessageExpandsToken()
        {
            var img = new byte[44];
            img[5] = 1;                 // NumMessages
            img[8] = 34;                // TokensPtr
            img[16] = 39;               // MsgList
            // tokens: placeholder string 0, then "the " (bit 7 on the last char)
            img[34] = 0xF8; img[35] = (byte)'t'; img[36] = (byte)'h'; img[37] = (byte)'e'; img[38] = (byte)(' ' | 0x80);
            img[39] = 41;               // message 0 at 41
            img[41] = 0x80 ^ 0xFF;      // token 0
            img[42] = (byte)('!' ^ 0xFF);
            img[43] = 0x0A ^ 0xFF;
            Assert.Equal("the !", new Ddb(img).Message(0));
        }

        [Fact]
        public void Vocabulary()
        {
            var d = Fix();
            Assert.Contains(d.Vocabulary, v => v.Word == "LAMP" && v.Number == 50 && v.Type == WordType.Noun);
            Assert.Contains(d.Vocabulary, v => v.Word == "GET" && v.Number == 20 && v.Type == WordType.Verb);
            Assert.Equal("BRASS", d.WordFor(2, WordType.Adjective));
            Assert.Equal("QUICK", d.WordFor(2, WordType.Adverb));
            Assert.Equal("_", d.WordFor(255, WordType.Noun));
            Assert.Null(d.WordFor(99, WordType.Noun));
            Assert.Contains(d.WordFor(3, WordType.Verb), new[] { "S", "SOUTH" });   // movement noun < 20 acts as verb
        }

        [Fact]
        public void ConnectionsAndObjects()
        {
            var d = Fix();
            var c0 = d.Connections(0);
            Assert.Single(c0);
            Assert.Equal(3, c0[0].Word);
            Assert.Equal(1, c0[0].Destination);
            Assert.Equal(0, d.Connections(1)[0].Destination);
            Assert.Empty(d.Connections(5));
            Assert.Equal(0, d.ObjectInitialLocation(0));
            Assert.Equal(254, d.ObjectInitialLocation(1));
            Assert.Equal(50, d.ObjectNoun(0));
            Assert.Equal(2, d.ObjectAdjective(0));
            Assert.Equal(255, d.ObjectAdjective(1));
            Assert.Equal(3, Ddb.Weight(d.ObjectAttr(0)));
            Assert.False(Ddb.IsContainer(d.ObjectAttr(0)));
            Assert.False(Ddb.IsWearable(d.ObjectAttr(0)));
            Assert.True(Ddb.IsWearable(0x80));
            Assert.True(Ddb.IsContainer(0x40));
        }

        [Fact]
        public void ProcessTablesAndCondacts()
        {
            var d = Fix();
            var e0 = d.Entries(0);
            Assert.Equal(3, e0.Count);
            Assert.Equal(255, e0[0].Verb);
            Assert.Equal(e0[0].CondactOffset, d.EntryCondactStart(e0[0].HeaderOffset));
            Assert.Equal(new[] { "LET 100 7", "LET @100 3", "DEBUG", "PROCESS 1", "(end)" }, Texts(d, e0[0].CondactOffset));
            Assert.Equal(new[] { "PARSE 0", "SYSMESS 6", "REDO" }, Texts(d, e0[1].CondactOffset));
            Assert.Equal(new[] { "PROCESS 2", "REDO" }, Texts(d, e0[2].CondactOffset));
            var e2 = d.Entries(2);
            Assert.Equal(5, e2.Count);
            Assert.Equal(20, e2[1].Verb);
            Assert.Equal(50, e2[1].Noun);
            Assert.Equal(new[] { "PROCESS 3", "DONE" }, Texts(d, e2[3].CondactOffset));
            Assert.Equal(new[] { "PROCESS 3", "(end)" }, Texts(d, d.Entries(3)[0].CondactOffset));
            Assert.Single(d.Entries(3));
            Assert.Empty(d.Entries(4));
            var marker = d.EntryCondacts(e0[0].CondactOffset)[2];
            Assert.True(marker.IsMarker);
            Assert.Equal(1, marker.Length);
        }

        [Fact]
        public void ExternXmessageThirdByte()
        {
            var img = new byte[64];
            img[40] = Condacts.Extern; img[41] = 0x10; img[42] = 3; img[43] = 0x02; img[44] = 0xFF;
            var d = new Ddb(img).DecodeAt(40);
            Assert.Equal(new[] { 0x10, 3, 0x02 }, d.Args);
            Assert.Equal(4, d.Length);
            var e = new Ddb(new byte[] { Condacts.Extern, 5, 4, 0xFF }).DecodeAt(0);
            Assert.Equal(3, e.Length);
        }

        [Fact]
        public void GarbageImageNeverThrows()
        {
            var rnd = new Random(1234);
            foreach (var img in new[] { new byte[0], new byte[34], new byte[65536], Rand(rnd, 65536), Rand(rnd, 100) })
            {
                var d = new Ddb(img);
                for (int n = -1; n < 256; n++)
                {
                    d.Message(n); d.SysMessage(n); d.Location(n); d.ObjectText(n); d.Token(n);
                    d.Connections(n); d.Entries(n);
                    d.ObjectNoun(n); d.ObjectAdjective(n); d.ObjectAttr(n); d.ObjectExtAttr(n); d.ObjectInitialLocation(n);
                    d.WordFor(n, WordType.Noun);
                }
                var v = d.Vocabulary;
                for (int i = 0; i < 300; i++)
                {
                    int off = rnd.Next(-5, 70000);
                    d.DecodeAt(off);
                    d.EntryCondacts(off);
                    d.Text(off);
                }
            }
        }

        static byte[] Rand(Random r, int n) { var b = new byte[n]; r.NextBytes(b); return b; }
    }
}
