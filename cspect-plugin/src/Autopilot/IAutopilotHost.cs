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
        void Type(string text);             // ENTER semantics
        void Cancel();
        void Hotkey(char k);
        KeyFeeder Keys { get; }
        int DebuggerState();
        int TicksWhileHalted { get; }
        int CurrentOffset { get; }
        void Quit();
    }
}
