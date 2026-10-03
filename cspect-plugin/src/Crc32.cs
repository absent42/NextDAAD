namespace NextDAADDebug
{
    // IEEE 802.3 CRC-32, as GAME.DSM records it.
    public static class Crc32
    {
        static readonly uint[] Table = Make();

        static uint[] Make()
        {
            var t = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                uint c = i;
                for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                t[i] = c;
            }
            return t;
        }

        public static uint Compute(byte[] data, int offset, int length)
        {
            uint c = 0xFFFFFFFFu;
            for (int i = offset; i < offset + length; i++) c = Table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
            return c ^ 0xFFFFFFFFu;
        }
    }
}
