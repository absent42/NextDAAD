using System;
using System.Collections.Generic;

namespace NextDAADDebug
{
    public struct SourceLoc
    {
        public int File;
        public int Line;
        public int Col;
    }

    // Entry is the owning entry record offset; -1 for a v1 record.
    public sealed class CondLoc
    {
        public int Entry;
        public SourceLoc Loc;
    }

    public struct LineHit
    {
        public int Offset;
        public int Entry;
    }

    // GAME.DSM, written by NDRC -srcmap. Versions 1 and 2 are read.
    public sealed class SourceMap
    {
        public const string Magic = "NDRC-DSM";
        public const int Major = 2;
        const int MinMajor = 1;

        public uint DdbCrc;
        public int DdbLength;
        public readonly Dictionary<int, string> Files = new Dictionary<int, string>();
        public readonly Dictionary<int, List<CondLoc>> Condacts = new Dictionary<int, List<CondLoc>>();
        public readonly Dictionary<int, SourceLoc> Entries = new Dictionary<int, SourceLoc>();
        public readonly Dictionary<int, SourceLoc> Processes = new Dictionary<int, SourceLoc>();
        public readonly List<KeyValuePair<string, int>> Symbols = new List<KeyValuePair<string, int>>();

        public static SourceMap Parse(string text)
        {
            var m = new SourceMap();
            bool ddb = false;
            int version;
            foreach (string[] f in RecordFile.Parse(text, Magic, MinMajor, Major, out version))
            {
                switch (f[0])
                {
                    case "ddb":
                        RecordFile.Need(f, 3);
                        m.DdbCrc = RecordFile.HexU(f[1], "crc");
                        m.DdbLength = RecordFile.Hex(f[2], "length");
                        ddb = true;
                        break;
                    case "file":
                        RecordFile.Need(f, 3);
                        m.Files[RecordFile.Dec(f[1], "file")] = f[2];
                        break;
                    case "proc":
                        RecordFile.Need(f, 4);
                        m.Processes[RecordFile.Dec(f[1], "proc")] = new SourceLoc { File = RecordFile.Dec(f[2], "file"), Line = RecordFile.Dec(f[3], "line") };
                        break;
                    case "entry":
                        RecordFile.Need(f, 4);
                        m.Entries[RecordFile.Hex(f[1], "offset")] = new SourceLoc { File = RecordFile.Dec(f[2], "file"), Line = RecordFile.Dec(f[3], "line") };
                        break;
                    case "cond":
                        int at = version >= 2 ? 3 : 2;
                        RecordFile.Need(f, at + 3);
                        var cl = new CondLoc
                        {
                            Entry = version >= 2 ? RecordFile.Hex(f[2], "entry") : -1,
                            Loc = new SourceLoc { File = RecordFile.Dec(f[at], "file"), Line = RecordFile.Dec(f[at + 1], "line"), Col = RecordFile.Dec(f[at + 2], "col") }
                        };
                        int off = RecordFile.Hex(f[1], "offset");
                        List<CondLoc> owners;
                        if (!m.Condacts.TryGetValue(off, out owners)) m.Condacts[off] = owners = new List<CondLoc>();
                        owners.Add(cl);
                        break;
                    case "sym":
                        RecordFile.Need(f, 3);
                        m.Symbols.Add(new KeyValuePair<string, int>(f[1], RecordFile.Dec(f[2], f[1])));
                        break;
                }
            }
            if (!ddb) throw new FormatException("missing ddb record");
            return m;
        }

        public bool Matches(byte[] ddbImage) => DdbLength > 0 && DdbLength <= ddbImage.Length && Crc32.Compute(ddbImage, 0, DdbLength) == DdbCrc;

        // Map paths are relative to the DSM; '\' and '/' and letter case are not significant.
        public static bool SamePath(string a, string b) =>
            string.Equals(a.Replace('\\', '/'), b.Replace('\\', '/'), StringComparison.OrdinalIgnoreCase);

        public int FileIndex(string path)
        {
            int best = -1;
            foreach (var kv in Files)
                if (SamePath(kv.Value, path) && (best < 0 || kv.Key < best)) best = kv.Key;
            return best;
        }

        public List<LineHit> OffsetsForLine(int file, int line)
        {
            var r = new List<LineHit>();
            foreach (var kv in Condacts)
                foreach (var c in kv.Value)
                    if (c.Loc.File == file && c.Loc.Line == line) r.Add(new LineHit { Offset = kv.Key, Entry = c.Entry });
            r.Sort((a, b) => a.Offset != b.Offset ? a.Offset.CompareTo(b.Offset) : a.Entry.CompareTo(b.Entry));
            return r;
        }

        public bool TryLocate(int offset, out SourceLoc loc) => TryLocate(offset, -1, out loc);

        // The record owned by 'entry'; else a v1 record; else the first one.
        public bool TryLocate(int offset, int entry, out SourceLoc loc)
        {
            List<CondLoc> owners;
            if (!Condacts.TryGetValue(offset, out owners) || owners.Count == 0) { loc = new SourceLoc(); return false; }
            CondLoc pick = null;
            foreach (var c in owners)
                if (c.Entry == entry) { pick = c; break; }
            if (pick == null)
                foreach (var c in owners)
                    if (c.Entry < 0) { pick = c; break; }
            loc = (pick ?? owners[0]).Loc;
            return true;
        }

        public List<string> NamesForValue(int value)
        {
            var r = new List<string>();
            foreach (var kv in Symbols) if (kv.Value == value) r.Add(kv.Key);
            return r;
        }

        public bool TryResolveName(string name, out int value)
        {
            foreach (var kv in Symbols)
                if (string.Equals(kv.Key, name, StringComparison.OrdinalIgnoreCase)) { value = kv.Value; return true; }
            value = 0;
            return false;
        }
    }
}
