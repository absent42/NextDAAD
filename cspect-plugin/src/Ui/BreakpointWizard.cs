namespace NextDAADDebug
{
    // Chains popups to build a breakpoint. Source-line breakpoints come from the Source tab margin.
    public sealed class BreakpointWizard
    {
        readonly Ddb ddb;
        readonly SourceMap map;
        readonly Breakpoint bp = new Breakpoint();
        int step;

        public Popup Current { get; private set; }
        public Breakpoint Result { get; private set; }

        public BreakpointWizard(Ddb ddb, SourceMap map)
        {
            this.ddb = ddb;
            this.map = map;
            Current = new Picker("Break on", Lists.BreakKinds());
        }

        public void Feed(PopupResult r)
        {
            if (r == PopupResult.Open || Current == null) return;
            if (r == PopupResult.Cancel) { Current = null; return; }
            var picker = Current as Picker;
            int v = picker != null ? picker.Selected : ((DigitPad)Current).Value;
            switch (step++)
            {
                case 0:
                    bp.Kind = (BreakKind)v;
                    switch (bp.Kind)
                    {
                        case BreakKind.Process: Current = new Picker("Process", Lists.Processes(ddb)); return;
                        case BreakKind.Condact: Current = new Picker("Condact", Lists.CondactNames()); return;
                        case BreakKind.FlagChange:
                        case BreakKind.FlagCompare: Current = new Picker("Flag", Lists.Flags(ddb, map)); return;
                        case BreakKind.ObjectMoved: Current = new Picker("Object", Lists.Objects(ddb)); return;
                        default: Finish(); return;
                    }
                case 1:
                    bp.A = v;
                    if (bp.Kind == BreakKind.Process) { Current = new Picker("Entry verb", Lists.Words(ddb, WordType.Verb, true)); return; }
                    if (bp.Kind == BreakKind.FlagCompare) { Current = new Picker("Compare", Lists.CompareOps()); return; }
                    Finish();
                    return;
                case 2:
                    if (bp.Kind == BreakKind.Process) { bp.B = v; Current = new Picker("Entry noun", Lists.Words(ddb, WordType.Noun, true)); return; }
                    bp.Op = (CompareOp)v;
                    Current = new DigitPad("Value", 0, 0, 255);
                    return;
                default:
                    if (bp.Kind == BreakKind.Process) bp.C = v;
                    else bp.B = v;
                    Finish();
                    return;
            }
        }

        void Finish()
        {
            Result = bp;
            Current = null;
        }
    }
}
