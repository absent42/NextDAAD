using System;
using System.IO;
using System.Text;

namespace NextDAADDebug
{
    // debugger.log in the NEXTDAAD_DEBUG folder, mirrored to CSpect's console.
    public static class Log
    {
        static readonly object Gate = new object();
        static StreamWriter w;

        public static void Open(string path)
        {
            lock (Gate)
            {
                try { w = new StreamWriter(path, true, new UTF8Encoding(false)) { AutoFlush = true }; }
                catch (Exception) { w = null; }
            }
        }

        public static void Write(string msg)
        {
            lock (Gate)
            {
                Console.WriteLine("NextDAAD debugger: " + msg);
                if (w != null) w.WriteLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg);
            }
        }

        public static void Close()
        {
            lock (Gate)
            {
                if (w != null) w.Dispose();
                w = null;
            }
        }
    }
}
