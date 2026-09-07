# Spikes

Throwaway programs whose output is a finding, kept as records. None is
built by build.ps1 or the harness. Each folder has its own build.ps1
that assembles with tools\sjasmplus and, where the spike needs it,
reads binaries from tools\ at assembly time. A spike whose inputs are
absent (tools\NextDAW is the author's own copy) simply does not build.
