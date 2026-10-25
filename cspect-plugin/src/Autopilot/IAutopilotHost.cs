namespace NextDAADDebug.Autopilot
{
    // Everything the engine touches in the plugin; a fake implements it for unit tests.
    public interface IAutopilotHost
    {
        CellScreen Screen { get; }
        string Status { get; }              // Problem if set, else Status
        string[] GameRows();                // may throw or return null before the interpreter is loaded
        string LogText();
        void Inject(UiInput input);
        bool Type(string text);             // ENTER semantics; false = no popup open or it refused the text
        bool Accept();                      // OK on the open DigitPad/Picker; false = no popup or nothing selectable
        bool Cancel();                      // false = no popup open
        void Hotkey(char k);
        KeyFeeder Keys { get; }
        int DebuggerState();                // 0 running, else halted
        bool WindowOpen { get; }            // the debugger window is on screen
        int TicksWhileHalted { get; }
        int CurrentOffset { get; }
        void Quit();
    }
}
