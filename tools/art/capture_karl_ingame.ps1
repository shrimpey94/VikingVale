# In-game validation capture for Karl's authored art (Claude Code integration QA).
# Builds an ISOLATED sandbox (same approach as capture_karl_review.ps1): project
# dirs are junctioned, project.godot is copied with the offline network stub
# (no socket, no login), and APPDATA is redirected so user:// (graphics, login,
# prologue configs) never touches the real install or live server.
#
# Unlike the review capture, this loads the REAL world.tscn / world3d.tscn and
# drives Karl through tools/art/karl_ingame_harness.gd.
#
#   -Mode 2d|3d|toggle   -Run <name>   [-Procedural] (capture the original Karl)
param([ValidateSet('2d','3d','toggle')][string]$Mode = '2d',
      [string]$Run = '2d_v011', [switch]$Procedural, [int]$Fps = 24)
$ErrorActionPreference = 'Stop'
if ($Run -notmatch '^[a-z0-9_]+$') { throw 'Invalid run name' }
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sandboxRoot = Join-Path $projectRoot 'art_source\validation\karl_ingame'
$outputRoot  = Join-Path $projectRoot "art_source\previews\characters\karl\v011\claude_ingame\$Run"
New-Item -ItemType Directory -Force -Path $sandboxRoot, $outputRoot | Out-Null
foreach ($name in @('scripts','assets','scenes','shaders','tools','.godot')) {
    $link = Join-Path $sandboxRoot $name
    if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target (Join-Path $projectRoot $name) | Out-Null }
}
foreach ($f in @('world.tscn','world3d.tscn','player.tscn','icon.svg')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $f) -Destination (Join-Path $sandboxRoot $f) -Force
}
$config = [IO.File]::ReadAllText((Join-Path $projectRoot 'project.godot'))
$config = $config.Replace('res://scripts/autoloads/NetworkManager.gd','res://tools/art/offline_network.gd')
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'project.godot'),$config)
[IO.File]::WriteAllText((Join-Path $sandboxRoot '.gitignore'),"*`n")
# Boot scene: park the harness on the tree root, then let it load the real world.
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'karl_harness_boot.gd'),
"extends Node`nfunc _ready() -> void:`n`tget_tree().root.add_child.call_deferred(preload(`"res://tools/art/karl_ingame_harness.gd`").new())`n")
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'karl_harness_boot.tscn'),
"[gd_scene load_steps=2 format=3]`n`n[ext_resource type=`"Script`" path=`"res://karl_harness_boot.gd`" id=`"1`"]`n`n[node name=`"Boot`" type=`"Node`"]`nscript = ExtResource(`"1`")`n")
$env:APPDATA = Join-Path $sandboxRoot 'userdata'
$userArgs = @("--karl-mode=$Mode", "--karl-out=$outputRoot")
if ($Procedural) { $userArgs += '--procedural-karl' }
# Godot prints a known harmless "ObjectDB instances leaked at exit" warning on
# stderr; under 'Stop' PowerShell 5.1 would turn that into a terminating error.
$ErrorActionPreference = 'Continue'
& 'D:\GoDot\Godot_v4.6.2-stable_win64_console.exe' --path $sandboxRoot --audio-driver Dummy `
    --resolution 1280x720 --minimized --fixed-fps $Fps `
    --write-movie (Join-Path $outputRoot 'recording.avi') `
    --log-file (Join-Path $outputRoot 'godot.log') 'res://karl_harness_boot.tscn' -- @userArgs
exit $LASTEXITCODE
