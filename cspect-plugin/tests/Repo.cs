using System;
using System.IO;

namespace NextDAADDebug.Tests
{
    static class Repo
    {
        public static readonly string Root = FindRoot();

        static string FindRoot()
        {
            var d = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (d != null && !File.Exists(Path.Combine(d.FullName, "build.ps1"))) d = d.Parent;
            if (d == null) throw new InvalidOperationException("repo root (build.ps1) not found above " + AppDomain.CurrentDomain.BaseDirectory);
            return d.FullName;
        }

        public static string Fixture(string name) => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "fixtures", name);
    }
}
