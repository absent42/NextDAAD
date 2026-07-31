# Compares DRF.exe's embedded condact parameter counts against
# src\engine.asm's cprops table (argc bits 0-1). Fails on any mismatch.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$drf = [System.IO.File]::ReadAllBytes("$root\tools\DAAD-READY\TOOLS\DRC\DRF.exe")

# Locate the table: condact 0 is AT (1 param, name length 2), so scan
# for the byte run 01 02 'A' 'T' 00.
$sig = [byte[]](1,2,0x41,0x54,0)
$start = -1
for ($i = 0; $i -lt $drf.Length - 5; $i++) {
    $hit = $true
    for ($j = 0; $j -lt 5; $j++) { if ($drf[$i+$j] -ne $sig[$j]) { $hit = $false; break } }
    if ($hit) { $start = $i; break }
}
if ($start -lt 0) { throw "DRF condact table signature not found" }

# Record layout is NOT variable-length/NUL-walked: it is a fixed 276-
# byte stride struct (numParams byte, nameLen byte, name bytes, NUL,
# then space-padding to the next record). Verified by dumping records
# 0-39 and eyeballing AT, NOTAT, ATGT, ATLT, PRESENT, ABSENT, WORN,
# NOTWORN... through all 128 in condact order; a variable-length walk
# from record 0 (padded to a much wider field) mis-parses record 1
# onward.
$STRIDE = 276

$drfParams = @{}
for ($n = 0; $n -lt 128; $n++) {
    $p = $start + $n * $STRIDE
    $numParams = $drf[$p]
    $nameLen = $drf[$p+1]
    $name = [System.Text.Encoding]::ASCII.GetString($drf, $p+2, $nameLen)
    $drfParams[$n] = @{ params = $numParams; name = $name }
}

# Parse cprops out of engine.asm: db lines between cprops: and cdisp
$asm = Get-Content "$root\src\engine.asm" -Raw
if ($asm -notmatch '(?s)cprops:(.*?)cdisp') { throw "cprops block not found" }
$vals = @()
foreach ($line in ($Matches[1] -split "`n")) {
    if ($line -match '^\s*db\s+(.+?)(;|$)') {
        foreach ($v in ($Matches[1] -split ',')) {
            $v = $v.Trim()
            if ($v -match '^\$([0-9A-Fa-f]+)$') { $vals += [Convert]::ToInt32($Matches[1],16) }
            elseif ($v -match '^\d+$') { $vals += [int]$v }
        }
    }
}
if ($vals.Count -ne 128) { throw "cprops parsed $($vals.Count) rows, expected 128" }

# DAAD V3 opcodes (SP16 Task 6). DRF's table is authoritative only for
# opcodes DRF ITSELF emits, and it never emits 120/122/124 - its rows
# for them are the placeholder "dumb", 0 params. The V3 spellings reach
# the DDB through DRB instead: source XMES is DRF record 128 (1 param,
# a message number) which drb.php:842-855 rewrites to opcode 120 with
# TWO parameters (offset LSB/MSB); INDIR (122, 1 parameter) has no
# source keyword at all and is synthesised by drb.php:1136-1143 for any
# '@' on a second parameter; SETAT (124, 2 parameters) likewise has no
# keyword in DRF 0.40. Arities below are from the emitted byte stream
# (verified against a -v3 compile) and PRP013's CONDACTS[] table.
$v3Argc = @{ 120 = 2; 122 = 1; 124 = 2 }

$bad = 0
for ($n = 0; $n -lt 128; $n++) {
    $argc = $vals[$n] -band 3
    if ($v3Argc.ContainsKey($n)) {
        $want = $v3Argc[$n]
        if ($argc -ne $want) {
            "MISMATCH condact $n (V3): cprops argc=$argc expected=$want"
            $bad++
        }
        continue
    }
    $want = $drfParams[$n].params
    if ($argc -ne $want) {
        "MISMATCH condact $n ($($drfParams[$n].name)): cprops argc=$argc DRF=$want"
        $bad++
    }
}
if ($bad -gt 0) { throw "$bad cprops mismatches" }
"cprops: all 128 rows match DRF (120/122/124 against the V3 arities)"
