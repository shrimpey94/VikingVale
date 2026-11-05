param([string]$Version = 'v007', [string]$Scene = 'review_idle', [int]$Frames = 2)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^v[0-9]+$' -or $Scene -notmatch '^[a-z0-9_]+$') { throw 'Invalid asset version or scene' }
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sandboxRoot = Join-Path $projectRoot "art_source\validation\karl_$Version"
$sourceRoot = Join-Path $projectRoot "art_source\review_scenes\karl\$Version"
$outputRoot = Join-Path $projectRoot "art_source\previews\characters\karl\$Version\godot_$Scene"
New-Item -ItemType Directory -Force -Path $sandboxRoot, $outputRoot | Out-Null
foreach ($name in @('scripts','assets','scenes','shaders','tools','.godot')) {
    $link = Join-Path $sandboxRoot $name
    if (-not (Test-Path -LiteralPath $link)) { New-Item -ItemType Junction -Path $link -Target (Join-Path $projectRoot $name) | Out-Null }
}
$config = [IO.File]::ReadAllText((Join-Path $projectRoot 'project.godot'))
$config = $config.Replace('res://scripts/autoloads/NetworkManager.gd','res://tools/art/offline_network.gd')
$config = $config.Replace('config/icon="res://icon.svg"','')
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'project.godot'),$config)
[IO.File]::WriteAllText((Join-Path $sandboxRoot '.gitignore'),"*`n")
Copy-Item -LiteralPath (Join-Path $sourceRoot "$Scene.tscn") -Destination (Join-Path $sandboxRoot "$Scene.tscn")
$env:APPDATA = Join-Path $sandboxRoot 'userdata'
& 'D:\GoDot\Godot_v4.6.2-stable_win64_console.exe' --path $sandboxRoot --audio-driver Dummy --rendering-method gl_compatibility --resolution 1280x720 --minimized --fixed-fps 30 --write-movie (Join-Path $outputRoot 'frame.png') --quit-after $Frames --log-file (Join-Path $outputRoot 'capture.log') "res://$Scene.tscn" -- --procedural-village
exit $LASTEXITCODE
