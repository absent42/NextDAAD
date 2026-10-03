using System;
using System.Collections.Generic;
using System.Globalization;

namespace NextDAADDebug
{
    // Tab-separated records shared by NEXTDAAD.SYM, GAME.DSM and DEBUGGER.local.TXT.
    public static class RecordFile
    {
        public static List<string[]> Parse(string text, string magic, int major)
        {
            if (string.IsNullOrEmpty(text)) throw new FormatException("empty file");
            if (text[0] == '﻿') text = text.Substring(1);
            string[] lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            var records = new List<string[]>();
            bool header = false;
            for (int i = 0; i < lines.Length; i++)
            {
                string line = lines[i].TrimEnd();
                if (line.Length == 0 || line[0] == '#') continue;
                string[] f = line.Split('\t');
                for (int k = 0; k < f.Length; k++) f[k] = f[k].Trim();
                if (!header)
                {
                    int v;
                    if (f.Length < 2 || f[0] != magic || !int.TryParse(f[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out v))
                        throw new FormatException("line " + (i + 1) + ": expected '" + magic + "' header");
                    if (v != major)
                        throw new FormatException(magic + " version " + v + " is not supported (this debugger reads version " + major + ")");
                    header = true;
                    continue;
                }
                records.Add(f);
            }
            if (!header) throw new FormatException("no '" + magic + "' header line");
            return records;
        }

        public static int Hex(string s, string what)
        {
            int v;
            if (!int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) throw new FormatException("bad hex " + what + ": '" + s + "'");
            return v;
        }

        public static uint HexU(string s, string what)
        {
            uint v;
            if (!uint.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v)) throw new FormatException("bad hex " + what + ": '" + s + "'");
            return v;
        }

        public static int Dec(string s, string what)
        {
            int v;
            if (!int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) throw new FormatException("bad number " + what + ": '" + s + "'");
            return v;
        }

        public static void Need(string[] f, int n)
        {
            if (f.Length < n) throw new FormatException(f[0] + " record needs " + n + " fields");
        }
    }
}
