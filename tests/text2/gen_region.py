"""Write the synthetic text region fixtures (fixed seed, invented words).

python tests/text2/gen_region.py OUTDIR
  REGION.DSF   -nxtext: about 43K of dead process code (PRO 7) plus 200
               messages, 60 locations and 12 objects of synthetic prose;
               one location text lands across file offset 65536 (N_FILL,
               RARE and the prose lengths place it; build-tests checks it).
  REGIONC.DSF  the format 1 control: REGION.DSF with every message from
               CTL_KEEP on cut to its "Note n:" label and first sentence.
               Locations, objects and system messages stay identical.
  REGPART1.DSF part 1 for -Text2RegionPart: picture 1, an XMESSAGE, a
               SAVE, then EXTERN 2 4 into GAME2.DDB (REGION).
REGION play: 60 locations in a line (EAST/WEST), objects at location 0,
READ prints the next 10 messages (20 READs cover 0-199). Text window is
rows 20-29, 32 columns, so More... fires inside the location 0 object list.
"""
import os, random, sys

SEED = 20261028
N_MSG = 200
N_LOC = 60
N_FILL = 1240          # PRO 7 entries, 10 PLUS each: the part A bulk
CTL_KEEP = 30          # control: messages >= CTL_KEEP keep one sentence
PAGE = 10              # messages per READ
RARE = 0.5             # share of words built from SYLL

WORDS = '''
alvo bremic cadra dunsel elvar fottin garrow hesk ilbor jandle kelvy lusk
morrin nabble oskel pindar quell rasmo sulk tavric umber vellin wexford
yarrow zennet ambric bolsk crennet daskin emmery frith glendon hallick
istle jorvel kessin lambric mardle nettick orvel pashen quintle roskin
selvy tandric ulvane vorrel wimble yeskin zorvel abric belto cosk drimble
eskar fennick gorsle harrel inver jessop kandle lirrup mosk nevvin ospar
plinth quarrel rindle saskin trevor undle varrick welkin yorrel zimble
arden bosket cullis dorrin ellick fasken grimble hosker ivvel jundle
'''.split()
ENDS = '- en ish ow ack ix et um ar ost ing ly ard ell ip on ux ade orn esk ib'.split()
GLUE = 'the a of and to in by on near past under over with from'.split()

# (article text, vocabulary noun, start: 0 = location 0, 'C' carried, 'W' worn)
OBJECTS = [
    ('a velka of the low road', 'VELKA', 0),
    ('an orrin bound in wire', 'ORRIN', 0),
    ('the dramet with a split rim', 'DRAME', 0),
    ('some pellish in a cloth', 'PELLI', 0),
    ('a tamsel of grey cord', 'TAMSE', 0),
    ('an ulbric', 'ULBRI', 0),
    ('the quorrel from the old store', 'QUORR', 0),
    ('some fenwick seeds', 'FENWI', 0),
    ('a brask', 'BRASK', 0),
    ('an eskel token', 'ESKEL', 0),
    ('the morvel lantern', 'MORVE', 'C'),
    ('a wexley cloak', 'WEXLE', 'W'),
]

SYSMESS = [
    "It's too dark to see anything.", "I can also see: ", "#nWhat now?",
    "#nWhat next?", "#nWhat should I do now?", "#nWhat should I do next?",
    "#nI was not able to understand any of that.  Please try again.",
    "#nI can't go in that direction.", "I can't do that.#n",
    "I have with me:#n", "I am wearing:#n", "", "Are you sure? ",
    "Would you like another go? ", "", "OK.#n", "Press any key to continue.#n",
    "", "", "", "", "", "", "I'm not wearing one of those.#n",
    "I can't.  I'm wearing the _.", "I already have the _.",
    "There isn't one of those here.", "I can't carry any more things.",
    "I don't have one of those.", "I'm already wearing the _.", "Y", "N",
    "More...", "#n>", "", "#nTime passes...#n", "I now have the _.#n",
    "I'm now wearing the _.#n", "I've removed the _.#n", "I've dropped the _.#n",
    "I can't wear the _.#n", "I can't remove the _.#n",
    "I can't remove the _.  My hands are full.#n",
    "The _ weighs too much for me.#n", "#nThe _ is in the ", "The _ isn't in the ",
    ", ", " and ", ".#n", "I don't have the _.#n", "I'm not wearing the _.#n",
    ".#n", "There isn't one of those in the ", "Nothing.#n", "T", "D",
    "Drive not ready - press any key to retry.#n", "I/O Error.#n",
    "Disc or Directory may be full.", "Invalid filename.", "Type in name of file:",
    "Start tape.#n", "Tape or Disc?",
]

FLAGS = '''#define fDarkF              28
#define fGFlags             29
#define fTurns              31
#define fTurnsHi            32
#define fVerb               33
#define fMaxCarr            37
#define fPlayer             38
#define fCPronounNoun       46
#define fCPronounAdject     47
#define fStrength           52
#define fInit               101
#define fPage               100
'''


SYLL = [c + v for c in 'bcdfghjklmnprstvwz' for v in 'aeiou']


def word(rnd):
    if rnd.random() < RARE:
        return ''.join(rnd.choice(SYLL) for _ in range(rnd.randint(1, 3)))
    e = rnd.choice(ENDS)
    return rnd.choice(WORDS) + ('' if e == '-' else e)


def sentence(rnd):
    # stems + endings and syllable words keep the vocabulary wide, so tokens do not swallow it
    n = rnd.randint(7, 13)
    w = [word(rnd) if rnd.random() < 0.7 else rnd.choice(GLUE) for _ in range(n)]
    w[0] = word(rnd).capitalize()
    w[-1] = word(rnd)
    return ' '.join(w) + '.'


def prose(rnd, lo, hi):
    return [sentence(rnd) for _ in range(rnd.randint(lo, hi))]


def texts():
    rnd = random.Random(SEED)
    msgs = ['REGION - synthetic text region fixture. LOOK, EAST, WEST, READ.']
    for i in range(1, N_MSG):
        msgs.append(['Note %d:' % i] + prose(rnd, 2, 4))
    locs = []
    for i in range(N_LOC):
        ex = 'Exit east.' if i == 0 else 'Exit west.' if i == N_LOC - 1 else 'Exits east and west.'
        # location 0 stays short so More... fires inside its object list
        body = ['A bare store room.'] if i == 0 else prose(rnd, 3, 6)
        locs.append(' '.join(['Place %d.' % i] + body + [ex]))
    return msgs, locs


def stx_section():
    return ''.join('/%d "%s"\n' % (i, s) for i, s in enumerate(SYSMESS))


def region_dsf(ctl):
    msgs, locs = texts()
    o = []
    o.append('; REGION%s - generated by tests/text2/gen_region.py; do not edit.\n' % ('C' if ctl else ''))
    o.append('; Synthetic words only. %s\n\n' % (
        'Format 1 control: messages %d+ cut to one sentence.' % CTL_KEEP if ctl else
        'Compile with -nxtext: the file passes 64K.'))
    o.append(FLAGS + '\n/CTL\n_\n\n/VOC\n')
    voc = [('E', 4, 'noun'), ('EAST', 4, 'noun'), ('W', 5, 'noun'), ('WEST', 5, 'noun'),
           ('I', 14, 'noun'), ('INVEN', 14, 'noun')]
    voc += [(noun, 50 + k, 'noun') for k, (_, noun, _) in enumerate(OBJECTS)]
    voc += [('GET', 20, 'verb'), ('TAKE', 20, 'verb'), ('DROP', 21, 'verb'),
            ('REMOV', 22, 'verb'), ('WEAR', 23, 'verb'), ('QUIT', 25, 'verb'),
            ('SAVE', 26, 'verb'), ('LOAD', 27, 'verb'), ('LOOK', 30, 'verb'),
            ('L', 30, 'verb'), ('READ', 33, 'verb'), ('AND', 2, 'conjugation'), ('THEN', 2, 'conjugation')]
    o += ['%-8s%-8d%s\n' % v for v in voc]
    o.append('\n/STX\n' + stx_section())
    o.append('\n/MTX\n')
    for i, m in enumerate(msgs):
        if isinstance(m, list):
            m = ' '.join(m[:2] if ctl and i >= CTL_KEEP else m)
        o.append('/%d "%s"\n' % (i, m))
    o.append('\n/OTX\n' + ''.join('/%d "%s"\n' % (k, t) for k, (t, _, _) in enumerate(OBJECTS)))
    o.append('\n/LTX\n' + ''.join('/%d "%s"\n' % (i, t) for i, t in enumerate(locs)))
    o.append('\n/CON\n')
    for i in range(N_LOC):
        o.append('/%d\n' % i)
        if i < N_LOC - 1:
            o.append('E %d\n' % (i + 1))
        if i > 0:
            o.append('W %d\n' % (i - 1))
    o.append('\n/OBJ\n')
    for k, (_, noun, at) in enumerate(OBJECTS):
        start = 'CARRIED' if at == 'C' else 'WORN' if at == 'W' else str(at)
        o.append('/%-3d %-8s 1 _ %s  _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _  %s _\n' % (
            k, start, 'Y' if at == 'W' else '_', noun))
    o.append('''
/PRO 0
> _ _   ZERO    fInit
        PROCESS 6
> _ _   WINDOW  1
        CLEAR   fDarkF
        DESC    @fPlayer
> _ _   NEWLINE
        LISTOBJ
> _ _   PROCESS 1

/PRO 1
> _ _   PARSE   0
        PROCESS 2
        REDO
> _ _   EQ      fTurns 255
        PLUS    fTurnsHi 1
        CLEAR   fTurns
        SKIP    $noCarry
> _ _   PLUS    fTurns 1
$noCarry
> _ _   PROCESS 5
        ISDONE
        REDO
> _ _   MOVE    fPlayer
        RESTART
> _ _   NEWTEXT
        LT      fVerb 14
        SYSMESS 7
        REDO
> _ _   SYSMESS 8
        REDO

/PRO 2
> _ _   SYSMESS 6

/PRO 3
/PRO 4
/PRO 5
> I     _     SYSMESS 9
              LISTAT  CARRIED
              SYSMESS 10
              LISTAT  WORN
              DONE
> GET   _     AUTOG
              DONE
> DROP  _     AUTOD
              DONE
> REMOV _     AUTOR
              DONE
> WEAR  _     AUTOW
              DONE
> LOOK  _     RESTART
> READ  _     GT      fPage %d
              SYSMESS 8
              DONE
> READ  _     %s
              DONE
> SAVE  _     SAVE    0
              RESTART
> LOAD  _     LOAD    0
              RESTART
> QUIT  _     QUIT
              END

/PRO 6
> _ _   WINDOW  1
        WINAT   20 0
        WINSIZE 10 32
        CLS
        MESSAGE 0
        SET     255
$resetLoop
> _ _   MINUS   255 1
        NOTEQ   255 fGFlags
        CLEAR   @255
> _ _   NOTZERO 255
        SKIP    $resetLoop
> _ _   RESET
        LET     fStrength 50
        LET     fMaxCarr 20
        SET     fCPronounNoun
        SET     fCPronounAdject
        LET     fInit 1
        GOTO    0

; Never called: part A bulk. Entries differ so none is shared.
/PRO 7
''' % (N_MSG - 1, '\n              '.join(['MESSAGE @fPage\n              PLUS    fPage 1'] * PAGE)))
    for i in range(N_FILL):
        a = [50 + i % 200, 50 + i // 200] + [50 + (i * 7 + j * 31) % 200 for j in range(2, 10)]
        o.append('> _ _   ' + '\n        '.join('PLUS %d %d' % (f, (j or 1)) for j, f in enumerate(a)) + '\n')
    o.append('/END\n')
    return ''.join(o)


def part1_dsf():
    rnd = random.Random(SEED + 1)
    o = ['''; REGPART1 - generated by tests/text2/gen_region.py; do not edit.
; Part 1 of -Text2RegionPart, compile with -nxtext. First boot: picture
; 1, "P1 BOOT", the XMESSAGE, SAVE (type a name), EXTERN 2 4 into
; GAME2.DDB. A LOAD of that save from part 2 returns here: "P1 LOAD OK",
; picture and XMESSAGE again, END. Messages 2+ are never printed; they
; make -nxtext choose format 2.

''', FLAGS, '\n/CTL\n_\n\n/VOC\nMARKE   50      noun\nAND     2       conjugation\n\n/STX\n', stx_section(),
         '\n/MTX\n/0 ""\n/1 "P1 BOOT#n"\n']
    for i in range(2, 40):
        o.append('/%d "%s"\n' % (i, ' '.join(prose(rnd, 2, 3))))
    o.append('''
/OTX
/0 "a part one marker"

/LTX
/0 "Part one."

/CON
/0

/OBJ
/0   0        1 _ _  _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _  MARKE _

/PRO 0
> _ _   EQ      102 0
        WINDOW  1
        WINAT   20 0
        WINSIZE 12 80
        CLS
        LET     102 1
> _ _   EQ      102 1
        ZERO    103
        PICTURE 1
        DISPLAY 0
> _ _   EQ      102 1
        ZERO    103
        MESSAGE 1
        XMESSAGE "Part one external text, read from 0.XMB."
        MES     "P1 TYPE A SAVE NAME:#n"
        LET     103 1
        SAVE    0
        EXTERN  2 4
        MES     "P1 SWITCH F#n"
        END
> _ _   EQ      103 1
        WINDOW  1
        WINAT   20 0
        WINSIZE 12 80
        MES     "P1 LOAD OK#n"
> _ _   EQ      103 1
        PICTURE 1
        DISPLAY 0
> _ _   EQ      103 1
        XMESSAGE "Part one external text, read from 0.XMB."
        END
/END
''')
    return ''.join(o)


def main(out):
    os.makedirs(out, exist_ok=True)
    for name, text in (('REGION.DSF', region_dsf(False)), ('REGIONC.DSF', region_dsf(True)),
                       ('REGPART1.DSF', part1_dsf())):
        with open(os.path.join(out, name), 'w', newline='\r\n') as f:
            f.write(text)
        print('wrote', os.path.join(out, name))


if __name__ == '__main__':
    main(sys.argv[1])
