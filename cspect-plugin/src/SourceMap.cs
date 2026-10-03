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

    // GAME.DSM, written by NDRC -srcmap.
    public sealed class SourceMap
    {
        public const string Magic = "NDRC-DSM";
        public const int Major = 1;

        public uint DdbCrc;
        public int DdbLength;
        public readonly Dictionary<int, string> Files = new Dictionary<int, string>();
        public readonly Dictionary<int, SourceLoc> Condacts = new Dictionary<int, SourceLoc>();
        public readonly Dictionary<int, SourceLoc> Entries = new Dictionary<int, SourceLoc>();
        public readonly Dictionary<int, SourceLoc> Processes = new Dictionary<int, SourceLoc>();
        public readonly List<KeyValuePair<string, int>> Symbols = new List<KeyValuePair<string, int>>();

        public static SourceMap Parse(string text)
        {
            var m = new SourceMap();
            bool ddb = false;
            foreach (string[] f in RecordFile.Parse(text, Magic, Major))
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
                        RecordFile.Need(f, 5);
                        m.Condacts[RecordFile.Hex(f[1], "offset")] = new SourceLoc { File = RecordFile.Dec(f[2], "file"), Line = RecordFile.Dec(f[3], "line"), Col = RecordFile.Dec(f[4], "col") };
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

        public List<int> OffsetsForLine(int file, int line)
        {
            var r = new List<int>();
            foreach (var kv in Condacts) if (kv.Value.File == file && kv.Value.Line == line) r.Add(kv.Key);
            r.Sort();
            return r;
        }

        public bool TryLocate(int offset, out SourceLoc loc) => Condacts.TryGetValue(offset, out loc);

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
