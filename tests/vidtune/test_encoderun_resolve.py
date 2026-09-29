import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "authoring-kit", "lib"))
from vidtune import encoderun

def test_candidate_names_follow_platform():
    names = encoderun.videnc_names()
    if os.name == "nt":
        assert names == ["videnc.exe"]
    else:
        assert names == ["videnc"]

def test_python_candidates_follow_platform():
    cands = encoderun.python_candidates()
    assert cands[0] == [sys.executable]
    if os.name == "nt":
        assert cands[1:] == [["py", "-3"], ["python"]]
    else:
        venv = os.path.join(os.path.expanduser("~"), "nextdaad-venv", "bin", "python3")
        assert cands[1:] == [["python3"], ["python"], [venv]]

def test_python_candidates_never_offer_a_frozen_exe(monkeypatch):
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", "/bundle/vidtune")
    assert ["/bundle/vidtune"] not in encoderun.python_candidates()

def test_resolve_encoder_uses_own_interpreter(tmp_path, monkeypatch):
    # No videnc exe: the GUI's own Python runs videnc.py when it has the packages.
    monkeypatch.setattr(encoderun, "python_candidates",
                        lambda: [[sys.executable], ["no-such-python-xyz"]])
    got = encoderun.resolve_encoder(tmp_path, "tools")
    assert got == [sys.executable, str(tmp_path / "lib" / "videnc.py")]
