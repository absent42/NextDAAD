using System;
using System.Numerics;
using System.Runtime.CompilerServices;
using ImGuiNET;
using Plugin;

namespace NextDAADDebug
{
    interface ISurface
    {
        int X { get; set; }
        int Y { get; set; }
        bool Closed { get; }
        void Present(uint[] pixels);
        void Close();
        void Release();         // after an OS close: free what Close would have
    }

    // The only iWindow/ImGui user. Created only after VersionGate, so older CSpect builds never load it.
    // CSpect runs the draw action on the OSTick thread (measured on 4.0.0.0); ImGui calls stay inside it.
    sealed class ImGuiSurface : ISurface
    {
        const ImGuiWindowFlags Flags = ImGuiWindowFlags.NoTitleBar | ImGuiWindowFlags.NoResize | ImGuiWindowFlags.NoMove
            | ImGuiWindowFlags.NoScrollbar | ImGuiWindowFlags.NoScrollWithMouse | ImGuiWindowFlags.NoCollapse | ImGuiWindowFlags.NoSavedSettings;
        static bool loggedActive;
        readonly iWindow w;
        readonly WindowHost host;
        readonly int width, height;
        IntPtr texture;
        volatile bool closed;
        bool failed, wasTyping, disabled;
        int pushed;

        public ImGuiSurface(iWindow w, WindowHost host, int width, int height)
        {
            this.w = w;
            this.host = host;
            this.width = width;
            this.height = height;
            w.OnClosed += (s, e) => closed = true;
            if (!w.SetImGuiDraw(Draw)) throw new InvalidOperationException("SetImGuiDraw refused");
        }

        public int X { get { return w.X; } set { w.X = value; } }
        public int Y { get { return w.Y; } set { w.Y = value; } }
        public bool Closed => closed;

        public void Present(uint[] pixels)
        {
            if (closed) return;
            if (texture == IntPtr.Zero)
            {
                texture = w.CreateImGuiTexture(width, height);
                if (texture == IntPtr.Zero) throw new InvalidOperationException("CreateImGuiTexture returned 0");
            }
            w.UpdateImGuiTexture(texture, pixels);
        }

        public void Close()
        {
            if (closed) return;
            closed = true;
            Release();
            w.Close();
        }

        public void Release()
        {
            closed = true;
            if (texture == IntPtr.Zero) return;
            try { w.DestroyImGuiTexture(texture); }
            catch (Exception ex) { Log.Write("DestroyImGuiTexture: " + ex.Message); }
            texture = IntPtr.Zero;
        }

        // Exceptions must not reach CSpect; the first one is logged and drawing stops.
        void Draw()
        {
            if (closed || failed) return;
            bool began = false;
            pushed = 0;
            disabled = false;
            try
            {
                var io = ImGui.GetIO();
                ImGui.SetNextWindowPos(Vector2.Zero);
                ImGui.SetNextWindowSize(io.DisplaySize);
                ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, Vector2.Zero);
                pushed++;
                ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0f);
                pushed++;
                bool visible = ImGui.Begin("NextDAAD debugger", Flags);
                began = true;
                ImGui.PopStyleVar(pushed);
                pushed = 0;
                if (visible && texture != IntPtr.Zero)
                {
                    ImGui.Image(texture, new Vector2(width, height));
                    var o = ImGui.GetItemRectMin();
                    host.Sample(io.MousePos.X, io.MousePos.Y, o.X, o.Y, io.MouseDown[0], io.MouseDown[1], io.MouseWheel);
                    TypedLine();
                    if (!loggedActive) { loggedActive = true; Log.Write("imgui draw active " + (int)io.DisplaySize.X + "x" + (int)io.DisplaySize.Y); }
                }
            }
            catch (Exception ex)
            {
                failed = true;
                host.DrawFailed(ex);
            }
            finally
            {
                // Keep ImGui's stacks balanced whatever threw.
                if (disabled) { try { ImGui.EndDisabled(); } catch (Exception) { } }
                if (pushed > 0) { try { ImGui.PopStyleVar(pushed); } catch (Exception) { } }
                if (began) { try { ImGui.End(); } catch (Exception) { } }
            }
        }

        // Enabled only while a DigitPad or Picker is open: Enter submits, Escape cancels.
        void TypedLine()
        {
            bool typing = host.TypingWanted;
            ImGui.SetCursorPosX(4);
            ImGui.BeginDisabled(!typing);
            disabled = true;
            if (typing && !wasTyping) ImGui.SetKeyboardFocusHere();
            wasTyping = typing;
            ImGui.SetNextItemWidth(240);
            string text = host.TypedText;
            bool enter = ImGui.InputText("##typed", ref text, 64, ImGuiInputTextFlags.EnterReturnsTrue);
            host.TypedText = text;
            ImGui.EndDisabled();
            disabled = false;
            ImGui.SameLine();
            ImGui.TextUnformatted(typing ? host.TypedNote ?? "type a number or name, Enter = OK, Esc = cancel" : "");
            if (!typing) return;
            if (enter)
            {
                host.QueueTyped(text);
                ImGui.SetKeyboardFocusHere(-1);
            }
            else if (ImGui.IsWindowFocused() && ImGui.IsKeyPressed(ImGuiKey.Escape)) host.QueueCancel();
        }
    }

    sealed class WindowHost
    {
        internal const int Cols = 100, Rows = 40, CellW = 8, CellH = 16;
        internal const int ImageW = Cols * CellW, ImageH = Rows * CellH, WindowW = ImageW, WindowH = ImageH + 32;
        readonly iCSpect cs;
        readonly Func<ISurface> opener;
        readonly object gate = new object();
        volatile bool toggleRequested;
        readonly Settings settings;
        readonly CellScreen screen = new CellScreen(Cols, Rows);
        readonly Ui ui;
        readonly DebuggerView view;
        readonly ImGuiMouse mouse = new ImGuiMouse(Cols, Rows, CellW, CellH);
        readonly uint[] pixels = new uint[ImageW * ImageH];
        readonly byte[] font;
        readonly uint[] palette;
        readonly bool supported;
        readonly bool closeWorks;
        bool warnedNoClose, positionBroken;
        ISurface surface;
        bool wanted = true;
        long lastSerial = -1;
        string pendingTyped;
        bool pendingCancel;
        Exception drawError;

        public WindowHost(iCSpect cs, Settings settings, string settingsPath, string sourceRoot)
            : this((Func<ISurface>)null, settings, settingsPath, sourceRoot, PlatformFacts.WindowCloseWorks)
        {
            this.cs = cs;
            supported = VersionGate.WindowSupported(typeof(iCSpect));
        }

        internal WindowHost(Func<ISurface> opener, Settings settings, string settingsPath, string sourceRoot, bool closeWorks = true)
        {
            this.closeWorks = closeWorks;
            this.opener = opener;
            this.settings = settings;
            supported = opener != null;
            font = Font.Load();
            palette = Theme.Palette(PlatformFacts.TextureIsArgb);
            ui = new Ui(screen);
            view = new DebuggerView(settings, settingsPath, sourceRoot);
        }

        // Draw-action side (same thread as Frame): input samples and the typed-text line.
        internal bool TypingWanted { get; private set; }
        internal string TypedText = "";
        internal string TypedNote;

        internal void Sample(float mx, float my, float ox, float oy, bool left, bool right, float wheel)
        {
            lock (gate) mouse.Sample(mx, my, ox, oy, left, right, wheel);
        }

        internal void QueueTyped(string text) { lock (gate) pendingTyped = text ?? ""; }
        internal void QueueCancel() { lock (gate) pendingCancel = true; }
        internal void DrawFailed(Exception ex) { lock (gate) drawError = ex; }

        [MethodImpl(MethodImplOptions.NoInlining)]
        ISurface OpenSurface()
        {
            if (opener != null) return opener();
            iWindow w = cs.OpenWindow("NextDAAD debugger", WindowW, WindowH);
            return w == null ? null : new ImGuiSurface(w, this, ImageW, ImageH);
        }

        // Any thread: only records the request; Frame acts on it.
        public void Toggle() { toggleRequested = true; }

        public void Frame(Snapshot snap, Action<Command> post)
        {
            lock (gate) FrameLocked(snap, post);
        }

        void FrameLocked(Snapshot snap, Action<Command> post)
        {
            if (drawError != null)
            {
                try { CloseLocked(); }
                catch (Exception ex) { Log.Write("close after draw failure: " + ex.Message); }
                surface = null;
                throw new InvalidOperationException("ImGui draw failed", drawError);
            }
            if (toggleRequested)
            {
                toggleRequested = false;
                if (surface != null && !closeWorks)
                {
                    if (!warnedNoClose) { warnedNoClose = true; Log.Write("window cannot be closed under mono - Ctrl+Alt+A ignored while it is open"); }
                }
                else if (wanted) { CloseLocked(); wanted = false; }
                else wanted = true;
            }
            if (!supported || !wanted) return;
            if (surface != null && surface.Closed)
            {
                SavePosition();
                surface.Release();
                surface = null;
                wanted = false;
                return;
            }
            if (surface == null)
            {
                surface = OpenSurface();
                if (surface == null) { wanted = false; Log.Write("OpenWindow returned null"); return; }
                if (settings.WinX >= 0) Position(() => { surface.X = settings.WinX; surface.Y = settings.WinY; });
                lastSerial = -1;
                Log.Write("window opened " + WindowW + "x" + WindowH);
            }
            bool force = false;
            if (pendingTyped != null)
            {
                string t = pendingTyped;
                pendingTyped = null;
                if (view.Type(t)) { TypedText = ""; TypedNote = null; }
                else TypedNote = "not accepted: " + t;
                force = true;
            }
            if (pendingCancel)
            {
                pendingCancel = false;
                view.CancelPopup();
                force = true;
            }
            UiInput input = mouse.Take();
            if (!force && !input.HasEvent && snap.Serial == lastSerial) return;
            lastSerial = snap.Serial;
            ui.Begin(input);
            view.Draw(ui, snap, post);
            TypingWanted = view.TypingWanted;
            if (!TypingWanted) { TypedText = ""; TypedNote = null; }
            screen.Render(pixels, font, palette);
            surface.Present(pixels);
        }

        // Window position is a convenience: a CSpect build that rejects it only loses the saved place.
        void Position(Action a)
        {
            if (positionBroken) return;
            try { a(); }
            catch (Exception ex) { positionBroken = true; Log.Write("window position not available: " + ex.Message); }
        }

        void SavePosition()
        {
            if (surface == null) return;
            Position(() => { settings.WinX = surface.X; settings.WinY = surface.Y; });
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
