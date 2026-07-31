# SP16 Task 7a - AY channel-count characterization ladder.
#
# Generates the AKY song fixtures the owner ear leg (EAR CARD #T7A) walks
# up: 1 channel -> 3 -> 6 -> 9, plus a reduced-volume 9-channel control.
# Run from the repo root:
#
#     python tests/audio/mkladder.py
#
# Output (this directory, committed): L1.AKY L3.AKY L6.AKY L9.AKY L9Q.AKY
# and LADDER.txt (the per-rung note/period table the ear card quotes).
# tests\build-tests.ps1 -AudLad stages them into sd\ as 001..005.AKY,
# with GAME.AKY = a byte-identical copy of 001.AKY (the Task 7b STOPM
# control - see the report).
#
# WHY HAND-BUILT AKY AND NOT AN ARKOS EXPORT
# The ladder's whole value is that rung N's channels 1..N are BYTE-
# IDENTICAL to rung M's channels 1..N (M > N): the only variable between
# rungs is how many voices/PSGs are sounding, so "distortion appears at
# rung k" attributes to the voices rung k added and to nothing else. A
# tracker export cannot promise that - it re-optimises blocks, tracks and
# the linker per song. Writing the AKY directly does.
#
# FORMAT AUTHORITY
# tools\ArkosTracker3\players\playerAky\doc\AKY.md, cross-checked field by
# field against the converted player in src\audio\player_aky.asm (the
# decoder that actually runs) and against a real SongToAky export of
# authoring-kit\AUDIO\1.aks. The three agree; where AKY.md's bit-field
# tables are ambiguous the player source was taken as authority:
#   IS  software-only byte = 0 vvvv n 0 1   -> (vol << 3) | 1
#       followed by dw softwarePeriod (little-endian, LSB first)
#       (player: RRB_IS_SOFTWAREONLY* - three rra's leave $40|vol in A,
#        stored to ix+6, then two byte reads to ix+0 / ix+1)
#   NIS software-only byte = msp lsp vvvv 0 1 -> (vol << 2) | 1
#       (player: RRB_NIS_SOFTWAREONLY* - and $f is the volume, bit 4 of
#        the shifted copy is lsp, bit 5 is msp/noise)
#   NIS no-sound byte $04 = "new volume", volume 0, and it also does
#       set 2,b - i.e. it CLOSES the tone bit for that channel, which is
#       what makes a silent channel truly silent rather than volume-0
#       audible-leak. $00 is the matching initial state.
#   NIS loop byte $08 followed by dw addressOfANonInitialState.
#       (verified byte-for-byte against the reference export's shared
#        empty block: 00 04 08 <addr-of-the-04>)
# The AY register writes themselves are unconditional every frame in
# PLY_AKY_SENDPSGREGISTERS_SPECTRUMRELATED, so a sustained tone needs the
# NIS re-stated every frame - which the loop above does.
#
# ADDRESSES ARE ABSOLUTE. AKY is address-encoded; the interpreter loads
# songs at AUD_SONG_ORG = $D800 (src\nextdaad.inc), which is what
# --encodingAddress 0xD800 bakes into a real export too.

import os
import struct

BASE = 0xD800           # AUD_SONG_ORG
SLOT_MAX = 10208        # AUD_SONG_MAX - the song slot ceiling
AY_CLOCK = 1773400      # ZX Spectrum Next AY clock (src/audio/aud_periods.inc)
FRAMES_PER_NOTE = 50    # 1 second per scale step at 50Hz
VOL = 11                # per-channel volume, IDENTICAL on every rung
VOL_QUIET = 5           # the reduced-volume 9-channel discriminator

# C major, one octave, as semitone offsets from C.
SCALE = [0, 2, 4, 5, 7, 9, 11, 12]
SCALE_NAMES = ["C", "D", "E", "F", "G", "A", "B", "C+"]

# Per-channel voicing. FIXED for all rungs - channel k plays the same
# notes whether the fixture has 1 channel or 9, so the rungs nest.
# (semitone offset added to the scale step, octave number)
#   PSG 1 = channels 1-3 : the root, three octaves
#   PSG 2 = channels 4-6 : the major third, three octaves
#   PSG 3 = channels 7-9 : the fifth, three octaves
VOICING = [
    (0, 4), (0, 5), (0, 3),
    (4, 4), (4, 5), (4, 3),
    (7, 4), (7, 5), (7, 3),
]


def freq(semitone_from_c0):
    # equal temperament, A4 = 440 Hz. C0 is 57 semitones below A4.
    return 440.0 * (2.0 ** ((semitone_from_c0 - 57) / 12.0))


def period(semitone_from_c0):
    p = int(round(AY_CLOCK / (16.0 * freq(semitone_from_c0))))
    return max(1, min(4095, p))


class Song:
    """Builds one AKY image. Blocks and tracks are pooled so identical
    content is emitted once - the pooling is content-keyed, so the same
    (period, volume) always resolves to the same block in every fixture,
    which is what keeps the rungs comparable."""

    def __init__(self, channels, vol):
        self.channels = channels        # 1..9 sounding; the rest silent
        self.vol = vol
        self.blocks = {}                # key -> bytes (address fixed later)
        self.block_order = []
        self.tracks = {}
        self.track_order = []

    # --- block pool ---------------------------------------------------
    def silent_block(self):
        if "sil" not in self.blocks:
            self.blocks["sil"] = None
            self.block_order.append("sil")
        return "sil"

    def tone_block(self, per):
        key = ("tone", per, self.vol)
        if key not in self.blocks:
            self.blocks[key] = None
            self.block_order.append(key)
        return key

    # --- track pool ---------------------------------------------------
    def track(self, block_key, duration):
        key = (block_key, duration)
        if key not in self.tracks:
            self.tracks[key] = None
            self.track_order.append(key)
        return key

    def build(self, patterns):
        """patterns = list of (duration_frames, [block_key x9])."""
        # Pass 1: sizes, so every address is known before any pointer is
        # written (AKY has no relocation - the pointers ARE the format).
        header = 2 + 12
        linker = len(patterns) * (2 + 18) + 4
        track_at = {}
        off = BASE + header + linker
        for key in self.track_order:
            track_at[key] = off
            off += 3                    # db duration, dw blockAddress
        block_at = {}
        for key in self.block_order:
            block_at[key] = off
            # silent: IS $00, NIS $04, loop $08 + dw          = 5
            # tone:   IS + dw period, NIS, loop $08 + dw      = 7
            off += 5 if key == "sil" else 7

        out = bytearray()
        out.append(0x81)                # format 1, little-endian
        out.append(9)                   # 9 channels / 3 PSGs (player is fixed)
        for _ in range(3):
            out += struct.pack("<I", AY_CLOCK)
        for duration, keys in patterns:
            out += struct.pack("<H", duration)
            for k in keys:
                out += struct.pack("<H", track_at[(k, duration)])
        out += struct.pack("<H", 0)     # end of song
        out += struct.pack("<H", BASE + header)     # loop to the first pattern
        for key in self.track_order:
            block_key, duration = key
            out.append(duration & 0xFF)
            out += struct.pack("<H", block_at[block_key])
        for key in self.block_order:
            if key == "sil":
                nis = block_at[key] + 1
                out += bytes([0x00, 0x04, 0x08]) + struct.pack("<H", nis)
            else:
                _, per, vol = key
                nis = block_at[key] + 3
                out += bytes([(vol << 3) | 0x01, per & 0xFF, per >> 8,
                              (vol << 2) | 0x01, 0x08]) + struct.pack("<H", nis)
        assert len(out) == off - BASE, (len(out), off - BASE)
        return bytes(out)


def make(channels, vol):
    s = Song(channels, vol)
    patterns = []
    for step in SCALE:
        keys = []
        for ch in range(9):
            if ch < channels:
                semi, octave = VOICING[ch]
                keys.append(s.tone_block(period(12 * octave + semi + step)))
            else:
                keys.append(s.silent_block())
        for k in keys:
            s.track(k, FRAMES_PER_NOTE)
        patterns.append((FRAMES_PER_NOTE, keys))
    return s.build(patterns)


def note_table():
    lines = []
    lines.append("SP16 Task 7a ladder - per-channel content (identical on every rung)")
    lines.append("AY clock %d Hz, %d frames (%.2f s) per step, volume %d (L9Q: %d)"
                 % (AY_CLOCK, FRAMES_PER_NOTE, FRAMES_PER_NOTE / 50.0, VOL, VOL_QUIET))
    lines.append("")
    header = "ch PSG voice   " + "  ".join("%-5s" % n for n in SCALE_NAMES)
    lines.append(header)
    lines.append("-" * len(header))
    for ch in range(9):
        semi, octave = VOICING[ch]
        voice = {0: "root", 4: "3rd ", 7: "5th "}[semi]
        cells = []
        for step in SCALE:
            cells.append("%-5d" % period(12 * octave + semi + step))
        lines.append("%-2d %-3d %s o%d  %s"
                     % (ch + 1, ch // 3 + 1, voice, octave, "  ".join(cells)))
    lines.append("")
    lines.append("cells are AY tone periods (R0/R1 pairs), not note numbers")
    return "\n".join(lines) + "\n"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rungs = [("L1", 1, VOL), ("L3", 3, VOL), ("L6", 6, VOL),
             ("L9", 9, VOL), ("L9Q", 9, VOL_QUIET)]
    for name, channels, vol in rungs:
        data = make(channels, vol)
        if len(data) > SLOT_MAX:
            raise SystemExit("%s is %d bytes, over the %d song slot"
                             % (name, len(data), SLOT_MAX))
        path = os.path.join(here, name + ".AKY")
        with open(path, "wb") as f:
            f.write(data)
        print("%-4s %d channel(s) volume %-2d %5d bytes  (slot %d)"
              % (name, channels, vol, len(data), SLOT_MAX))
    with open(os.path.join(here, "LADDER.txt"), "w") as f:
        f.write(note_table())
    print("wrote LADDER.txt")


if __name__ == "__main__":
    main()
