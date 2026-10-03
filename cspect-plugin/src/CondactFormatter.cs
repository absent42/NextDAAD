using System.Text;

namespace NextDAADDebug
{
    public static class CondactFormatter
    {
        // Numbers only: "LET @100 3". Trace lines use this form.
        public static string Plain(DecodedCondact c)
        {
            if (c.IsEnd) return "(end)";
            if (c.IsMarker) return "DEBUG";
            var info = c.Info;
            var sb = new StringBuilder(info.Name);
            for (int i = 0; i < c.Args.Length; i++)
            {
                sb.Append(' ');
                bool ind = i == 0 && c.Indirect;
                if (ind) sb.Append('@');
                bool signed = !ind && i < info.Argc && info.Kinds[i] == ArgKind.Signed;
                sb.Append(signed ? ((sbyte)(byte)c.Args[i]).ToString() : c.Args[i].ToString());
            }
            return sb.ToString();
        }

        // Names and live values for the UI: "PLACE 0 (lamp) 254 (carried)", "DESC @38(=1)".
        public static string Rich(DecodedCondact c, Ddb ddb, byte[] flags)
        {
            if (c.IsEnd || c.IsMarker) return Plain(c);
            var info = c.Info;
            var sb = new StringBuilder(info.Name);
            for (int i = 0; i < c.Args.Length; i++)
            {
                sb.Append(' ');
                int v = c.Args[i];
                if (i == 0 && c.Indirect)
                {
                    sb.Append('@').Append(v);
                    if (flags != null) sb.Append("(=").Append(flags[v & 0xFF]).Append(')');
                    continue;
                }
                sb.Append(Arg(i < info.Argc ? info.Kinds[i] : ArgKind.Value, v, ddb));
            }
            return sb.ToString();
        }

        public static string Arg(ArgKind k, int v, Ddb ddb)
        {
            switch (k)
            {
                case ArgKind.Signed: return ((sbyte)(byte)v).ToString();
                case ArgKind.Object: return v + Paren(ObjectName(ddb, v));
                case ArgKind.Location: return v + Paren(LocationName(ddb, v));
                case ArgKind.Message: return v + Quote(ddb == null ? null : ddb.Message(v));
                case ArgKind.SysMessage: return v + Quote(ddb == null ? null : ddb.SysMessage(v));
                case ArgKind.Verb: return Word(ddb, v, WordType.Verb);
                case ArgKind.Noun: return Word(ddb, v, WordType.Noun);
                case ArgKind.Adjective: return Word(ddb, v, WordType.Adjective);
                case ArgKind.Adverb: return Word(ddb, v, WordType.Adverb);
                case ArgKind.Preposition: return Word(ddb, v, WordType.Preposition);
                default: return v.ToString();
            }
        }

        public static string Word(Ddb ddb, int v, WordType t)
        {
            string w = ddb == null ? null : ddb.WordFor(v, t);
            return w ?? v.ToString();
        }

        public static string ObjectName(Ddb ddb, int o)
        {
            if (ddb == null || o < 0 || o >= ddb.NumObjects) return null;
            string w = ddb.WordFor(ddb.ObjectNoun(o), WordType.Noun);
            return w == null || w == "_" ? null : w.ToLowerInvariant();
        }

        public static string LocationName(Ddb ddb, int l)
        {
            switch (l)
            {
                case 252: return "not created";
                case 253: return "worn";
                case 254: return "carried";
                case 255: return "here";
            }
            if (ddb == null) return null;
            string t = ddb.Location(l);
            return t == null ? null : Clip(FirstLine(t), 24);
        }

        public static string Clip(string s, int n) => s.Length <= n ? s : s.Substring(0, n - 3) + "...";

        static string FirstLine(string s)
        {
            int i = s.IndexOf('\n');
            return (i < 0 ? s : s.Substring(0, i)).Trim();
        }

        static string Paren(string s) => s == null ? "" : " (" + s + ")";
        static string Quote(string s) => s == null ? "" : " \"" + Clip(FirstLine(s), 30) + "\"";
    }
}
