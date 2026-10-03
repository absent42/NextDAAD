using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace NextDAADDebug
{
    public sealed class Watch
    {
        public bool IsObject;
        public int Number;
    }

    // DEBUGGER.local.TXT: breakpoints, watches, window position.
    public sealed class Settings
    {
        public const string Magic = "NEXTDAAD-DEBUGGER";
        public List<Breakpoint> Breakpoints = new List<Breakpoint>();
        public List<Watch> Watches = new List<Watch>();
        public int WinX = -1, WinY = -1;

        public static Settings Defaults()
        {
            var s = new Settings();
            s.Breakpoints.Add(new Breakpoint { Kind = BreakKind.DebugMarker });
            s.Breakpoints.Add(new Breakpoint { Kind = BreakKind.RuntimeError });
            return s;
        }

        public static Settings Load(string path)
        {
            if (!File.Exists(path)) return Defaults();
            try
            {
                var s = new Settings();
                foreach (string[] f in RecordFile.Parse(File.ReadAllText(path), Magic, 1))
                {
                    if (f[0] == "bp" && f.Length >= 7)
                        s.Breakpoints.Add(new Breakpoint
                        {
                            Kind = (BreakKind)Enum.Parse(typeof(BreakKind), f[1]),
                            Enabled = f[2] == "1",
                            A = RecordFile.Dec(f[3], "a"),
                            B = RecordFile.Dec(f[4], "b"),
                            C = RecordFile.Dec(f[5], "c"),
                            Op = (CompareOp)Enum.Parse(typeof(CompareOp), f[6]),
                        });
                    else if (f[0] == "watch" && f.Length >= 3)
                        s.Watches.Add(new Watch { IsObject = f[1] == "object", Number = RecordFile.Dec(f[2], "watch") });
                    else if (f[0] == "window" && f.Length >= 3)
                    {
                        s.WinX = RecordFile.Dec(f[1], "x");
                        s.WinY = RecordFile.Dec(f[2], "y");
                    }
                }
                return s;
            }
            catch (Exception ex)
            {
                Log.Write("settings ignored (" + path + "): " + ex.Message);
                return Defaults();
            }
        }

        public string Serialize(IEnumerable<Breakpoint> bps)
        {
            var sb = new StringBuilder(Magic + "\t1\n");
            foreach (var b in bps) sb.Append("bp\t" + b.Kind + "\t" + (b.Enabled ? 1 : 0) + "\t" + b.A + "\t" + b.B + "\t" + b.C + "\t" + b.Op + "\n");
            foreach (var w in Watches) sb.Append("watch\t" + (w.IsObject ? "object" : "flag") + "\t" + w.Number + "\n");
            sb.Append("window\t" + WinX + "\t" + WinY + "\n");
            return sb.ToString();
        }

        public void Save(string path, IEnumerable<Breakpoint> bps) => File.WriteAllText(path, Serialize(bps), new UTF8Encoding(false));
    }
}
