using System.IO;
using System.Text;
using Xunit;

namespace NextDAADDebug.Tests
{
    public class BuildSplitTests
    {
        const string Marker = "NEXTDAAD-AUTOPILOT-BUILD";

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

        [Fact]
        public void ReleaseHasNoAutopilot()
        {
            var p = Dll("Release");
            Assert.True(File.Exists(p), "build Release first");
            var b = File.ReadAllBytes(p);
            Assert.False(Has(b, Marker));
            Assert.False(Has(b, "NEXTDAAD_DEBUG_AUTOPILOT"));
            Assert.False(Has(b, "NextDAADDebug.Autopilot"));
        }

        [Fact]
        public void AutopilotBuildHasMarker()
        {
            var p = Dll("Autopilot");
            Assert.True(File.Exists(p), "build -c Autopilot first");
            Assert.True(Has(File.ReadAllBytes(p), Marker));
        }
    }
}
