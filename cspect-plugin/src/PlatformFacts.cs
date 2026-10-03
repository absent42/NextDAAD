using System;

namespace NextDAADDebug
{
    public enum HaltMethod { DebuggerEnter, Block, Pause }

    // CSpect 3.4.0.0 behaviour not in its documentation, measured on Windows; mono not yet measured.
    public static class PlatformFacts
    {
        public static readonly bool IsMono = Type.GetType("Mono.Runtime") != null;
        public static readonly bool WindowCloseWorks = !IsMono;     // S8: iWindow.Close() is a no-op under mono
        public const HaltMethod Halt = HaltMethod.DebuggerEnter;   // S2: halts one instruction after the hook, debugger screen hidden
        public const bool TickRunsWhileHalted = true;               // S3
        public const bool RefireOnResume = false;                   // S4
        public const bool WindowFromOSTick = true;                  // S5
        public const bool ScreenIsArgb = true;                      // S6: 0xFFFF0000 shows red
        public const int LeftButtonMask = 1;                        // S7: mouse getters unimplemented, values unmeasured
        public const int RightButtonMask = 2;                       // S7
        public const bool WheelIsTotal = true;                      // S7
        public const bool WheelUpPositive = true;                   // S7
    }
}
