using System;
using System.Collections.Generic;
using System.IO;

namespace NextDAADDebug
{
    // GAME.DSM is part 1, GAME2.DSM..GAME9.DSM the other parts; an unreadable file is skipped.
    public sealed class MapSet
    {
        public const string NoMapText = "no source map";
        public const string OutOfDateText = "source map is out of date - rebuild";

        public readonly List<SourceMap> Maps = new List<SourceMap>();
        public readonly List<string> Problems = new List<string>();   // "<file>: <why>", in part order
        public readonly List<string> Missing = new List<string>();    // absent below the highest part found

        public MapSet(IEnumerable<SourceMap> maps = null)
        {
            if (maps != null) Maps.AddRange(maps);
        }

        public static string FileName(int part) => part == 1 ? "GAME.DSM" : "GAME" + part + ".DSM";

        public static MapSet Load(string folder)
        {
            var s = new MapSet();
            int top = 0;
            for (int part = 1; part <= 9; part++)
                if (File.Exists(Path.Combine(folder, FileName(part)))) top = part;
            for (int part = 1; part <= top; part++)
            {
                string name = FileName(part), path = Path.Combine(folder, name);
                if (!File.Exists(path)) { s.Missing.Add(name); continue; }
                try { s.Maps.Add(SourceMap.Parse(File.ReadAllText(path))); }
                catch (Exception ex) { s.Problems.Add(name + ": " + ex.Message); }
            }
            return s;
        }

        // The debugger.log "armed" line ends with this.
        public string LogText => Maps.Count == 0 ? ", no source map" : Maps.Count == 1 ? ", source map loaded" : ", source maps loaded (" + Maps.Count + ")";

        // Source tab text when no map was read at all.
        public string NothingLoadedText => Problems.Count > 0 ? Problems[0] : NoMapText;

        // Source tab text when no map matches the loaded database: an unreadable or missing file is the likelier cause.
        public string NoMatchText => Problems.Count > 0 ? Problems[0]
            : Missing.Count > 0 ? "source map is missing (" + string.Join(", ", Missing) + ") - rebuild"
            : OutOfDateText;
    }
}
