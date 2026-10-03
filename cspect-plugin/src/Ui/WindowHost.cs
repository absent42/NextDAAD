using System;
using System.Runtime.CompilerServices;
using Plugin;

namespace NextDAADDebug
{
    interface ISurface
    {
        int MouseX { get; }
        int MouseY { get; }
        int Buttons { get; }
        int Wheel { get; }
        int X { get; set; }
        int Y { get; set; }
        bool Closed { get; }
        bool InputSupported { get; }
        bool PositionSupported { get; }
        void ResetWheel();
        void Blit(uint[] pixels);
        void Close();
    }

    // The only iWindow user. Touched only after the OpenWindow check, so CSpect < 3.4.0 never loads it.
    sealed class NativeSurface : ISurface
    {
        readonly iWindow w;
        volatile bool closed;

        public NativeSurface(iWindow w)
        {
            this.w = w;
            w.OnClosed += (s, e) => closed = true;
            try { int a = w.MouseX, b = w.MouseY, c = w.MouseButtons, d = w.Wheel; InputSupported = true; }
            catch (Exception) { }
            if (!InputSupported) Log.Write("iWindow mouse input not implemented by this CSpect build - window is display-only; use Ctrl+Alt+B/N/R");
            try { int x = w.X, y = w.Y; w.X = x; w.Y = y; PositionSupported = true; }
            catch (Exception) { }
            if (!PositionSupported) Log.Write("iWindow position not implemented by this CSpect build - window position not saved");
        }

        public bool InputSupported { get; private set; }
        public bool PositionSupported { get; private set; }
        public int MouseX => InputSupported ? w.MouseX : -1;
        public int MouseY => InputSupported ? w.MouseY : -1;
        public int Buttons => InputSupported ? w.MouseButtons : 0;
        public int Wheel => InputSupported ? w.Wheel : 0;
        public int X { get { return PositionSupported ? w.X : 0; } set { if (PositionSupported) w.X = value; } }
        public int Y { get { return PositionSupported ? w.Y : 0; } set { if (PositionSupported) w.Y = value; } }
        public bool Closed => closed;
        public void ResetWheel() { if (InputSupported) w.Wheel = 0; }

        public void Blit(uint[] pixels)
        {
            uint[] dst = w.Screen;
            Array.Copy(pixels, dst, Math.Min(pixels.Length, dst.Length));
            w.IsDirty = true;
        }

        public void Close()
        {
            if (!closed) w.Close();
            closed = true;
        }
    }

    sealed class WindowHost
    {
        const int Cols = 100, Rows = 40, CellW = 8, CellH = 16;
        readonly iCSpect cs;
        readonly Func<ISurface> opener;
        readonly object gate = new object();
        volatile bool toggleRequested;
        readonly Settings settings;
        readonly CellScreen screen = new CellScreen(Cols, Rows);
        readonly Ui ui;
        readonly DebuggerView view;
        readonly MouseTracker mouse = new MouseTracker();
        readonly uint[] pixels = new uint[Cols * CellW * Rows * CellH];
        readonly byte[] font;
        readonly uint[] palette;
        readonly bool supported;
        ISurface surface;
        bool wanted = true;
        long lastSerial = -1;

        public WindowHost(iCSpect cs, Settings settings, string settingsPath, string sourceRoot)
            : this((Func<ISurface>)null, settings, settingsPath, sourceRoot)
        {
            this.cs = cs;
            supported = typeof(iCSpect).GetMethod("OpenWindow") != null;
        }

        internal WindowHost(Func<ISurface> opener, Settings settings, string settingsPath, string sourceRoot)
        {
            this.opener = opener;
            this.settings = settings;
            supported = opener != null;
            font = Font.Load();
            palette = Theme.Palette(PlatformFacts.ScreenIsArgb);
            ui = new Ui(screen);
            view = new DebuggerView(settings, settingsPath, sourceRoot);
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        ISurface OpenSurface()
        {
            if (opener != null) return opener();
            iWindow w = cs.OpenWindow("NextDAAD debugger", Cols * CellW, Rows * CellH);
            return w == null ? null : new NativeSurface(w);
        }

        // Any thread: only records the request; Frame acts on it.
        public void Toggle() { toggleRequested = true; }

        public void Frame(Snapshot snap, Action<Command> post)
        {
            lock (gate) FrameLocked(snap, post);
        }

        void FrameLocked(Snapshot snap, Action<Command> post)
        {
            if (toggleRequested)
            {
                toggleRequested = false;
                if (wanted) { CloseLocked(); wanted = false; }
                else wanted = true;
            }
            if (!supported || !wanted) return;
            if (surface != null && surface.Closed)
            {
                SavePosition();
                surface = null;
                wanted = false;
                return;
            }
            if (surface == null)
            {
                surface = OpenSurface();
                if (surface == null) { wanted = false; Log.Write("OpenWindow returned null"); return; }
                if (surface.PositionSupported && settings.WinX >= 0) { surface.X = settings.WinX; surface.Y = settings.WinY; }
                lastSerial = -1;
                Log.Write("window opened " + Cols * CellW + "x" + Rows * CellH);
            }
            bool inputOk = surface.InputSupported;
            UiInput input;
            if (inputOk)
            {
                input = mouse.Next(surface.MouseX, surface.MouseY, surface.Buttons, surface.Wheel, Cols, Rows, CellW, CellH,
                    PlatformFacts.LeftButtonMask, PlatformFacts.RightButtonMask, PlatformFacts.WheelIsTotal, PlatformFacts.WheelUpPositive);
#pragma warning disable CS0162
                if (!PlatformFacts.WheelIsTotal) surface.ResetWheel();
#pragma warning restore CS0162
            }
            else input = new UiInput();
            if (!input.HasEvent && snap.Serial == lastSerial) return;
            lastSerial = snap.Serial;
            ui.Begin(input);
            view.Draw(ui, snap, post, inputOk);
            screen.Render(pixels, font, palette);
            surface.Blit(pixels);
        }

        void SavePosition()
        {
            if (surface == null || !surface.PositionSupported) return;
            settings.WinX = surface.X;
            settings.WinY = surface.Y;
            view.SaveIfChanged();
        }

        public void Close()
        {
            lock (gate) CloseLocked();
        }

        void CloseLocked()
        {
            if (surface == null) return;
            SavePosition();
            surface.Close();
            surface = null;
        }
    }
}
