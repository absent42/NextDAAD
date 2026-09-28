# Runs inside the rig. One log per step; /out/summary.txt has "<step> <exit>".
$ErrorActionPreference = 'Continue'
$tools = @('-ToolsDir', '/opt/kittools', '-FfmpegDir', '/usr/bin')
$steps = @(
    @('parity', 'pwsh', (@('-NoProfile', '-File', 'tests/kit-parity/parity.ps1', '-NoCompare') + $tools)),
    @('parity-compress', 'pwsh', (@('-NoProfile', '-File', 'tests/kit-parity/parity.ps1', '-NoCompare', '-Variant', 'compress') + $tools)),
    @('negative', 'pwsh', (@('-NoProfile', '-File', 'tests/kit-parity/negative.ps1') + $tools)),
    @('tools-ab', 'pwsh', (@('-NoProfile', '-File', 'tests/kit-parity/tools-ab.ps1', '-Out', '/out/tools-ab.txt') + $tools)),
    @('kit-binaries', 'pwsh', @('-NoProfile', '-File', 'tests/kit-binaries-selftest.ps1')),
    @('kitconfig', 'pwsh', @('-NoProfile', '-File', 'tests/kitconfig-selftest.ps1')),
    @('kittools', 'pwsh', @('-NoProfile', '-File', 'tests/kittools-selftest.ps1')),
    @('assets-order', 'pwsh', @('-NoProfile', '-File', 'tests/assets-order-selftest.ps1')),
    @('anipack', 'pwsh', @('-NoProfile', '-File', 'tests/anipack-selftest.ps1')),
    @('intro', 'pwsh', @('-NoProfile', '-File', 'tests/intro-selftest.ps1')),
    @('xbnbuild', 'pwsh', @('-NoProfile', '-File', 'tests/xbnbuild-selftest.ps1')),
    @('audit-externs-selftest', 'pwsh', @('-NoProfile', '-File', 'tests/audit-externs-selftest.ps1')),
    @('audit-externs', 'pwsh', @('-NoProfile', '-File', 'tests/audit-externs.ps1')),
    @('hintpack-accent-oracle', 'pwsh', @('-NoProfile', '-File', 'tests/hintpack-accent-oracle.ps1')),
    @('structure', 'pwsh', @('-NoProfile', '-File', 'tests/kit-structure.ps1')),
    @('pytest-grammar', 'python', @('-m', 'pytest', 'tests/vidtune/test_kitmodel_grammar.py', 'tests/vidtune/test_config_grammar_parity.py', '-q'))
)
$summary = @()
$bad = 0
foreach ($s in $steps) {
    $name = $s[0]; $exe = $s[1]; $stepArgs = $s[2]
    & $exe @stepArgs 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath "/out/$name.log" | Out-Host
    $code = $LASTEXITCODE
    $summary += "$name $code"
    if ($code -ne 0) { $bad++ }
    # The container is --rm and each parity run recreates the kit copy: keep
    # the default variant's RELEASE for the silicon leg (Task 13).
    if ($name -eq 'parity' -and $code -eq 0) { Copy-Item -LiteralPath 'tests/out/kit parity/kit/RELEASE' -Destination '/out/release' -Recurse }
}
foreach ($m in 'manifest.txt', 'manifest-compress.txt') {
    $p = "tests/out/kit parity/$m"
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination "/out/$m" }
}
[IO.File]::WriteAllLines('/out/summary.txt', $summary)
exit $bad
