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
    if os.name == "nt":
        assert cands == [["py", "-3"], ["python"]]
    else:
        assert cands == [["python3"], ["python"]]
