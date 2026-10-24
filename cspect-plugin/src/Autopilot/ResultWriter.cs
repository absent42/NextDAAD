using System.Collections.Generic;
using System.IO;
using System.Text;

namespace NextDAADDebug.Autopilot
{
    // autopilot-result.txt: STEP lines as they happen, then FACT lines, then DONE; dumps\NNN.txt per step.
    public sealed class ResultWriter
    {
        readonly string file, dumps;
        readonly List<string> facts = new List<string>();
        static readonly Encoding NoBom = new UTF8Encoding(false);
        int n;

        public ResultWriter(string folder)
        {
            dumps = Path.Combine(folder, "dumps");
            Directory.CreateDirectory(dumps);
            file = Path.Combine(folder, "autopilot-result.txt");
            File.WriteAllText(file, "");
        }

        static string One(string s) => (s ?? "").Replace("\r", "").Replace("\n", "\\n");

        void Line(string s) => File.AppendAllText(file, s + "\r\n", NoBom);

        public void Result(Step s, string verdict, string expected, string actual)
        {
            n++;
            Line("STEP " + n + " " + verdict + " line " + s.Line + " | " + One(s.Raw) +
                 " | expected " + One(expected) + " | actual " + One(actual));
        }

        public void Fact(string name, string value) => facts.Add("FACT " + name + "=" + One(value));

        public void Dump(int index, CellScreen screen, string[] game)
        {
            var sb = new StringBuilder();
            if (screen != null)
                for (int y = 0; y < screen.Rows; y++) sb.Append(Printable(screen.RowText(y)).TrimEnd()).Append("\r\n");
            sb.Append("\r\n");
            if (game == null) sb.Append("(game screen not readable)\r\n");
            else foreach (string r in game) sb.Append((r ?? "").TrimEnd()).Append("\r\n");
            File.WriteAllText(Path.Combine(dumps, index.ToString("D3") + ".txt"), sb.ToString(), NoBom);
        }

        // CP437 glyphs outside printable ASCII become '?', as in TilemapText; glyph 0 is blank.
        static string Printable(string row)
        {
            var c = row.ToCharArray();
            for (int i = 0; i < c.Length; i++) c[i] = c[i] == 0 ? ' ' : c[i] < 32 || c[i] > 126 ? '?' : c[i];
            return new string(c);
        }

        public void Finish(int failures)
        {
            foreach (string f in facts) Line(f);
            facts.Clear();
            Line("DONE failures=" + failures);
        }
    }
}
