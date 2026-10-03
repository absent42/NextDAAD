using System;

namespace NextDAADDebug
{
    public enum ArgKind { Value, Flag, Object, Location, Message, SysMessage, Process, Verb, Noun, Adjective, Adverb, Preposition, Signed, Window }

    public sealed class CondactInfo
    {
        public readonly string Name;
        public readonly bool IsAction;
        public readonly ArgKind[] Kinds;
        public int Argc => Kinds.Length;

        public CondactInfo(string name, bool action, params ArgKind[] kinds)
        {
            Name = name;
            IsAction = action;
            Kinds = kinds;
        }
    }

    // Argument counts and action bits mirror src/engine.asm cprops (tested against the built image).
    public static class Condacts
    {
        public const byte DebugMarker = 0xDC;
        public const byte EndOfEntry = 0xFF;
        public const int Parse = 73, Extern = 61, Indir = 122, Process = 75;

        // DRB omits the $FF entry terminator after these raw opcode bytes.
        static readonly byte[] Terminators = { 22, 23, 103, 116, 117, 108 };

        public static bool IsTerminatorByte(byte raw) => Array.IndexOf(Terminators, raw) >= 0;

        const ArgKind V = ArgKind.Value, F = ArgKind.Flag, O = ArgKind.Object, L = ArgKind.Location,
            M = ArgKind.Message, S = ArgKind.SysMessage, P = ArgKind.Process, VB = ArgKind.Verb,
            N = ArgKind.Noun, AJ = ArgKind.Adjective, AV = ArgKind.Adverb, PR = ArgKind.Preposition,
            SG = ArgKind.Signed, W = ArgKind.Window;

        static CondactInfo C(string n, params ArgKind[] k) => new CondactInfo(n, false, k);
        static CondactInfo A(string n, params ArgKind[] k) => new CondactInfo(n, true, k);

        public static readonly CondactInfo[] Table =
        {
            C("AT", L), C("NOTAT", L), C("ATGT", L), C("ATLT", L),                         // 0-3
            C("PRESENT", O), C("ABSENT", O), C("WORN", O), C("NOTWORN", O),                 // 4-7
            C("CARRIED", O), C("NOTCARR", O), C("CHANCE", V), C("ZERO", F),                 // 8-11
            C("NOTZERO", F), C("EQ", F, V), C("GT", F, V), C("LT", F, V),                   // 12-15
            C("ADJECT1", AJ), C("ADVERB", AV), A("SFX", V, V), A("DESC", L),                // 16-19
            C("QUIT"), A("END"), A("DONE"), A("OK"),                                         // 20-23
            A("ANYKEY"), C("SAVE", V), C("LOAD", V), A("DPRINT", F),                         // 24-27
            A("DISPLAY", V), A("CLS"), A("DROPALL"), A("AUTOG"),                             // 28-31
            A("AUTOD"), A("AUTOW"), A("AUTOR"), A("PAUSE", V),                               // 32-35
            C("SYNONYM", VB, N), A("GOTO", L), A("MESSAGE", M), A("REMOVE", O),              // 36-39
            A("GET", O), A("DROP", O), A("WEAR", O), A("DESTROY", O),                        // 40-43
            A("CREATE", O), A("SWAP", O, O), A("PLACE", O, L), A("SET", F),                  // 44-47
            A("CLEAR", F), A("PLUS", F, V), A("MINUS", F, V), A("LET", F, V),                // 48-51
            A("NEWLINE"), A("PRINT", F), A("SYSMESS", S), C("ISAT", O, L),                   // 52-55
            A("SETCO", O), A("SPACE"), C("HASAT", V), C("HASNAT", V),                        // 56-59
            A("LISTOBJ"), A("EXTERN", V, V), A("RAMSAVE"), A("RAMLOAD", F),                  // 60-63
            A("BEEP", V, V), A("PAPER", V), A("INK", V), A("BORDER", V),                     // 64-67
            C("PREP", PR), C("NOUN2", N), C("ADJECT2", AJ), A("ADD", F, F),                  // 68-71
            A("SUB", F, F), C("PARSE", V), A("LISTAT", L), A("PROCESS", P),                  // 72-75
            C("SAME", F, F), A("MES", M), A("WINDOW", W), C("NOTEQ", F, V),                  // 76-79
            C("NOTSAME", F, F), A("MODE", V), A("WINAT", V, V), A("TIME", V, V),             // 80-83
            C("PICTURE", V), A("DOALL", L), A("MOUSE", V, V), A("GFX", V, V),                // 84-87
            C("ISNOTAT", O, L), A("WEIGH", O, F), A("PUTIN", O, O), A("TAKEOUT", O, O),      // 88-91
            A("NEWTEXT"), A("ABILITY", V, V), A("WEIGHT", F), A("RANDOM", F),                // 92-95
            A("INPUT", V, V), A("SAVEAT"), A("BACKAT"), A("PRINTAT", V, V),                  // 96-99
            A("WHATO"), A("CALL", V, V), A("PUTO", L), A("NOTDONE"),                         // 100-103
            A("AUTOP", O), A("AUTOT", O), C("MOVE", F), A("WINSIZE", V, V),                  // 104-107
            A("REDO"), A("CENTRE"), A("EXIT", V), C("INKEY"),                                // 108-111
            C("BIGGER", F, F), C("SMALLER", F, F), C("ISDONE"), C("ISNDONE"),                // 112-115
            A("SKIP", SG), A("RESTART"), A("TAB", V), A("COPYOF", O, F),                     // 116-119
            A("XMES", V, V), A("COPYOO", O, O), A("INDIR", F), A("COPYFO", F, O),            // 120-123
            A("SETAT", V, V), A("COPYFF", F, F), A("COPYBF", F, F), A("RESET"),              // 124-127
        };
    }
}
