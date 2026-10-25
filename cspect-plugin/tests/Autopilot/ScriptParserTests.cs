using System;
using System.Collections.Generic;
using NextDAADDebug.Autopilot;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class ScriptParserTests
    {
        [Fact]
        public void ParsesEveryCommand()
        {
            string s = string.Join("\n", new[]
            {
                "wait status \"Running\" timeout 20",
                "wait screen \"Hall.\"",
                "wait game \"Welcome\"",
                "expect status \"Paused\"",
                "expect screen not \"Error\"",
                "expect game \"OK\"",
                "expect log \"hook\"",
                "expect colour \"Hall.\" Accent",
                "click \"Go\" rows 3-9",
                "click \"Stop\"",
                "click @12,7",
                "wheel -3 at \"Source\"",
                "wheel 2 at @5,6",
                "type \"abc\"",
                "key enter",
                "key esc",
                "hotkey b",
                "game \"GET LAMP\\n\"",
                "dump first",
                "note \"hello world\"",
                "measure ticks-while-halted",
                "quit",
            });
            List<Step> p = ScriptParser.Parse(s);
            Assert.Equal(22, p.Count);

            Assert.Equal(StepKind.WaitStatus, p[0].Kind);
            Assert.Equal("Running", p[0].Text);
            Assert.Equal(20, p[0].Timeout);
            Assert.Equal(1, p[0].Line);
            Assert.Equal(StepKind.WaitScreen, p[1].Kind);
            Assert.Equal(StepKind.WaitGame, p[2].Kind);

            Assert.Equal(StepKind.ExpectStatus, p[3].Kind);
            Assert.False(p[3].Not);
            Assert.Equal(StepKind.ExpectScreen, p[4].Kind);
            Assert.True(p[4].Not);
            Assert.Equal("Error", p[4].Text);
            Assert.Equal(StepKind.ExpectGame, p[5].Kind);
            Assert.Equal(StepKind.ExpectLog, p[6].Kind);
            Assert.Equal(StepKind.ExpectColour, p[7].Kind);
            Assert.Equal("Hall.", p[7].Text);
            Assert.Equal("Accent", p[7].Theme);

            Assert.Equal(StepKind.Click, p[8].Kind);
            Assert.Equal("Go", p[8].Text);
            Assert.Equal(3, p[8].FromRow);
            Assert.Equal(9, p[8].ToRow);
            Assert.Equal(0, p[9].FromRow);
            Assert.Equal(39, p[9].ToRow);
            Assert.Equal(StepKind.ClickCell, p[10].Kind);
            Assert.Equal(12, p[10].Col);
            Assert.Equal(7, p[10].Row);

            Assert.Equal(StepKind.Wheel, p[11].Kind);
            Assert.Equal(-3, p[11].Amount);
            Assert.Equal("Source", p[11].Text);
            Assert.Equal(StepKind.Wheel, p[12].Kind);
            Assert.Equal(2, p[12].Amount);
            Assert.Null(p[12].Text);
            Assert.Equal(5, p[12].Col);
            Assert.Equal(6, p[12].Row);

            Assert.Equal(StepKind.Type, p[13].Kind);
            Assert.Equal("abc", p[13].Text);
            Assert.Equal(StepKind.Key, p[14].Kind);
            Assert.Equal("enter", p[14].Text);
            Assert.Equal("esc", p[15].Text);
            Assert.Equal(StepKind.Hotkey, p[16].Kind);
            Assert.Equal("b", p[16].Text);
            Assert.Equal(StepKind.Game, p[17].Kind);
            Assert.Equal("GET LAMP\n", p[17].Text);
            Assert.Equal(StepKind.Dump, p[18].Kind);
            Assert.Equal("first", p[18].Text);
            Assert.Equal(StepKind.Note, p[19].Kind);
            Assert.Equal("hello world", p[19].Text);
            Assert.Equal(StepKind.Measure, p[20].Kind);
            Assert.Equal("ticks-while-halted", p[20].Text);
            Assert.Equal(StepKind.Quit, p[21].Kind);
            Assert.Equal("quit", p[21].Raw);
        }

        [Fact]
        public void RejectsUnknownCommandWithLineNumber()
        {
            var e = Assert.Throws<FormatException>(() => ScriptParser.Parse("quit\n\nfrobnicate \"x\"\n"));
            Assert.Contains("line 3", e.Message);
        }

        [Fact]
        public void ParsesQuotedTextWithSpacesAndEscapedQuote()
        {
            List<Step> p = ScriptParser.Parse("type \"say \\\"hi there\\\" now\"");
            Assert.Equal("say \"hi there\" now", p[0].Text);
        }

        [Fact]
        public void CrlfAndCommentsIgnored()
        {
            List<Step> p = ScriptParser.Parse("# top\r\n\r\nquit  # trailing\r\nnote \"a # b\"\r\n");
            Assert.Equal(2, p.Count);
            Assert.Equal(StepKind.Quit, p[0].Kind);
            Assert.Equal(3, p[0].Line);
            Assert.Equal("a # b", p[1].Text);
        }

        [Fact]
        public void DefaultTimeoutTen()
        {
            Assert.Equal(10, ScriptParser.Parse("wait screen \"x\"")[0].Timeout);
        }

        [Fact]
        public void GameNewlineEscape()
        {
            Assert.Equal("GET LAMP" + "\n", ScriptParser.Parse("game \"GET LAMP\\n\"")[0].Text);
        }

        [Fact]
        public void BadArgumentsAreFormatErrors()
        {
            Assert.Throws<FormatException>(() => ScriptParser.Parse("wait status"));
            Assert.Throws<FormatException>(() => ScriptParser.Parse("key tab"));
            Assert.Throws<FormatException>(() => ScriptParser.Parse("type \"unterminated"));
            Assert.Throws<FormatException>(() => ScriptParser.Parse("measure bogus"));
            Assert.Throws<FormatException>(() => ScriptParser.Parse("expect running now"));
            Assert.Throws<FormatException>(() => ScriptParser.Parse("wait window shut"));
        }

        [Fact]
        public void EscapesKnownOnly()
        {
            Assert.Equal("a\\b\b\"\n", ScriptParser.Parse("game \"a\\\\b\\b\\\"\\n\"")[0].Text);
            var e = Assert.Throws<FormatException>(() => ScriptParser.Parse("note \"ok\"\ngame \"tab\\there\""));
            Assert.Contains("line 2", e.Message);
            Assert.Contains("\\t", e.Message);
        }

        [Fact]
        public void ParsesRunningAndWindow()
        {
            List<Step> p = ScriptParser.Parse("expect running\nwait window closed timeout 3\nwait window open");
            Assert.Equal(StepKind.ExpectRunning, p[0].Kind);
            Assert.Equal(StepKind.WaitWindow, p[1].Kind);
            Assert.Equal("closed", p[1].Text);
            Assert.Equal(3, p[1].Timeout);
            Assert.Equal("open", p[2].Text);
            Assert.Equal(10, p[2].Timeout);
        }

        [Fact]
        public void LoadMissingScriptNamesIt()
        {
            string path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ndap-missing-" + Guid.NewGuid().ToString("N") + ".txt");
            var e = Assert.Throws<System.IO.FileNotFoundException>(() => ScriptParser.Load(path));
            Assert.Equal("script not found: " + path, e.Message);
        }
    }
}
