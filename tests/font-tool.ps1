# Round-trips a 2048-byte .CHR charset to/from an editable text form.
# -Mode Extract: CHR binary -> text (8 rows of . and X per glyph)
# -Mode Build:   text -> CHR binary
param(
    [Parameter(Mandatory)][ValidateSet('Extract','Build')][string]$Mode,
    [Parameter(Mandatory)][string]$In,
    [Parameter(Mandatory)][string]$Out
)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Extract') {
    $b = [IO.File]::ReadAllBytes($In)
    if ($b.Length -ne 2048) { throw "expected 2048 bytes, got $($b.Length)" }
    $sb = [System.Text.StringBuilder]::new()
    for ($g = 0; $g -lt 256; $g++) {
        [void]$sb.AppendLine(('; glyph {0} ${0:X2}' -f $g))
        for ($r = 0; $r -lt 8; $r++) {
            $byte = $b[$g*8 + $r]
            $row = ''
            for ($bit = 7; $bit -ge 0; $bit--) { $row += if ($byte -band (1 -shl $bit)) { 'X' } else { '.' } }
            [void]$sb.AppendLine($row)
        }
    }
    [IO.File]::WriteAllText($Out, $sb.ToString())
} else {
    $rows = Get-Content $In | Where-Object { $_ -match '^[.X]{8}$' }
    if ($rows.Count -ne 2048) { throw "expected 2048 glyph rows, got $($rows.Count)" }
    $b = New-Object byte[] 2048
    for ($i = 0; $i -lt 2048; $i++) {
        $byte = 0
        for ($bit = 0; $bit -lt 8; $bit++) { if ($rows[$i][$bit] -eq 'X') { $byte = $byte -bor (1 -shl (7 - $bit)) } }
        $b[$i] = $byte
    }
    [IO.File]::WriteAllBytes($Out, $b)
}
"done: $Out"
