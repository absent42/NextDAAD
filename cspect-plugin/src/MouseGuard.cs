using System;
using Plugin;

namespace NextDAADDebug
{
    // Keeps clicks in the debugger window away from the emulated Kempston mouse.
    // Armed (pointer over the window, every button up) or owning (a press began while armed, until all are released):
    // $FADF answers buttons idle; owning also freezes $FBDF/$FFDF at the values from before the press.
    sealed class MouseGuard
    {
        public const int PortButtons = 0xFADF, PortX = 0xFBDF, PortY = 0xFFDF;
        public static readonly int[] Ports = { PortButtons, PortX, PortY };
        internal const int StaleFrames = 50;    // no window sample this long: the window is gone
        internal const int UpFrames = 25;       // CSpect shows no button this long while owning: a release was missed
        // CSpect still shows a button this long after the host release: a new press outside the window, not lag.
        // 10 frames = 200 ms; CSpect followed the host button within a frame in the spike runs.
        internal const int ReleaseFrames = 10;
        const int ButtonBits = 0x07;            // active-low: bit0 right, bit1 left, bit2 middle

        // Transitions run under gate (window and emulator callbacks); TryAnswer only reads the volatiles.
        readonly object gate = new object();
        volatile bool armed, owning, sampled;
        volatile int buttons = 0xFF, x, y, frozenX, frozenY;
        int stale, upRun, releaseRun;
        bool down, over, released;

        // Set while the plugin reads CSpect's own value, so its read is not answered here.
        public volatile bool Sampling;

        public bool Armed => armed;
        public bool Owning => owning;

        // Window side, every draw: over = pointer inside the debugger window, anyDown = any host button held.
        // Ownership outlives the host release until CSpect's own buttons read up (PassThrough).
        public void Sample(bool over, bool anyDown)
        {
            lock (gate)
            {
                stale = 0;
                this.over = over;
                if (owning)
                {
                    if (!anyDown && !released) releaseRun = 0;
                    released = !anyDown;
                    if (released && !sampled) owning = false;
                }
                else if (armed && anyDown && !down)
                {
                    frozenX = x;
                    frozenY = y;
                    upRun = 0;
                    released = false;
                    owning = true;
                }
                down = anyDown;
                armed = !owning && over && !anyDown && CSpectButtonsUp;
            }
        }

        bool CSpectButtonsUp => (buttons & ButtonBits) == ButtonBits;

        // Emulator side, once per frame: what CSpect itself answers for the three ports.
        public void PassThrough(byte b, byte px, byte py)
        {
            lock (gate)
            {
                buttons = b;
                x = px;
                y = py;
                sampled = true;
                if (!owning) return;
                bool up = CSpectButtonsUp;
                upRun = up ? upRun + 1 : 0;
                if (released && !up) releaseRun++;
                if (!(released && up) && upRun <= UpFrames && releaseRun <= ReleaseFrames) return;
                ReleaseLocked();
                // Still over the window with the host button up: a re-press in the next draw is guarded too.
                armed = over && !down && up;
            }
        }

        // Emulator side, once per frame.
        public void Frame()
        {
            lock (gate)
            {
                if ((armed || owning) && ++stale > StaleFrames) ReleaseLocked();
            }
        }

        public void Release()
        {
            lock (gate) ReleaseLocked();
        }

        void ReleaseLocked()
        {
            owning = false;
            armed = false;
            released = false;
            upRun = 0;
            releaseRun = 0;
            stale = 0;
        }

        // Port_Read hot path: no allocation, no logging.
        public bool TryAnswer(int port, out byte v)
        {
            v = 0;
            if (Sampling) return false;
            bool own = owning;
            if (port == PortButtons)
            {
                if (!own && !armed) return false;
                v = (byte)(buttons | ButtonBits);   // wheel and bit 3 as last seen
                return true;
            }
            if (!own || !sampled) return false;
            if (port == PortX) { v = (byte)frozenX; return true; }
            if (port == PortY) { v = (byte)frozenY; return true; }
            return false;
        }
    }

    // Plugin glue for the guard: port registration, Read routing and the per-frame sample of CSpect's own values.
    sealed class MousePorts
    {
        public const int Id = 4;
        readonly Func<int, byte> inPort;
        volatile MouseGuard guard;
        bool logged;

        public MousePorts(MouseGuard guard, Func<int, byte> inPort)
        {
            this.guard = guard;
            this.inPort = inPort;
        }

        public MouseGuard Guard => guard;

        public static void Register(System.Collections.Generic.List<sIO> list)
        {
            foreach (int p in MouseGuard.Ports) list.Add(new sIO(p, eAccess.Port_Read, Id));
        }

        // True when the read is one of the guard's; isvalid then says whether the guard answered it.
        public bool Read(eAccess type, int port, int id, out bool isvalid, out byte v)
        {
            isvalid = false;
            v = 0;
            if (type != eAccess.Port_Read || id != Id) return false;
            var g = guard;
            if (g != null && g.TryAnswer(port, out v)) isvalid = true;
            return true;
        }

        // Once per Tick. A dead window or a failing InPort drops the guard for good.
        public void Tick(bool hostAlive)
        {
            var g = guard;
            if (g == null) return;
            if (!hostAlive) { Drop(g); return; }
            byte b, x, y;
            g.Sampling = true;
            try
            {
                b = inPort(MouseGuard.PortButtons);
                x = inPort(MouseGuard.PortX);
                y = inPort(MouseGuard.PortY);
            }
            catch (Exception ex)
            {
                Log.Write("mouse guard disabled: " + ex.Message);
                Drop(g);
                return;
            }
            finally { g.Sampling = false; }
            g.PassThrough(b, x, y);
            g.Frame();
            if (!logged) { logged = true; Log.Write("mouse guard: CSpect answers " + b.ToString("X2") + " " + x.ToString("X2") + " " + y.ToString("X2")); }
        }

        void Drop(MouseGuard g)
        {
            g.Release();
            guard = null;
        }
    }
}
