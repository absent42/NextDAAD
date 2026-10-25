using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class BuildSplitTests
    {
        const string Marker = "NEXTDAAD-AUTOPILOT-BUILD";
        static readonly string[] Seams = { "NEXTDAAD_DEBUG_AUTOPILOT", "NextDAADDebug.Autopilot", "InjectInput", "AutoType", "AutoAccept", "AutoCancel" };

        static string Src => Path.Combine(Repo.Root, "cspect-plugin", "src");

        static string Dll(string config) => Path.Combine(Repo.Root, "build", "cspect-plugin", "bin",
            "NextDAADDebug", config, "net48", "NextDAADDebug.dll");

        static bool Contains(byte[] hay, string s, Encoding enc)
        {
            var n = enc.GetBytes(s);
            for (int i = 0; i + n.Length <= hay.Length; i++)
            {
                int j = 0;
                while (j < n.Length && hay[i + j] == n[j]) j++;
                if (j == n.Length) return true;
            }
            return false;
        }

        static bool Has(byte[] b, string s) => Contains(b, s, Encoding.ASCII) || Contains(b, s, Encoding.Unicode);

        // Every type declared under src/Autopilot.
        static List<string> AutopilotTypes()
        {
            var names = new List<string>();
            foreach (string f in Directory.GetFiles(Path.Combine(Src, "Autopilot"), "*.cs"))
                foreach (Match m in Regex.Matches(File.ReadAllText(f), @"\b(?:class|struct|interface|enum)\s+(\w+)"))
                    names.Add(m.Groups[1].Value);
            Assert.NotEmpty(names);
            return names;
        }

        // A DLL older than its compiled sources was not rebuilt: dotnet test only builds Debug.
        static byte[] Fresh(string config, bool withAutopilot)
        {
            var p = Dll(config);
            Assert.True(File.Exists(p), "build -c " + config + " first");
            DateTime dll = File.GetLastWriteTimeUtc(p);
            var inputs = Directory.GetFiles(Src, "*.cs", SearchOption.AllDirectories)
                .Where(f => withAutopilot || f.IndexOf(Path.DirectorySeparatorChar + "Autopilot" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) < 0)
                .Concat(new[] { Path.Combine(Repo.Root, "cspect-plugin", "NextDAADDebug.csproj") });
            foreach (string f in inputs)
                Assert.True(File.GetLastWriteTimeUtc(f) <= dll, config + " DLL is older than " + f + ": rebuild -c " + config);
            return File.ReadAllBytes(p);
        }

        [Fact]
        public void ReleaseHasNoAutopilot()
        {
            var b = Fresh("Release", false);
            Assert.False(Has(b, Marker));
            foreach (string s in Seams) Assert.False(Has(b, s), s);
            var types = MetadataTypes.Names(b);
            Assert.Contains("DebugPlugin", types);
            foreach (string t in AutopilotTypes()) Assert.DoesNotContain(t, types);
        }

        [Fact]
        public void AutopilotBuildHasMarker()
        {
            var b = Fresh("Autopilot", true);
            Assert.True(Has(b, Marker));
            foreach (string s in Seams) Assert.True(Has(b, s), s);
            var types = MetadataTypes.Names(b);
            foreach (string t in AutopilotTypes()) Assert.Contains(t, types);
        }
    }

    // TypeDef names from a PE file's ECMA-335 metadata (#~ stream, tables 0x00-0x02).
    static class MetadataTypes
    {
        public static HashSet<string> Names(byte[] pe)
        {
            int peOff = BitConverter.ToInt32(pe, 0x3C);
            int sections = BitConverter.ToUInt16(pe, peOff + 6);
            int optSize = BitConverter.ToUInt16(pe, peOff + 20);
            int opt = peOff + 24;
            int dirs = opt + (BitConverter.ToUInt16(pe, opt) == 0x20B ? 112 : 96);
            int secTable = opt + optSize;
            Func<int, int> file = rva =>
            {
                for (int i = 0; i < sections; i++)
                {
                    int s = secTable + i * 40;
                    int va = BitConverter.ToInt32(pe, s + 12), raw = BitConverter.ToInt32(pe, s + 16), ptr = BitConverter.ToInt32(pe, s + 20);
                    if (rva >= va && rva < va + raw) return rva - va + ptr;
                }
                throw new InvalidDataException("rva " + rva);
            };
            int cli = file(BitConverter.ToInt32(pe, dirs + 14 * 8));
            int root = file(BitConverter.ToInt32(pe, cli + 8));
            int verLen = BitConverter.ToInt32(pe, root + 12);
            int pos = root + 16 + verLen + 2;
            int streams = BitConverter.ToUInt16(pe, pos);
            pos += 2;
            int tables = -1, strings = -1;
            for (int i = 0; i < streams; i++)
            {
                int off = BitConverter.ToInt32(pe, pos);
                int end = Array.IndexOf(pe, (byte)0, pos + 8);
                string name = Encoding.ASCII.GetString(pe, pos + 8, end - pos - 8);
                if (name == "#~" || name == "#-") tables = root + off;
                if (name == "#Strings") strings = root + off;
                pos = (end + 4) & ~3;
            }
            byte heaps = pe[tables + 6];
            ulong valid = BitConverter.ToUInt64(pe, tables + 8);
            var rows = new int[64];
            pos = tables + 24;
            for (int t = 0; t < 64; t++)
                if ((valid & (1UL << t)) != 0) { rows[t] = BitConverter.ToInt32(pe, pos); pos += 4; }
            int str = (heaps & 1) != 0 ? 4 : 2, guid = (heaps & 2) != 0 ? 4 : 2;
            Func<int, int, int> coded = (bits, max) => max < (1 << (16 - bits)) ? 2 : 4;
            int scope = coded(2, new[] { rows[0x00], rows[0x1A], rows[0x23], rows[0x01] }.Max());
            int extends = coded(2, new[] { rows[0x02], rows[0x01], rows[0x1B] }.Max());
            int field = rows[0x04] < 65536 ? 2 : 4, method = rows[0x06] < 65536 ? 2 : 4;
            pos += rows[0x00] * (2 + str + 3 * guid) + rows[0x01] * (scope + 2 * str);
            var names = new HashSet<string>();
            for (int r = 0; r < rows[0x02]; r++, pos += 4 + 2 * str + extends + field + method)
            {
                int at = strings + (str == 2 ? BitConverter.ToUInt16(pe, pos + 4) : BitConverter.ToInt32(pe, pos + 4));
                names.Add(Encoding.UTF8.GetString(pe, at, Array.IndexOf(pe, (byte)0, at) - at));
            }
            return names;
        }
    }
}
