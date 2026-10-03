namespace NextDAADDebug
{
    public static class Theme
    {
        public const byte Bg = 0, Text = 1, Dim = 2, Current = 3, Accent = 4, Changed = 5, Error = 6,
            Button = 7, ButtonHot = 8, ButtonOff = 9, Tab = 10, TabOn = 11, PopupBg = 12, Break = 13;

        static readonly int[] Rgb =
        {
            0x101820, 0xD8D8D8, 0x787878, 0x204868, 0x58B0F0, 0xF0D040, 0xF05050,
            0x283848, 0x406080, 0x202830, 0x283040, 0x3868A0, 0x303848, 0xE04040,
        };

        // argb false = ABGR channel order (PlatformFacts.ScreenIsArgb).
        public static uint[] Palette(bool argb)
        {
            var p = new uint[Rgb.Length];
            for (int i = 0; i < Rgb.Length; i++)
            {
                uint r = (uint)(Rgb[i] >> 16) & 0xFF, g = (uint)(Rgb[i] >> 8) & 0xFF, b = (uint)Rgb[i] & 0xFF;
                p[i] = 0xFF000000u | (argb ? (r << 16 | g << 8 | b) : (b << 16 | g << 8 | r));
            }
            return p;
        }
    }
}
