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
        }

        public int MouseX => w.MouseX;
        public int MouseY => w.MouseY;
        public int Buttons => w.MouseButtons;
        public int Wheel => w.Wheel;
        public int X { get { return w.X; } set { w.X = value; } }
        public int Y { get { return w.Y; } set { w.Y = value; } }
        public bool Closed => closed;
        public void ResetWheel() => w.Wheel = 0;

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
        {
            this.cs = cs;
            this.settings = settings;
            supported = typeof(iCSpect).GetMethod("OpenWindow") != null;
            if (!supported) Log.Write("NextDAAD debugger needs CSpect 3.4.0 or later - no window (trace mode still works)");
            font = Font.Load();
            palette = Theme.Palette(PlatformFacts.ScreenIsArgb);
            ui = new Ui(screen);
            view = new DebuggerView(settings, settingsPath, sourceRoot);
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        ISurface OpenSurface()
        {
            iWindow w = cs.OpenWindow("NextDAAD debugger", Cols * CellW, Rows * CellH);
            return w == null ? null : new NativeSurface(w);
        }

        public void Toggle()
        {
            if (wanted) Close();
            wanted = !wanted;
        }

        public void Frame(Snapshot snap, Action<Command> post)
        {
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
                if (settings.WinX >= 0) { surface.X = settings.WinX; surface.Y = settings.WinY; }
                lastSerial = -1;
                Log.Write("window opened " + Cols * CellW + "x" + Rows * CellH);
            }
            var input = mouse.Next(surface.MouseX, surface.MouseY, surface.Buttons, surface.Wheel, Cols, Rows, CellW, CellH,
                PlatformFacts.LeftButtonMask, PlatformFacts.RightButtonMask, PlatformFacts.WheelIsTotal, PlatformFacts.WheelUpPositive);
            if (!PlatformFacts.WheelIsTotal) surface.ResetWheel();
            if (!input.HasEvent && snap.Serial == lastSerial) return;
            lastSerial = snap.Serial;
            ui.Begin(input);
            view.Draw(ui, snap, post);
            screen.Render(pixels, font, palette);
            surface.Blit(pixels);
        }

        void SavePosition()
        {
            if (surface == null) return;
            settings.WinX = surface.X;
            settings.WinY = surface.Y;
            view.SaveIfChanged();
        }

        public void Close()
        {
            if (surface == null) return;
            SavePosition();
            surface.Close();
            surface = null;
        }
    }
}
