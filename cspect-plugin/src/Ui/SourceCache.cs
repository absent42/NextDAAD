using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace NextDAADDebug
{
    // DSF text by DSM path, relative to the DSM folder; DSF is Latin-1.
    public sealed class SourceCache
    {
        readonly string root;
        readonly Dictionary<string, string[]> cache = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);

        public SourceCache(string root) { this.root = root ?? ""; }

        public string[] Lines(string path)
        {
            string[] r;
            if (cache.TryGetValue(path, out r)) return r;
            string p = path.Replace('\\', Path.DirectorySeparatorChar);
            string full = Path.IsPathRooted(p) ? p : Path.Combine(root, p);
            try { r = File.ReadAllLines(full, Encoding.GetEncoding(28591)); }
            catch (Exception) { r = new[] { "(cannot read " + full + ")" }; }
            cache[path] = r;
            return r;
        }
    }
}
