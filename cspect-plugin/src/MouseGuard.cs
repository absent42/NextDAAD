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
        const int ButtonBits = 0x07;            // active-low: bit0 right, bit1 left, bit2 middle

        volatile bool armed, owning, sampled;
        volatile int buttons = 0xFF, x, y, frozenX, frozenY;
        int stale, upRun;
        bool down;

        // Set while the plugin reads CSpect's own value, so its read is not answered here.
        public volatile bool Sampling;

        public bool Armed => armed;
        public bool Owning => owning;

        // Window side, every draw: over = pointer inside the debugger window, anyDown = any host button held.
        public void Sample(bool over, bool anyDown)
        {
            stale = 0;
            if (owning)
            {
                if (!anyDown) owning = false;
            }
            else if (armed && anyDown && !down)
            {
                frozenX = x;
                frozenY = y;
                upRun = 0;
                owning = true;
            }
            down = anyDown;
            armed = !owning && over && !anyDown && CSpectButtonsUp;
        }

        bool CSpectButtonsUp => (buttons & ButtonBits) == ButtonBits;

        // Emulator side, once per frame: what CSpect itself answers for the three ports.
        public void PassThrough(byte b, byte px, byte py)
        {
            buttons = b;
            x = px;
            y = py;
            sampled = true;
            upRun = owning && CSpectButtonsUp ? upRun + 1 : 0;
            if (upRun > UpFrames) Release();
        }

        // Emulator side, once per frame.
        public void Frame()
        {
            if ((armed || owning) && ++stale > StaleFrames) Release();
        }

        public void Release()
        {
            owning = false;
            armed = false;
            upRun = 0;
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
}
