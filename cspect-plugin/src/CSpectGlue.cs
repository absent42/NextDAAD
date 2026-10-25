using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using Plugin;

namespace NextDAADDebug
{
    sealed class CSpectMachine : IMachine
    {
        readonly iCSpect cs;
        public CSpectMachine(iCSpect cs) { this.cs = cs; }
        public byte Peek(ushort a) => cs.Peek(a);
        public byte[] Peek(ushort a, int n) => cs.Peek(a, n, null);
        public byte[] PeekPhysical(int a, int n) => cs.PeekPhysical(a, n, null);
        public byte[] PeekPhysicalUla(int a, int n) => cs.PeekPhysicalULA(a, n, null);
        public void Poke(ushort a, byte v) => cs.Poke(a, v);
        public byte GetNextRegister(byte r) => cs.GetNextRegister(r, -1);

        public CpuRegs Registers()
        {
            var r = cs.GetRegs();
            return new CpuRegs { PC = r.PC, HL = r.HL, AF = r.AF };
        }
    }

#pragma warning disable CS0162
    static class Halters
    {
        public static IHalter Create(iCSpect cs, Action pump)
        {
            switch (PlatformFacts.Halt)
            {
                case HaltMethod.Block: return new BlockingHalter(pump);
                case HaltMethod.Pause: return new PauseHalter(cs);
                default: return new DebuggerHalter(cs);
            }
        }
    }

#pragma warning restore CS0162

    // CSpect's debugger stops before the hooked instruction; SetRemote hides its screen.
    sealed class DebuggerHalter : IHalter
    {
        readonly iCSpect cs;
        public DebuggerHalter(iCSpect cs) { this.cs = cs; }

        public void Halt()
        {
            cs.Debugger(eDebugCommand.SetRemote, 1);
            cs.Debugger(eDebugCommand.Enter, 0);
        }

        public void Resume() => cs.Debugger(eDebugCommand.Run, 0);
    }

    // Holds the emulator thread in the hook; pump drains UI commands until one resumes.
    sealed class BlockingHalter : IHalter
    {
        readonly Action pump;
        volatile bool held;
        public BlockingHalter(Action pump) { this.pump = pump; }

        public void Halt()
        {
            held = true;
            while (held)
            {
                pump();
                Thread.Sleep(10);
            }
        }

        public void Resume() => held = false;
    }

    // Stops at the frame end: condacts after the break are counted as "ran past".
    sealed class PauseHalter : IHalter
    {
        readonly iCSpect cs;
        public PauseHalter(iCSpect cs) { this.cs = cs; }
        public void Halt() => cs.SetGlobal(eGlobal.pause, true);
        public void Resume() => cs.SetGlobal(eGlobal.pause, false);
    }

    public sealed class DebugPlugin : iPlugin
    {
        const int IdExec = 1, IdError = 2, IdMouse = 4, KeyToggle = 10, KeyBreak = 11, KeyStep = 12, KeyRun = 13;
        iCSpect cs;
        DebugSession session;
        TraceWriter trace;
        Settings settings = new Settings();
        string settingsPath, folder, problem;
        bool disarmed, interactive;
        WindowHost host;
        volatile MouseGuard guard;
        bool mouseLogged;
#if AUTOPILOT
        Autopilot.AutopilotHost autopilot;
        const int IdKeys = 3;
#endif

        public List<sIO> Init(iCSpect _CSpect)
        {
            cs = _CSpect;
            folder = Environment.GetEnvironmentVariable("NEXTDAAD_DEBUG");
            if (string.IsNullOrEmpty(folder) || !Directory.Exists(folder)) return null;
            var list = new List<sIO>();
            try
            {
                InitCore(list);
            }
            catch (Exception ex)
            {
                problem = "init failed: " + ex.Message;
                try { Log.Write("init failed: " + ex); } catch { }
            }
            return list;
        }

        void InitCore(List<sIO> list)
        {
            Log.Open(Path.Combine(folder, "debugger.log"));
            Log.Write("NextDAAD debugger " + typeof(DebugPlugin).Assembly.GetName().Version + ", folder " + folder);
            bool windowPossible = VersionGate.WindowSupported(typeof(iCSpect));
            if (!windowPossible) Log.Write(VersionGate.TooOld);
            interactive = Environment.GetEnvironmentVariable("NEXTDAAD_DEBUG_NOWINDOW") != "1" && windowPossible;
            string sdir = Environment.GetEnvironmentVariable("NEXTDAAD_DEBUG_SETTINGS");
            settingsPath = Path.Combine(string.IsNullOrEmpty(sdir) ? folder : sdir, "DEBUGGER.local.TXT");
            settings = Settings.Load(settingsPath);
            if (interactive)
            {
                list.Add(new sIO("<ctrl><alt>a", eAccess.KeyPress, KeyToggle));
                list.Add(new sIO("<ctrl><alt>b", eAccess.KeyPress, KeyBreak));
                list.Add(new sIO("<ctrl><alt>n", eAccess.KeyPress, KeyStep));
                list.Add(new sIO("<ctrl><alt>r", eAccess.KeyPress, KeyRun));
            }
            SymbolFile sym = null;
            try { sym = SymbolFile.Parse(File.ReadAllText(Path.Combine(folder, "NEXTDAAD.SYM"))); }
            catch (Exception ex) { problem = "NEXTDAAD.SYM: " + ex.Message; Log.Write(problem); }
            if (sym != null)
            {
                var maps = MapSet.Load(folder);
                foreach (string p in maps.Problems) Log.Write(p);
                string tp = Environment.GetEnvironmentVariable("NEXTDAAD_DEBUG_TRACE");
                if (!string.IsNullOrEmpty(tp)) trace = new TraceWriter(tp);
                IHalter halter = interactive ? Halters.Create(cs, () => session.Pump()) : new NullHalter();
                session = new DebugSession(new CSpectMachine(cs), sym, halter, maps, trace, interactive, settings.Breakpoints);
                list.Add(new sIO(sym.Hook("eng_exec").Address, eAccess.Memory_EXE, IdExec));
                list.Add(new sIO(sym.Hook("err_raise").Address, eAccess.Memory_EXE, IdError));
                Log.Write("armed: build " + sym.Build + " " + sym.Variant + maps.LogText);
            }
            if (interactive)
            {
                try { host = new WindowHost(cs, settings, settingsPath, folder); }
                catch (Exception ex) { Log.Write("window disabled: " + ex.Message); }
                if (host != null)
                {
                    guard = new MouseGuard();
                    host.Guard = guard;
                    foreach (int p in MouseGuard.Ports) list.Add(new sIO(p, eAccess.Port_Read, IdMouse));
                }
            }
#if AUTOPILOT
            StartAutopilot(list, sym);
#endif
        }

#if AUTOPILOT
        // Only when NEXTDAAD_DEBUG_AUTOPILOT is set; otherwise this build behaves like Release.
        // A missing script is logged and written as a FAIL by AutopilotHost.Start.
        void StartAutopilot(List<sIO> list, SymbolFile sym)
        {
            string script = Environment.GetEnvironmentVariable("NEXTDAAD_DEBUG_AUTOPILOT");
            if (string.IsNullOrEmpty(script)) return;
            try
            {
                var a = new Autopilot.AutopilotHost(cs, sym, Current, () => host, id => KeyPressed(id), folder);
                a.Start(script, folder);
                foreach (int p in Autopilot.AutopilotHost.Ports) list.Add(new sIO(p, eAccess.Port_Read, IdKeys));
                autopilot = a;
            }
            catch (Exception ex) { Log.Write("autopilot: not started - " + ex); }
        }
#endif

        void Post(Command c)
        {
            if (session != null) session.Post(c);
        }

        Snapshot Current() => session != null ? session.Latest : new Snapshot { Problem = problem ?? "debugger inactive", Breakpoints = settings.Breakpoints.ToArray() };

        void Disarm(Exception ex)
        {
            disarmed = true;
            Log.Write("disarmed: " + ex);
            if (session != null)
            {
                try { session.Problem = "debugger error, disarmed - see debugger.log: " + ex.Message; session.ForcePublish(); }
                catch (Exception ex2) { Log.Write("publish failed: " + ex2.Message); }
                try { session.ReleaseHalt(); }
                catch (Exception ex2) { Log.Write("release failed: " + ex2.Message); }
            }
        }

        public byte Read(eAccess type, int port, int id, out bool isvalid)
        {
            isvalid = false;
            if (type == eAccess.Port_Read && id == IdMouse)
            {
                byte m;
                var g = guard;
                if (g != null && g.TryAnswer(port, out m)) { isvalid = true; return m; }
                return 0;
            }
#if AUTOPILOT
            // Hot path (hundreds of reads per frame): no allocation, no logging.
            if (type == eAccess.Port_Read)
            {
                byte v;
                if (autopilot != null && autopilot.Keys.TryAnswerPort(port, out v)) { isvalid = true; return v; }
                return 0;
            }
#endif
            if (type != eAccess.Memory_EXE || session == null || disarmed) return 0;
            try
            {
                if (id == IdExec) session.OnExecHook();
                else if (id == IdError) session.OnErrorHook();
            }
            catch (Exception ex) { Disarm(ex); }
            return 0;
        }

        public bool Write(eAccess type, int port, int id, byte value) => false;

        public void Tick()
        {
            if (session != null && !disarmed)
            {
                try { session.Pump(); }
                catch (Exception ex) { Disarm(ex); }
            }
            if (host != null && !PlatformFacts.WindowFromOSTick) Frame();
            if (guard != null) SampleMouse();
#if AUTOPILOT
            if (autopilot != null) autopilot.Tick();
#endif
        }

        public void OSTick()
        {
            if (session != null && !disarmed && !PlatformFacts.TickRunsWhileHalted && session.Halted)
            {
                try { session.Pump(); }
                catch (Exception ex) { Disarm(ex); }
            }
            if (host != null && PlatformFacts.WindowFromOSTick) Frame();
#if AUTOPILOT
            if (autopilot != null) autopilot.Frame();
#endif
        }

        // CSpect's own mouse values, read once per frame past the guard; a failure turns the guard off.
        void SampleMouse()
        {
            if (host == null) { guard.Release(); guard = null; return; }
            byte b, x, y;
            try
            {
                guard.Sampling = true;
                b = cs.InPort(MouseGuard.PortButtons);
                x = cs.InPort(MouseGuard.PortX);
                y = cs.InPort(MouseGuard.PortY);
            }
            catch (Exception ex)
            {
                Log.Write("mouse guard disabled: " + ex.Message);
                guard.Release();
                guard = null;
                return;
            }
            finally { if (guard != null) guard.Sampling = false; }
            guard.PassThrough(b, x, y);
            guard.Frame();
            if (!mouseLogged) { mouseLogged = true; Log.Write("mouse guard: CSpect answers " + b.ToString("X2") + " " + x.ToString("X2") + " " + y.ToString("X2")); }
        }

        // A UI failure turns the window off; the hooks and trace keep running.
        void Frame()
        {
            try { host.Frame(Current(), Post); }
            catch (Exception ex)
            {
                Log.Write("window disabled: " + ex);
                host = null;
            }
        }

        public bool KeyPressed(int id)
        {
            try
            {
                switch (id)
                {
                    case KeyToggle: if (host != null) host.Toggle(); break;
                    case KeyBreak: Post(Command.Of(CommandKind.Break)); break;
                    case KeyStep: Post(Command.Of(CommandKind.Step)); break;
                    case KeyRun: Post(Command.Of(CommandKind.Run)); break;
                }
            }
            catch (Exception ex) { Log.Write("key " + id + ": " + ex.Message); }
            return true;
        }

        public void Reset()
        {
            try { if (session != null) session.Reset(); }
            catch (Exception ex) { Disarm(ex); }
        }

        public void Quit()
        {
            try { if (host != null) host.Close(); }
            catch (Exception ex) { Log.Write("quit: " + ex.Message); }
            try { if (trace != null) trace.Dispose(); }
            catch (Exception ex) { Log.Write("quit: " + ex.Message); }
            try { Log.Close(); } catch { }
        }
    }
}
