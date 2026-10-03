using System;
using System.Collections.Generic;

namespace NextDAADDebug
{
    public sealed class HookInfo
    {
        public string Name;
        public ushort Address;
        public byte Page;
        public byte[] Check;
    }

    // NEXTDAAD.SYM, written by scripts/make-sym.ps1 at interpreter build time.
    public sealed class SymbolFile
    {
        public const string Magic = "NEXTDAAD-SYM";
        public const int Major = 1;
        public static readonly string[] RequiredSymbols = { "flags", "objTable", "numObj", "procStack", "procSP", "isDone", "curOpcode", "curCondact", "curProps", "indirValid", "indirArg2", "doallObj", "doallLevel", "ddbHeader", "cprops" };
        public static readonly string[] RequiredHooks = { "eng_exec", "err_raise" };

        public string Build = "";
        public string Variant = "";
        readonly Dictionary<string, ushort> syms = new Dictionary<string, ushort>();
        readonly Dictionary<string, HookInfo> hooks = new Dictionary<string, HookInfo>();

        public ushort this[string name]
        {
            get
            {
                ushort v;
                if (syms.TryGetValue(name, out v)) return v;
                HookInfo h;
                if (hooks.TryGetValue(name, out h)) return h.Address;
                throw new KeyNotFoundException("symbol " + name);
            }
        }

        public HookInfo Hook(string name) => hooks[name];

        public static SymbolFile Parse(string text)
        {
            var s = new SymbolFile();
            foreach (string[] f in RecordFile.Parse(text, Magic, Major))
            {
                switch (f[0])
                {
                    case "build":
                        if (f.Length >= 3) { s.Build = f[1]; s.Variant = f[2]; }
                        break;
                    case "sym":
                        RecordFile.Need(f, 3);
                        s.syms[f[1]] = (ushort)RecordFile.Hex(f[2], f[1]);
                        break;
                    case "hook":
                        RecordFile.Need(f, 5);
                        if (f[4].Length != 64) throw new FormatException("hook " + f[1] + ": check bytes must be 64 hex chars");
                        var chk = new byte[32];
                        for (int i = 0; i < 32; i++) chk[i] = (byte)RecordFile.Hex(f[4].Substring(2 * i, 2), f[1]);
                        s.hooks[f[1]] = new HookInfo { Name = f[1], Address = (ushort)RecordFile.Hex(f[2], f[1]), Page = (byte)RecordFile.Hex(f[3], f[1]), Check = chk };
                        break;
                }
            }
            foreach (string n in RequiredSymbols) if (!s.syms.ContainsKey(n)) throw new FormatException("missing sym " + n);
            foreach (string n in RequiredHooks) if (!s.hooks.ContainsKey(n)) throw new FormatException("missing hook " + n);
            if (s["flags"] != 0xA200 || s["objTable"] != 0xA300 || s["numObj"] != 0xA900)
                throw new FormatException("frozen anchors moved: flags/objTable/numObj must be A200/A300/A900");
            return s;
        }
    }
}
