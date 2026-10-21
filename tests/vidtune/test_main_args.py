from vidtune.__main__ import parse_args


def test_parse_args_both(tmp_path):
    g = tmp_path / "My Game"
    assert parse_args(["--game-dir", str(g), "--game-cfg", str(g / "MYGAME.CFG"),
                       "-platform", "offscreen"]) == (g.resolve(),
                                                     (g / "MYGAME.CFG").resolve())


def test_parse_args_absent():
    assert parse_args([]) == (None, None)
