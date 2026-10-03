using System;
using System.IO;
using System.Text;

namespace NextDAADDebug
{
    // NEXTDAAD_DEBUG_TRACE: one line per condact. A DEBUG marker and the condact
    // it precedes share one eng_exec call, so both are written.
    public sealed class TraceWriter : IDisposable
    {
        readonly StreamWriter w;

        public TraceWriter(string path)
        {
            w = new StreamWriter(path, false, new UTF8Encoding(false)) { AutoFlush = true };
        }

        public void Write(ProcFrame top, DecodedCondact c, Ddb ddb)
        {
            for (int i = 0; i < 17; i++)
            {
                w.WriteLine("P" + top.Proc + " E" + top.EntryPtr.ToString("X4") + " C" + c.Offset.ToString("X4") + " " + CondactFormatter.Plain(c));
                if (!c.IsMarker) break;
                c = ddb.DecodeAt(c.Offset + 1);
            }
        }

        public void Dispose() => w.Dispose();
    }
}
