"""Generate tests\\bigddb.dsf - the oversize fixture, past the 31744 ceiling.

    python tests\\bigddb-gen.py [locations] [words/message] [words/location]

Run only when the fixture needs regrowing. The .dsf it writes is checked in,
so a normal harness run never calls this - tests\\build-tests.ps1 compiles the
committed .dsf and asserts the boundary crossings out of the compiled bytes.

WHY GENERATED. The fixture has to exceed 31744 bytes AFTER text compression,
which needs on the order of 85 KB of source prose. That is not something to
hand-maintain.

TWO COMPRESSORS, TWO FIXTURES. DRC compresses against a fixed English token
table, so pseudo-random prose over a small vocabulary resists it. NDRC's
-auto-tokens builds the table from the game's own text, which that same small
vocabulary feeds perfectly - the default 103-word pool compresses 58% smaller
under -auto-tokens and lands the database back inside the classic reach. The
auto-tokens variant therefore uses a wider --vocab to stay oversize. See
tests\\build-tests.ps1 for both invocations.

DETERMINISTIC. A plain LCG rather than random.Random, so the same .dsf comes
out of any Python on any machine and a regenerated fixture does not show up as
a whole-file diff. Changing the seed, the word list or any count changes every
byte - regenerate deliberately, and re-run the harness, which will tell you if
the result stopped crossing the boundary.

THE SIZE IS EMERGENT. Compressed size is DRC's to decide, so the defaults below
were chosen by compiling and measuring, not calculated. Two constraints the
harness enforces and this script cannot: the database must stay under 65535
bytes (the interpreter refuses larger with E2), and MESSAGE 254's text must
itself land past 31744 - the messages have to carry the size, because if the
location texts carry it instead the printed evidence proves nothing.
"""
import argparse
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

ap = argparse.ArgumentParser(description='Generate the NextDAAD oversize fixture.')
ap.add_argument('n_loc', nargs='?', type=int, default=120)
ap.add_argument('words_msg', nargs='?', type=int, default=36)
ap.add_argument('words_loc', nargs='?', type=int, default=24)
ap.add_argument('--dest', default=None, help='output .dsf path (default tests/bigddb.dsf)')
ap.add_argument('--vocab', type=int, default=103, help='distinct words drawn from the pool')
args = ap.parse_args()

N_MSG = 255          # byte-wide header count: 0..254 is the whole range
N_LOC = args.n_loc
WORDS_MSG = args.words_msg
WORDS_LOC = args.words_loc
SEED = 20260812
# Where play starts. Not 0 - that is the template's "game has not begun"
# sentinel rather than a room. One below the highest location, so the
# opening description is one of the last texts in the file and both NORTH
# and SOUTH lead somewhere.
START_LOC = N_LOC - 2

WORDS_POOL = """
lantern corridor granite whisper hollow beacon thicket marble cistern rafter
ember lattice furrow banner cavern trellis pewter shingle bramble quarry
cobble mantle spindle harbour drifting rusted narrow shallow crooked hollowed
weathered silent distant faded jagged twisted looming ancient brittle damp
arch vault ledge plinth alcove buttress gantry culvert conduit parapet
moss lichen soot chalk grit slate flint amber ochre umber
turns bends drops climbs widens narrows forks ends opens closes
beyond beneath against beside toward within across around behind before
a the this that some every no each one another
you can see there is here are it was they were nothing something
cinder lintel tarnish verdigris sallow rampart bastion turret cupola
spire belfry cloister nave transept chancel apse vestry portico
colonnade pediment cornice frieze capital pilaster baluster mullion tracery
gable eave dormer hearth chimney flue mantel threshold doorway
archway gateway causeway viaduct aqueduct reservoir sluice weir foundry
kiln furnace bellows anvil chisel mallet wedge lever pulley
winch hoist crane scaffold ladder landing terrace courtyard cellar
crypt catacomb tomb sepulchre mausoleum obelisk monument statue effigy
gargoyle finial gutter drainpipe millstone grindstone cobblestone flagstone paving
pavement meadow pasture orchard vineyard hedgerow copse woodland glade
dell dale valley ravine gorge canyon cliff bluff crag
boulder pebble gravel silt clay loam peat bog marsh
swamp fen mire quagmire wetland floodplain delta estuary lagoon
inlet cove bay strait channel current tide wave surf
spray foam brine kelp seaweed coral reef shoal sandbar
dune beach shore coast headland promontory peninsula isthmus archipelago
atoll glacier iceberg tundra steppe prairie savanna desert oasis
mirage foothill summit ridge plateau escarpment butte mesa knoll
hillock mound barrow cairn dolmen menhir stonewall smithy stile
gate fence paddock byre stable barn granary silo hayloft
threshing winnow harvest plough furrowed sow reap glean thresh
churn butter curd whey cheese wheat barley oats rye
millet clover thistle nettle dandelion fern bracken heather gorse
broom drizzling downpour hailstorm thunderclap lightning gale squall breeze
gust zephyr frost rime hoarfrost sleet blizzard flurry snowdrift
icicle thaw meltwater dew mist haze fog vapour cloudbank
overcast twilight dusk dawn sunrise sunset midday midnight starlight
moonlight shadow silhouette glare glimmer glow flicker flare spark
blaze smoulder ash hearthstone woodpile kindling tinder bonfire torch
candle wick tallow wax lamp lampstand oil paraffin flame
taper snuff extinguish kindle ignite singe scorch char blacken
rust corrode crumble erode weather crack fissure fracture splinter
shatter chip flake peel warp bend buckle sag droop
wilt shrivel wither decay rot mould mildew fungus algae
spore seed sapling seedling sprout shoot bud blossom bloom
petal stem stalk leaf branch bough trunk root bark
timber plank beam joist truss lath plaster mortar cement
concrete brick tile thatch reed rush wicker basket hamper
crate barrel cask keg jar urn vase pitcher jug
flask flagon goblet chalice tankard mug cup bowl platter
dish plate tray ladle spoon fork knife blade dagger
sword sabre rapier scabbard sheath hilt pommel shield buckler
helmet visor gauntlet armour breastplate greave chainmail hauberk pennant
standard heraldry crest emblem insignia badge medallion amulet talisman
charm relic artefact heirloom trinket bauble jewel gem gemstone
crystal quartz garnet opal jade jasper onyx obsidian pyrite
mica copper bronze tin lead zinc nickel steel iron
gold silver platinum brass alloy ore vein seam lode
mineshaft tunnel gallery chamber cave grotto burrow warren den
lair nest roost perch eyrie aerie coop pen sty
kennel fox badger otter beaver weasel stoat ferret hare
rabbit hedgehog squirrel mole vole shrew bat owl raven
crow rook jackdaw magpie sparrow wren finch thrush blackbird
starling swallow swift lark heron stork bittern kingfisher cormorant
gull tern gannet puffin falcon hawk kestrel buzzard eagle
osprey vulture kite harrier merlin wolf boar deer stag
doe fawn elk moose bison antler hoof paw claw
talon feather plume quill beak muzzle snout tail mane
hide pelt fleece wool hair whisker fang tusk skull
bone marrow sinew tendon rib spine skeleton carcass corpse
wraith spectre phantom ghost shade spirit apparition wisp haunt
eerie uncanny sinister ominous dreadful grim bleak desolate forlorn
forsaken abandoned derelict ruined dilapidated crumbling decayed rotten mouldering
festering putrid rancid fetid dank musty stale stagnant sour
bitter acrid pungent noxious sulphurous smoky hazy murky gloomy
dim dusky shadowy dark sombre drab dreary dismal cheerless
cold chill frigid icy freezing raw harsh biting piercing
numbing clammy humid sultry sweltering stifling parched arid dusty
dry crisp empty vacant barren fallow tilled fertile lush
verdant overgrown tangled thorny knotted gnarled warped bent leaning
sagging slumped collapsed toppled fallen cracked broken chipped worn
frayed tattered ragged threadbare patched mended stitched sewn woven
knitted spun thread yarn cotton linen silk velvet satin
canvas sackcloth burlap tarpaulin oilcloth leather suede fur cloak
cape hood shawl scarf glove mitten boot shoe sandal
sole heel strap belt sash girdle apron pouch satchel
knapsack pack bundle parcel package chest coffer strongbox padlock
latch bolt hinge hasp clasp catch lock key keyhole
handle knob crank shaft axle wheel cog gear ratchet
spring coil chain link fetter shackle manacle collar rope
cord twine string cable wire hook nail rivet screw
peg stake post pillar column pedestal base foundation footing
bedrock stratum outcrop precipice chasm abyss pit passage niche
recess nook cranny crevice cleft gap breach rift chink
slit gash wound scar bruise blister callus scab welt
laceration puncture sickness fever ague plague pestilence blight famine
drought flood deluge torrent cascade waterfall cataract rapids whirlpool
eddy ripple wake wash froth bubble surge swell trough
billow undertow riptide backwash salt brackish briny marshland fenland
moorland heathland wasteland backwater highland lowland upland grassland farmland
parkland shrubland scrubland grazing tillage hoe rake spade shovel
pickaxe crowbar mattock scythe sickle flail pitchfork trowel adze
creak groan moan sigh whimper wail shriek screech howl
growl snarl hiss rustle patter clatter clang clank rattle
jingle chime toll knell echo murmur mutter hum buzz
drone rumble crackle sizzle splash drip trickle gurgle seep
ooze leak drain flow swirl stir lap wade ford
paddle row sail drift float sink plunge dive dip
soak drench douse sprinkle spatter smear daub smudge stain
blot mark scratch scrape scour scrub polish buff shine
gleam glisten sparkle glitter twinkle shimmer dull fade wane
grow shrink expand contract stretch tighten loosen slacken tug
pull push shove nudge prod poke jab thrust lunge
dodge duck swerve veer lurch stumble trip stagger totter
wobble sway rock tilt lean slant slope incline descend
ascend scale clamber scramble crawl creep slink skulk lurk
prowl pursue chase flee dash sprint dart scamper scurry
scuttle hop leap bound pounce grapple wrestle grip clutch
seize snatch grab wrench yank haul drag heave lift
raise lower fling hurl toss throw cast launch propel
carpenter mason smith cooper wright tanner weaver dyer fletcher
cobbler tinker miller baker brewer vintner butcher fisherman hunter
trapper shepherd herder drover ploughman gardener forester woodcutter miner
quarryman sailor pilot navigator captain skipper mariner steersman lookout
stowaway castaway wanderer traveller pilgrim vagrant beggar peddler merchant
trader smuggler poacher outlaw fugitive guard sentry watchman warden
keeper steward bailiff constable sheriff magistrate scribe clerk chronicler
herald messenger courier envoy emissary ambassador diplomat scholar sage
hermit recluse ascetic monk friar priest chaplain deacon bishop
abbot prior novice acolyte penitent zealot heretic apostate knight
squire page baron duke earl viscount marquis count countess
duchess baroness lady lord monarch sovereign regent chancellor vizier
morning noon afternoon evening nightfall daybreak sundown gloaming eventide
fortnight sennight season autumn winter summer solstice equinox century
decade epoch era interval interlude moment instant hour minute
second heartbeat breath pause lull respite delay
""".split()

WORDS = WORDS_POOL[:args.vocab]
if len(WORDS_POOL) < args.vocab:
    raise SystemExit('vocab %d exceeds the %d-word pool' % (args.vocab, len(WORDS_POOL)))

# The 61 system messages, verbatim from the DAAD BLANK template.
SYS = [
    "It's too dark to see anything.", "I can also see:", "What now?",
    "What next?", "What should I do now?", "What should I do next?",
    "I didn't understand.", "I can't go in that direction.",
    "I can't do that.", "I have with me:", "I am wearing:", " ",
    "Are you sure?", "Another go?", " ", "OK.", "Press any key.", " ",
    " ", " ", " ", " ", " ", "I'm not wearing one of those.",
    "I can't. My hands are full.", "I already have the _.",
    "There isn't one of those here.", "I can't carry any more things.",
    "I don't have one of those.", "I'm already wearing the _.", "Y", "N",
    "More...", ">", " ", " ", "I now have the _.", "I'm now wearing the _.",
    "I've removed the _.", "I've dropped the _.", "I can't wear the _.",
    "I can't remove the _.", "I can't remove the _. My hands are full.",
    "The _ weighs too much for me.", "The _ is in the",
    "The _ isn't in the", ", ", " and ", ".#n", "I don't have the _.",
    "I'm not wearing the _.", ".", "There isn't one of those in the",
    "Nothing.", " ", " ", " ", "I/O Error", " ", "File name error.",
    "Type in name of file.",
]


class Lcg:
    """Numerical Recipes constants - deterministic on every platform."""

    def __init__(self, seed):
        self.s = seed & 0xFFFFFFFF

    def next(self, n):
        self.s = (1664525 * self.s + 1013904223) & 0xFFFFFFFF
        return (self.s >> 8) % n


def prose(rng, count):
    w = [WORDS[rng.next(len(WORDS))] for _ in range(count)]
    s = ' '.join(w)
    return s[0].upper() + s[1:] + '.'


def main():
    rng = Lcg(SEED)
    out = []
    w = out.append

    w('; NextDAAD oversize fixture - a database past the old 31744-byte ceiling.')
    w(';')
    w('; GENERATED by tests\\bigddb-gen.py. Do not hand-edit: the next')
    w('; regeneration would discard the edit. Change the generator instead.')
    w(';')
    w('; WHAT IT PINS. A classic ZX database bases its pointers at $8400, which')
    w('; caps it at 31744 bytes. The NEXTDAAD target bases them at 0, so the')
    w('; whole 64K is reachable. This database is larger than 31744 bytes, so')
    w('; the structures DRC writes last - the process list, the location and')
    w('; connection tables, and the text of the high-numbered messages - all')
    w('; sit where the classic scheme could not name them at all.')
    w(';')
    w('; MESSAGE 254 is the on-screen evidence: its text and its lookup entry')
    w('; both live past 31744, and PRO 0 prints it before anything else, so a')
    w('; boot screenshot is the proof. Messages 250-253 are short markers put')
    w('; after the bulk for the same reason; they are content rather than')
    w('; display, and printing them every turn only cluttered the screen.')
    w('; Every LOCATION text is past the boundary too, so the description')
    w('; under the marker is second evidence of the same thing.')
    w('; tests\\build-tests.ps1 asserts all of it out of the compiled bytes.')
    w(';')
    w('; The prose is pseudo-random because DRC token-compresses text and')
    w('; repeated filler would collapse under compression.')
    w(';')
    w('; THE LOOP IS THE TEMPLATE SHAPE, trimmed - PRO 0 draws, PRO 1 parses.')
    w('; An earlier version of this fixture ended PRO 0 without handing over')
    w('; to a parser loop, so the interpreter restarted process 0 forever and')
    w('; the screen flickered as it cleared and redrew. It read as correct')
    w('; through the test harness, which compares tilemap snapshots: every')
    w('; iteration redrew IDENTICAL content, so the grid compared equal and')
    w('; nothing distinguished a settled screen from one being redrawn')
    w('; hundreds of times a second. Reading the tilemap proves content, not')
    w('; stability. It also could not accept a command, which the hardware')
    w('; leg needs.')
    w('')
    w('#define fPlayer 38')
    w('#define fVerb   33')
    w('')
    w('/CTL')
    w('_')
    w('/VOC')
    w('NORTH  2  noun')
    w('SOUTH  3  noun')
    w('EAST   4  noun')
    w('WEST   5  noun')
    w('LOOK   6  verb')
    w('QUIT   7  verb')
    w('GET    8  verb')
    w('DROP   9  verb')
    w('STONE  10 noun')
    # Verb numbers 26/27 are the template's own for SAVE/LOAD. Anything
    # below 14 would be taken for a movement word.
    w('SAVE   26 verb')
    w('LOAD   27 verb')

    w('/STX')
    for i, s in enumerate(SYS):
        w('/%-3d "%s"' % (i, s))

    w('/MTX')
    for i in range(N_MSG):
        if i == 254:
            w('/254 "BIGDDB TAIL OK - MESSAGE 254 PAST 31744#n"')
        elif 250 <= i <= 253:
            w('/%-3d "MARK %d#n"' % (i, i))
        else:
            w('/%-3d "%s"' % (i, prose(rng, WORDS_MSG)))

    w('/OTX')
    w('/0 "a granite stone"')

    # Location texts end with a line break so the prompt does not run on
    # from the last word of the description.
    w('/LTX')
    for i in range(N_LOC):
        w('/%-3d "%s#n"' % (i, prose(rng, WORDS_LOC)))

    w('/CON')
    for i in range(N_LOC):
        w('/%d' % i)
        if i + 1 < N_LOC:
            w('NORTH %d' % (i + 1))
        if i > 0:
            w('SOUTH %d' % (i - 1))

    w('/OBJ')
    w('/0    0   1   _ _  _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _   STONE _')

    # PRO 0 redraws the screen each turn with the past-the-boundary marker
    # at the TOP, before the location description, so it is the first line
    # of a boot screenshot and stays on screen while the game waits.
    # PRO 0 must end by handing over to the parser loop: a process 0 that
    # simply ends is restarted immediately by the interpreter, which redraws
    # forever (visible flicker) and never prompts for a command.
    #
    # AT 0 / PROCESS 6 is the template's startup convention: location 0 is
    # the "game has not begun" sentinel, not a room, and a game GOTOs its
    # real starting location out of it. Displaying location 0 is what a
    # game looks like when it has skipped its own initialisation.
    w('/PRO 0')
    w('> _ _   AT 0')
    w('        PROCESS 6')
    w('> _ _   WINDOW 1')
    w('        WINAT 0 0')
    w('        WINSIZE 25 127')
    w('        CLS')
    w('        MESSAGE 254')
    # The room number, printed rather than left to be inferred from random
    # prose. Movement and - the point of it - a SAVE/LOAD round trip are
    # only checkable by eye if the screen says which room this is.
    w('> _ _   MES "LOC "')
    w('        PRINT fPlayer')
    w('        MES "#n"')
    w('> _ _   DESC @fPlayer')
    w('> _ _   PROCESS 1')
    # Parser loop, the template shape trimmed to what this fixture needs -
    # the same trim tests\gmodegate.dsf uses. PARSE is what prints the
    # prompt and waits, so movement between locations works and the leg can
    # be played for a few turns rather than only looked at.
    w('/PRO 1')
    w('> _ _   PARSE 0')
    w('        REDO')
    # The command decoder has to run BEFORE the movement fallback, or SAVE
    # and LOAD would be treated as failed movement attempts.
    w('> _ _   PROCESS 5')
    w('        ISDONE')
    w('        REDO')
    w('> _ _   MOVE fPlayer')
    w('        CLS')
    w('        RESTART')
    w('> _ _   NEWTEXT')
    w('        LT fVerb 14')
    w('        SYSMESS 7')
    w('        REDO')
    w('> _ _   SYSMESS 8')
    w('        REDO')
    # One-shot startup. START_LOC is near the TOP of the location range so
    # the description on screen is one of the last texts DRC wrote, and one
    # below the highest so both NORTH and SOUTH work from the opening room.
    # Command decoder. SAVE and LOAD are here because a 49K database is
    # exactly where the save path is worth exercising: the position data it
    # writes and re-reads refers to a database whose tail the classic
    # addressing could not reach. Both follow the template's shape - the
    # condact, then CLS and RESTART so process 0 redraws from the restored
    # state. Walk somewhere, note the LOC number, SAVE, walk elsewhere,
    # LOAD: the LOC number must come back.
    w('/PRO 5')
    w('> SAVE  _   SAVE 0')
    w('            CLS')
    w('            RESTART')
    w('> LOAD  _   LOAD 0')
    w('            CLS')
    w('            RESTART')
    w('/PRO 6')
    w('> _ _   GOTO %d' % START_LOC)
    w('/END')

    txt = '\n'.join(out) + '\n'
    dest = pathlib.Path(args.dest) if args.dest else (ROOT / 'tests' / 'bigddb.dsf')
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(txt, encoding='latin-1')
    print('wrote %s  %d bytes  (%d messages, %d locations)'
          % (dest, len(txt), N_MSG, N_LOC))
    print('now run tests\\build-tests.ps1 -BigDdb - it asserts the size and '
          'every boundary crossing out of the compiled bytes')


if __name__ == '__main__':
    main()
