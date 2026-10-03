using System;

namespace NextDAADDebug
{
    public enum HaltMethod { DebuggerEnter, Block, Pause }

    // CSpect 3.4.0.0 behaviour not in its documentation. Values are provisional until measured on Windows and mono.
    public static class PlatformFacts
    {
        public static readonly bool IsMono = Type.GetType("Mono.Runtime") != null;
        public const HaltMethod Halt = HaltMethod.DebuggerEnter;   // S10
        public const bool TickRunsWhileHalted = true;               // S3
        public const bool RefireOnResume = false;                   // S4
        public const bool WindowFromOSTick = true;                  // S5
        public const bool ScreenIsArgb = true;                      // S6: 0xFFFF0000 shows red
        public const int LeftButtonMask = 1;                        // S7
        public const int RightButtonMask = 2;                       // S7
        public const bool WheelIsTotal = true;                      // S7: Wheel accumulates
        public const bool WheelUpPositive = true;                   // S7
    }
}
