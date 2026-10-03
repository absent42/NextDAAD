using System;
using System.Collections.Generic;

namespace NextDAADDebug
{
    public sealed class ExecEvent
    {
        public int Offset;                              // HL at eng_exec entry
        public ProcFrame[] Stack = new ProcFrame[0];
        public DecodedCondact Condact;                  // byte at Offset: condact, $DC marker or $FF
        public DecodedCondact Effective;                // first non-marker at or after Offset
        public byte[] Flags = new byte[256];
        public byte[] ObjTable = new byte[256 * EngineReader.ObjSize];
        public ProcFrame Top => Stack.Length > 0 ? Stack[Stack.Length - 1] : new ProcFrame(-1, -1, -1);
    }

    public enum RunMode { Run, Step, StepEntry, StepOut, RunToParse }

    // Decides whether an eng_exec call halts. Changes are credited to the previous condact.
    public sealed class BreakController
    {
        public RunMode Mode { get; private set; }
        public readonly List<Breakpoint> Breakpoints = new List<Breakpoint>();
        public bool BreakpointsActive = true;
        int stepOutDepth;
        ExecEvent prev;
        Ddb ddb;

        public void SetDdb(Ddb d)
        {
            ddb = d;
            prev = null;
        }

        public void SetMode(RunMode mode, int depth)
        {
            Mode = mode;
            stepOutDepth = depth;
        }

        public string OnExec(ExecEvent e)
        {
            string reason = BreakpointsActive ? ModeReason(e) : null;
            if (reason == null && BreakpointsActive)
            {
                foreach (var bp in Breakpoints)
                {
                    if (!bp.Enabled) continue;
                    reason = Check(bp, e);
                    if (reason != null) break;
                }
            }
            prev = e;
            if (reason != null) Mode = RunMode.Run;
            return reason;
        }

        public string OnError(int code)
        {
            if (!BreakpointsActive) return null;
            foreach (var bp in Breakpoints)
                if (bp.Enabled && bp.Kind == BreakKind.RuntimeError) return "runtime error E" + code;
            return null;
        }

        bool IsEntryStart(ExecEvent e)
        {
            var t = e.Top;
            return ddb != null && t.EntryPtr >= 0 && ddb.EntryCondactStart(t.EntryPtr) == e.Offset;
        }

        string ModeReason(ExecEvent e)
        {
            switch (Mode)
            {
                case RunMode.Step: return "step";
                case RunMode.StepEntry: return IsEntryStart(e) ? "next entry" : null;
                case RunMode.StepOut: return e.Stack.Length < stepOutDepth ? "returned to level " + (e.Stack.Length - 1) : null;
                case RunMode.RunToParse:
                    return prev != null && prev.Effective != null && !prev.Effective.IsEnd && !prev.Effective.IsMarker && prev.Effective.Number == Condacts.Parse ? "after PARSE" : null;
                default: return null;
            }
        }

        string Check(Breakpoint bp, ExecEvent e)
        {
            switch (bp.Kind)
            {
                case BreakKind.DebugMarker:
                    return e.Condact.IsMarker ? "DEBUG marker" : null;
                case BreakKind.Process:
                    if (e.Top.Proc != bp.A || !IsEntryStart(e)) return null;
                    if (bp.B >= 0 && ddb.Byte(e.Top.EntryPtr) != bp.B) return null;
                    if (bp.C >= 0 && ddb.Byte(e.Top.EntryPtr + 1) != bp.C) return null;
                    return "breakpoint: " + bp.Describe(ddb, null);
                case BreakKind.Condact:
                    return e.Effective != null && !e.Effective.IsEnd && !e.Effective.IsMarker && e.Effective.Number == bp.A ? "breakpoint: condact " + Condacts.Table[bp.A].Name : null;
                case BreakKind.SourceLine:
                    return Array.IndexOf(bp.Offsets, e.Offset) >= 0 ? "breakpoint: source line " + bp.B : null;
                case BreakKind.FlagChange:
                    if (prev == null || prev.Flags[bp.A] == e.Flags[bp.A]) return null;
                    return "breakpoint: flag " + bp.A + " changed " + prev.Flags[bp.A] + " -> " + e.Flags[bp.A] + By();
                case BreakKind.FlagCompare:
                    bool now = Breakpoint.Compare(e.Flags[bp.A], bp.Op, bp.B);
                    bool before = prev != null && Breakpoint.Compare(prev.Flags[bp.A], bp.Op, bp.B);
                    return now && !before ? "breakpoint: flag " + bp.A + " " + Breakpoint.OpText(bp.Op) + " " + bp.B + By() : null;
                case BreakKind.ObjectMoved:
                    if (prev == null) return null;
                    int was = prev.ObjTable[bp.A * EngineReader.ObjSize], now2 = e.ObjTable[bp.A * EngineReader.ObjSize];
                    return was != now2 ? "breakpoint: object " + bp.A + " moved " + was + " -> " + now2 + By() : null;
                default:
                    return null;
            }
        }

        string By() => prev != null && prev.Effective != null && !prev.Effective.IsEnd ? " (by " + CondactFormatter.Plain(prev.Effective) + ")" : "";
    }
}
