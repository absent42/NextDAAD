namespace NextDAADDebug
{
    public enum BreakKind { DebugMarker, Process, Condact, SourceLine, FlagChange, FlagCompare, ObjectMoved, RuntimeError }

    public enum CompareOp { Eq, Ne, Lt, Gt }

    // A/B/C per kind: Process A proc, B verb (-1 any), C noun (-1 any); Condact A number;
    // SourceLine A file, B line; FlagChange A flag; FlagCompare A flag, Op, B value; ObjectMoved A object.
    public sealed class Breakpoint
    {
        public BreakKind Kind;
        public bool Enabled = true;
        public int A;
        public int B = -1;
        public int C = -1;
        public CompareOp Op;
        public int[] Offsets = new int[0];

        public Breakpoint Clone()
        {
            var b = (Breakpoint)MemberwiseClone();
            b.Offsets = (int[])Offsets.Clone();
            return b;
        }

        public bool SameAs(Breakpoint o) => o != null && Kind == o.Kind && A == o.A && B == o.B && C == o.C && Op == o.Op;

        public static bool Compare(int v, CompareOp op, int rhs)
        {
            switch (op)
            {
                case CompareOp.Eq: return v == rhs;
                case CompareOp.Ne: return v != rhs;
                case CompareOp.Lt: return v < rhs;
                default: return v > rhs;
            }
        }

        public static string OpText(CompareOp op) => op == CompareOp.Eq ? "=" : op == CompareOp.Ne ? "<>" : op == CompareOp.Lt ? "<" : ">";

        public string Describe(Ddb ddb, SourceMap map)
        {
            switch (Kind)
            {
                case BreakKind.DebugMarker: return "DEBUG marker";
                case BreakKind.RuntimeError: return "runtime error";
                case BreakKind.Process:
                    if (B < 0 && C < 0) return "PRO " + A;
                    return "PRO " + A + " entry " + (B >= 0 ? CondactFormatter.Word(ddb, B, WordType.Verb) : "*") + " " + (C >= 0 ? CondactFormatter.Word(ddb, C, WordType.Noun) : "*");
                case BreakKind.Condact: return "condact " + (A >= 0 && A < 128 ? Condacts.Table[A].Name : A.ToString());
                case BreakKind.SourceLine:
                    string f;
                    return "line " + B + " of " + (map != null && map.Files.TryGetValue(A, out f) ? f : "file " + A);
                case BreakKind.FlagChange: return "flag " + A + " changes";
                case BreakKind.FlagCompare: return "flag " + A + " " + OpText(Op) + " " + B;
                case BreakKind.ObjectMoved:
                    string n = CondactFormatter.ObjectName(ddb, A);
                    return "object " + A + (n == null ? "" : " (" + n + ")") + " moves";
            }
            return Kind.ToString();
        }
    }
}
