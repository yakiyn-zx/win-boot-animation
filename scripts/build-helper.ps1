# Compiles wbhelper.cs -> wbhelper.dll once, so the keeper can load the
# P/Invoke assembly instantly at launch instead of paying ~2s of CodeDom
# compilation every time.  Run manually if wbhelper.dll is ever missing
# (or stale after editing wbhelper.cs).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cs   = Join-Path $here 'wbhelper.cs'
$dll  = Join-Path $here 'wbhelper.dll'

$src = Get-Content -Raw -LiteralPath $cs
Add-Type -TypeDefinition $src -OutputAssembly $dll
if (Test-Path $dll) {
    "built $dll ($((Get-Item $dll).Length) bytes)"
} else {
    throw "compilation produced no dll"
}
