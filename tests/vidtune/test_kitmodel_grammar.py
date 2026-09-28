import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "authoring-kit", "lib"))
from vidtune import kitmodel

def write(tmp_path, name, text):
    p = tmp_path / name
    p.write_text(text)
    return p

def test_last_wins_and_quoted(tmp_path):
    cfg = write(tmp_path, "CONFIG.BAT",
                'SET VIDOPTS=--dither=0.3\nset "TOOLSDIR=C:\\Tools With Space"\nSET VIDOPTS=--fps 12.5\nSET VIDOPTS_001=a\n')
    c = kitmodel.parse_config(cfg)
    assert c.vid_opts == "--fps 12.5"
    assert c.toolsdir == "C:\\Tools With Space"
    assert c.per_clip["001"] == "a"

def test_local_overrides(tmp_path):
    cfg = write(tmp_path, "CONFIG.BAT", "SET TOOLSDIR=tools\nSET FFMPEGDIR=\n")
    loc = write(tmp_path, "CONFIG.local.BAT", "SET TOOLSDIR=..\\tools\nSET FFMPEGDIR=C:\\ff\n")
    c = kitmodel.parse_config(cfg, loc)
    assert c.toolsdir == "..\\tools"
    assert c.ffmpegdir == "C:\\ff"

def test_missing_local_is_fine(tmp_path):
    cfg = write(tmp_path, "CONFIG.BAT", "SET TOOLSDIR=tools\n")
    c = kitmodel.parse_config(cfg, tmp_path / "CONFIG.local.BAT")
    assert c.toolsdir == "tools"
