using System;

namespace NextDAADDebug
{
    // iWindow is reached through OpenWindow's return type, so CSpect builds without it never load it.
    public static class VersionGate
    {
        public const string TooOld = "NextDAAD debugger needs CSpect 4.0 or later - no window, breakpoints off, trace mode only";

        public static bool WindowSupported(Type cspect)
        {
            var open = cspect.GetMethod("OpenWindow");
            return open != null && open.ReturnType.GetMethod("SetImGuiDraw") != null;
        }
    }

    public enum HaltMethod { DebuggerEnter, Block, Pause }

    // CSpect behaviour not in its documentation. S2-S5, S8 measured on 3.4.0.0 (Windows and mono, identical except S8);
    // S6 on the 4.0.0.0 ImGui texture.
    public static class PlatformFacts
    {
        public static readonly bool IsMono = Type.GetType("Mono.Runtime") != null;
        public static readonly bool WindowCloseWorks = !IsMono;     // S8: iWindow.Close() is a no-op under mono
        public const HaltMethod Halt = HaltMethod.DebuggerEnter;   // S2: halts one instruction after the hook, debugger screen hidden
        public const bool TickRunsWhileHalted = true;               // S3
        public const bool RefireOnResume = false;                   // S4
        public const bool WindowFromOSTick = true;                  // S5
        public const bool TextureIsArgb = true;                     // S6: UpdateImGuiTexture channel order
    }
}
