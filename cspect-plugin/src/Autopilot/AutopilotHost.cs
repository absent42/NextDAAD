using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using Plugin;

namespace NextDAADDebug.Autopilot
{
    // Plugin side of the engine. Tick feeds keys and performs the quit; OSTick runs the engine after the window frame.
    // Every entry point is exception-contained: a fault is logged once and the autopilot stops.
    sealed class AutopilotHost : IAutopilotHost
    {
        public static readonly int[] Ports = { 0x00FE, 0xFEFE, 0xFDFE, 0xFBFE, 0xF7FE, 0xEFFE, 0xDFFE, 0xBFFE, 0x7FFE };

        readonly iCSpect cs;
        readonly IMachine machine;
        readonly SymbolFile sym;
        readonly Func<Snapshot> current;
        readonly Func<WindowHost> window;
        readonly Action<int> key;
        readonly string logPath;
        readonly KeyFeeder keys = new KeyFeeder();
        readonly Stopwatch clock = Stopwatch.StartNew();
        Engine engine;
        bool quitWanted, quitSent, reported, failed;
        int haltedTicks;

        public AutopilotHost(iCSpect cs, SymbolFile sym, Func<Snapshot> current, Func<WindowHost> window, Action<int> key, string folder)
        {
            this.cs = cs;
            this.sym = sym;
            this.current = current;
            this.window = window;
            this.key = key;
            machine = new CSpectMachine(cs);
            logPath = Path.Combine(folder, "debugger.log");
        }

        // A script that does not parse is one FAIL line, DONE and a quit.
        public void Start(string script, string folder)
        {
            Log.Write("autopilot: started " + script);
            var writer = new ResultWriter(folder);
            try { engine = new Engine(ScriptParser.Parse(File.ReadAllText(script)), this, writer, () => clock.Elapsed.TotalSeconds); }
            catch (Exception ex)
            {
                writer.Result(new Step { Kind = StepKind.Note, Raw = script }, "FAIL", "script parses", ex.Message);
                writer.Finish(1);
                Log.Write("autopilot: done failures=1");
                reported = true;
                quitWanted = true;
            }
        }

        public void Tick()
        {
            if (failed) return;
            try
            {
                keys.Frame();
                if (DebuggerState() != 0) haltedTicks++;
                if (quitWanted && !quitSent)
                {
                    quitSent = true;
                    Log.Write("autopilot: quit -> " + cs.SetGlobal(eGlobal.DoQuit, true));
                }
            }
            catch (Exception ex) { Fail(ex); }
        }

        public void Frame()
        {
            if (failed || engine == null) return;
            try
            {
                engine.Frame();
                if (engine.Finished && !reported)
                {
                    reported = true;
                    Log.Write("autopilot: done failures=" + engine.Failures);
                }
            }
            catch (Exception ex) { Fail(ex); }
        }

        void Fail(Exception ex)
        {
            failed = true;
            try { Log.Write("autopilot: stopped - " + ex); } catch (Exception) { }
        }

        WindowHost Win()
        {
            WindowHost w = window();
            if (w == null) throw new InvalidOperationException("debugger window not open");
            return w;
        }

        public CellScreen Screen => Win().Screen;

        public string Status
        {
            get
            {
                Snapshot s = current();
                return s.Problem ?? s.Status;
            }
        }

        public string[] GameRows()
        {
            ushort a;
            if (sym == null || !sym.TryGet("tmCols", out a)) return null;
            return TilemapText.Read(machine, a);
        }

        public string LogText()
        {
            using (var f = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var r = new StreamReader(f, Encoding.UTF8)) return r.ReadToEnd();
        }

        public void Inject(UiInput input) => Win().InjectInput(input);
        public bool Type(string text) => Win().AutoType(text);
        public bool Accept() => Win().AutoAccept();
        public bool Cancel() => Win().AutoCancel();

        // Same ids as the Ctrl+Alt hotkeys registered in Init.
        public void Hotkey(char k)
        {
            int i = "abnr".IndexOf(char.ToLowerInvariant(k));
            if (i < 0) throw new ArgumentException("unknown hotkey '" + k + "'");
            key(10 + i);
        }

        public KeyFeeder Keys => keys;
        public int DebuggerState() => cs.Debugger(eDebugCommand.GetState, 0);
        public int TicksWhileHalted => haltedTicks;
        public int CurrentOffset => current().Offset;
        public void Quit() => quitWanted = true;
    }
}
