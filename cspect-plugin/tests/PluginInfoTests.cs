using Xunit;

namespace NextDAADDebug.Tests
{
    public class PluginInfoTests
    {
        // CSpect 4.5 lists plugins by these two iPlugin members.
        [Fact]
        public void PluginNamesItself()
        {
            var p = new DebugPlugin();
            Assert.Equal("NextDAAD debugger", p.GetName());
            Assert.StartsWith("DAAD-level debugger", p.GetDescription());
        }
    }
}
