| Step | Command | Result | PNG identical | More... pages (test/ctl) | Control text | Test text |
|---:|---|---|---|---|---|---|
| 1 | LOOK | PASS | yes | 0/0 | A long white corridor of the / winding river valley. Exits / north and south. / Location number 1 | same |
| 2 | I | PASS | yes | 1/1 | I have with me: / a lamp / the key / some coins / a map of the winding river / valley / a scroll sealed by the old king / a lamp / I am wearing: / a woollen cloak with a frayed / hem / a silver ring from the old king | same |
| 3 | EXAMINE LAMP | FAIL | no | 0/0 | You examine lamp closely. / It is a lamp. Not the key, not / some coins, just a lamp. | You examine  closely. / It is a lamp. Not the key, not / some coins, just a lamp. |
| 4 | EXAMINE KEY | FAIL | no | 0/0 | You examine key closely. / It is the key. Not a lamp, not / some coins, just the key. | You examine  closely. / It is the key. Not a lamp, not / some coins, just the key. |
| 5 | EXAMINE COINS | FAIL | no | 0/0 | You examine coins closely. / It is some coins. Not a lamp, / not the key, just some coins. | You examine  closely. / It is some coins. Not a lamp, / not the key, just some coins. |
| 6 | EXAMINE MAP | PASS | yes | 0/0 | You examine map of the winding / river valley closely. / The map shows the course of the / winding river valley. | same |
| 7 | EXAMINE SCROLL | FAIL | no | 0/0 | You examine scroll sealed by the / old king closely. / The scroll is sealed by the old / king. | You examine  closely. / The scroll is sealed by the old / king. |
| 8 | EXAMINE CLOAK | FAIL | no | 0/0 | You examine woollen cloak with a / frayed hem closely. / The cloak with a frayed hem is / warm. | You examine cloak with a frayed / hem closely. / The cloak with a frayed hem is / warm. |
| 9 | EXAMINE RING | FAIL | no | 0/0 | You examine silver ring from the / old king closely. / The ring bears the seal of the / old king. | You examine  closely. / The ring bears the seal of the / old king. |
| 10 | EXAMINE LANTERN | FAIL | no | 0/0 | You examine lamp closely. / @ is here, with some coins. / A second lamp, the twin of a / lamp. | You examine  closely. / @ is here, with some coins. / A second lamp, the twin of a / lamp. |
| 11 | DROP LAMP | FAIL | no | 0/0 | I've dropped the lamp. | I've dropped the . |
| 12 | GET LAMP | FAIL | no | 0/0 | I now have the lamp. | I now have the . |
| 13 | DROP KEY | FAIL | no | 0/0 | I've dropped the key. | I've dropped the . |
| 14 | GET KEY | FAIL | no | 0/0 | I now have the key. | I now have the . |
| 15 | DROP COINS | FAIL | no | 0/0 | I've dropped the coins. | I've dropped the . |
| 16 | GET COINS | FAIL | no | 0/0 | I now have the coins. | I now have the . |
| 17 | DROP MAP | PASS | no | 0/0 | I've dropped the map of the / winding river valley. | same |
| 18 | GET MAP | PASS | yes | 0/0 | I now have the map of the / winding river valley. | same |
| 19 | DROP SCROLL | FAIL | no | 0/0 | I've dropped the scroll sealed / by the old king. | I've dropped the . |
| 20 | GET SCROLL | FAIL | no | 0/0 | I now have the scroll sealed by / the old king. | I now have the . |
| 21 | DROP LANTERN | FAIL | no | 0/0 | I've dropped the lamp. | I've dropped the . |
| 22 | GET LANTERN | FAIL | no | 0/0 | I now have the lamp. | I now have the . |
| 23 | REMOVE CLOAK | FAIL | no | 0/0 | I've removed the woollen cloak / with a frayed hem. | I've removed the cloak with a / frayed hem. |
| 24 | WEAR CLOAK | FAIL | no | 0/0 | I'm now wearing the woollen / cloak with a frayed hem. | I'm now wearing the cloak with a / frayed hem. |
| 25 | REMOVE RING | FAIL | no | 0/0 | I've removed the silver ring / from the old king. | I've removed the . |
| 26 | WEAR RING | FAIL | no | 0/0 | I'm now wearing the silver ring / from the old king. | I'm now wearing the . |
| 27 | PAIRS | PASS | yes | 2/2 | Sysmess pair: / SM pair: this system text is / stored once. / SM pair: this system text is / stored once. / Message pair: / MTX pair: this message text is / stored once. / MTX pair: this message text is / stored once. / Location pair: / A long white corridor of the / winding river valley. Exits / north and south. / A long white corridor of the / winding river valley. Exits / north and south. / Pairs done. | same |
| 28 | EMPTY | PASS | yes | 0/0 | Empty pair follows: / Empty pair done. | same |
| 29 | TEST | PASS | yes | 1/1 | Some coins, the key and a lamp / lie by the winding river valley. / The old king hid some coins and / the key in the winding river / valley. / Look for a lamp, the key and / some coins. / Then a lamp, then the key, then / some coins. / First the winding river valley, / then the old king. | same |
| 30 | DROP COINS | FAIL | no | 0/0 | I've dropped the coins. | I've dropped the . |
| 31 | LOOK | PASS | yes | 1/1 | A long white corridor of the / winding river valley. Exits / north and south. / Location number 1 / I can also see: / some coins | same |
| 32 | NORTH | PASS | yes | 0/0 | A long white corridor of the / winding river valley. Exits / north and south. / Location number 2 | same |
| 33 | LOOK | PASS | yes | 0/0 | A long white corridor of the / winding river valley. Exits / north and south. / Location number 2 | same |
| 34 | SOUTH | PASS | yes | 1/1 | A long white corridor of the / winding river valley. Exits / north and south. / Location number 1 / I can also see: / some coins | same |
| 35 | GET COINS | FAIL | no | 0/0 | I now have the coins. | I now have the . |
| 36 | LOOK | PASS | yes | 0/0 | A long white corridor of the / winding river valley. Exits / north and south. / Location number 1 | same |
| 37 | I | PASS | yes | 1/1 | I have with me: / a lamp / the key / some coins / a map of the winding river / valley / a scroll sealed by the old king / a lamp / I am wearing: / a woollen cloak with a frayed / hem / a silver ring from the old king | same |

37 step(s), 23 FAIL; boot screen identical: yes
