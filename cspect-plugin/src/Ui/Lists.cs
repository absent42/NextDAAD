using System;
using System.Collections.Generic;
using System.Linq;

namespace NextDAADDebug
{
    // Picker contents and flag labels. System flag names follow src/nextdaad.inc FLAG_*.
    public static class Lists
    {
        static readonly Dictionary<int, string> SystemFlags = new Dictionary<int, string>
        {
            { 0, "Dark" }, { 1, "Carried count" }, { 25, "Obj2 number" }, { 26, "Obj2 container" }, { 27, "Obj2 location" },
            { 29, "Graphics flags" }, { 30, "Score" }, { 31, "Turns low" }, { 32, "Turns high" }, { 33, "Verb" },
            { 34, "Noun1" }, { 35, "Adjective1" }, { 36, "Adverb" }, { 37, "Max carried" }, { 38, "Player location" },
            { 39, "Obj2 attributes" }, { 41, "Input stream" }, { 42, "Prompt" }, { 43, "Preposition" }, { 44, "Noun2" },
            { 45, "Adjective2" }, { 46, "Pronoun noun" }, { 47, "Pronoun adjective" }, { 48, "Timeout" }, { 49, "Timeout control" },
            { 50, "DOALL location" }, { 51, "Current object" }, { 52, "Strength" }, { 53, "Object flags" }, { 54, "CO location" },
            { 55, "CO weight" }, { 56, "CO container" }, { 57, "CO wearable" }, { 58, "CO attrs 8-15" }, { 59, "CO attrs 0-7" },
            { 60, "Key 1" }, { 61, "Key 2" }, { 62, "Screen mode" }, { 63, "Current window" },
        };

        public static string FlagLabel(int f, SourceMap map)
        {
            string s;
            if (SystemFlags.TryGetValue(f, out s)) return s;
            if (map != null)
            {
                var names = map.NamesForValue(f);
                if (names.Count > 0) return string.Join("/", names);
            }
            return "";
        }

        public static string FlagHint(int f, int v, Ddb ddb)
        {
            if (ddb == null) return "";
            switch (f)
            {
                case 33: return ddb.WordFor(v, WordType.Verb) ?? "";
                case 34: case 44: return ddb.WordFor(v, WordType.Noun) ?? "";
                case 35: case 45: return ddb.WordFor(v, WordType.Adjective) ?? "";
                case 36: return ddb.WordFor(v, WordType.Adverb) ?? "";
                case 43: return ddb.WordFor(v, WordType.Preposition) ?? "";
                case 38: return CondactFormatter.LocationName(ddb, v) ?? "";
                default: return "";
            }
        }

        public static List<PickItem> Flags(Ddb ddb, SourceMap map) =>
            Enumerable.Range(0, 256).Select(f => new PickItem(f.ToString().PadLeft(3) + "  " + FlagLabel(f, map), f)).ToList();

        public static List<PickItem> Objects(Ddb ddb)
        {
            int n = ddb == null ? 0 : ddb.NumObjects;
            return Enumerable.Range(0, n).Select(o => new PickItem(o.ToString().PadLeft(3) + "  " + (CondactFormatter.ObjectName(ddb, o) ?? ""), o)).ToList();
        }

        public static List<PickItem> Locations(Ddb ddb)
        {
            var r = new List<PickItem>();
            foreach (int l in new[] { 252, 253, 254, 255 }) r.Add(new PickItem(l + "  " + CondactFormatter.LocationName(ddb, l), l));
            int n = ddb == null ? 0 : ddb.NumLocations;
            for (int l = 0; l < n; l++) r.Add(new PickItem(l.ToString().PadLeft(3) + "  " + CondactFormatter.LocationName(ddb, l), l));
            return r;
        }

        public static List<PickItem> Processes(Ddb ddb)
        {
            int n = ddb == null ? 0 : ddb.NumProcesses;
            return Enumerable.Range(0, n).Select(p => new PickItem("PRO " + p, p)).ToList();
        }

        public static List<PickItem> CondactNames() =>
            Enumerable.Range(0, 128).Select(n => new PickItem(Condacts.Table[n].Name, n)).OrderBy(p => p.Label, StringComparer.Ordinal).ToList();

        public static List<PickItem> Words(Ddb ddb, WordType t, bool withAny)
        {
            var r = new List<PickItem>();
            if (withAny)
            {
                r.Add(new PickItem("(any)", -1));
                r.Add(new PickItem("_  255", 255));
            }
            if (ddb == null) return r;
            var words = ddb.Vocabulary.Where(v => v.Type == t || (t == WordType.Verb && v.Type == WordType.Noun && v.Number < 20));
            r.AddRange(words.OrderBy(v => v.Word, StringComparer.Ordinal).Select(v => new PickItem(v.Word + "  " + v.Number, v.Number)));
            return r;
        }

        public static List<PickItem> Symbols(SourceMap map)
        {
            if (map == null) return new List<PickItem>();
            return map.Symbols.OrderBy(s => s.Key, StringComparer.OrdinalIgnoreCase).Select(s => new PickItem(s.Key + " = " + s.Value, s.Value)).ToList();
        }

        public static List<PickItem> WatchKinds() => new List<PickItem> { new PickItem("as flag", 0), new PickItem("as object", 1) };

        public static List<PickItem> BreakKinds() => new List<PickItem>
        {
            new PickItem("DEBUG marker", (int)BreakKind.DebugMarker),
            new PickItem("Process / entry", (int)BreakKind.Process),
            new PickItem("Condact", (int)BreakKind.Condact),
            new PickItem("Flag changes", (int)BreakKind.FlagChange),
            new PickItem("Flag compare", (int)BreakKind.FlagCompare),
            new PickItem("Object moves", (int)BreakKind.ObjectMoved),
            new PickItem("Runtime error", (int)BreakKind.RuntimeError),
        };

        public static List<PickItem> CompareOps() => new List<PickItem>
        {
            new PickItem("=", (int)CompareOp.Eq), new PickItem("<>", (int)CompareOp.Ne),
            new PickItem("<", (int)CompareOp.Lt), new PickItem(">", (int)CompareOp.Gt),
        };
    }
}
