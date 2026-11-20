# DEVLOG CAPTURE RULE implementation for the 1.7.5 town families
# (08 buildings, 09 civic, 10 forge, 11 bank, 16 townprops, 17 walls).
#
# Copy of capture_devlog_forest.ps1 per family: ISOLATED sandbox project (junctions +
# offline network stub + redirected APPDATA/LOCALAPPDATA/TEMP on this drive), world
# state from a COPY of the newest server DB backup, scouts 2-3 real-map spots where
# each family stands (different villages first), then records 2d_old / 2d_new /
# 3d_old / 3d_new per spot: identical camera, 150 frames at 30 fps, 1080x960, no HUD.
# "old" = that family's kill switch (--procedural-<family>). Encoded to H.264 MP4 with
# D:\ffmpeg (first frame kept as a PNG still). Capture only: no game code, no commits.
#
#   -Stage all|snapshot|scout|record   -Families buildings,civic,...   -Release 1.7.5
param([ValidateSet('all','snapshot','scout','record')][string]$Stage = 'all',
      [string]$Families = 'buildings,civic,forge,bank,townprops,walls',
      [string]$Release = '1.7.5',
      [string]$Renderers = '2d,3d',
      [string]$Variants = 'old,new',
      [string]$Backup = '')
$ErrorActionPreference = 'Stop'
$godot  = 'D:\GoDot\Godot_v4.6.2-stable_win64_console.exe'
$ffmpeg = 'D:\ffmpeg\bin\ffmpeg.exe'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sandboxRoot = Join-Path $projectRoot 'art_source\validation\devlog_capture_town'
$snapshot    = Join-Path $sandboxRoot 'world_snapshot.json'
New-Item -ItemType Directory -Force -Path $sandboxRoot, (Join-Path $sandboxRoot 'db') | Out-Null

# ── sandbox project ──────────────────────────────────────────────────────────
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
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'devlog_boot.gd'),
"extends Node`nfunc _ready() -> void:`n`tget_tree().root.add_child.call_deferred(preload(`"res://tools/art/devlog_town_harness.gd`").new())`n")
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'devlog_boot.tscn'),
"[gd_scene load_steps=2 format=3]`n`n[ext_resource type=`"Script`" path=`"res://devlog_boot.gd`" id=`"1`"]`n`n[node name=`"Boot`" type=`"Node`"]`nscript = ExtResource(`"1`")`n")
$env:APPDATA = Join-Path $sandboxRoot 'userdata'
$env:LOCALAPPDATA = Join-Path $sandboxRoot 'userdata\local'
$env:TEMP = Join-Path $sandboxRoot 'tmp'; $env:TMP = $env:TEMP
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, $env:TEMP | Out-Null

function Invoke-Godot([string[]]$UserArgs, [string]$LogPath) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $godot --path $sandboxRoot --audio-driver Dummy --resolution 1080x960 --minimized --fixed-fps 30 `
        --log-file $LogPath 'res://devlog_boot.tscn' -- @UserArgs | Where-Object { "$_" -match '^(DEVLOG|SCRIPT ERROR|ERROR)' }
    $ErrorActionPreference = $prev
}

# ── 1. DB snapshot from a COPY of the newest backup (never the live DB) ──────
if ($Stage -in @('all','snapshot')) {
    if (-not $Backup) {
        $Backup = (Get-ChildItem (Join-Path $projectRoot 'server') -Filter 'game_server.db.bak_*' |
                   Where-Object { $_.Name -notmatch '-(shm|wal)$' } | Sort-Object Name | Select-Object -Last 1).FullName
    }
    if (-not $Backup) { throw 'No server DB backup found (server\game_server.db.bak_*)' }
    $dbCopy = Join-Path $sandboxRoot 'db\snapshot.db'
    Copy-Item -LiteralPath $Backup -Destination $dbCopy -Force
    foreach ($suffix in @('-wal','-shm')) {
        if (Test-Path -LiteralPath ($Backup + $suffix)) { Copy-Item -LiteralPath ($Backup + $suffix) -Destination ($dbCopy + $suffix) -Force }
        elseif (Test-Path -LiteralPath ($dbCopy + $suffix)) { Remove-Item -LiteralPath ($dbCopy + $suffix) -Force }
    }
    Write-Host "DB backup used: $Backup"
    & python -I (Join-Path $PSScriptRoot 'export_db_snapshot.py') $dbCopy $snapshot
    if ($LASTEXITCODE -ne 0) { throw 'snapshot export failed' }
    [IO.File]::WriteAllText((Join-Path $sandboxRoot 'SOURCE_DB.txt'), "Snapshot exported from a copy of: $Backup`r`n")
}

foreach ($family in ($Families -split ',')) {
    $outputRoot = Join-Path $projectRoot "art_source\previews\devlog\${Release}_$family"
    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
    Copy-Item (Join-Path $sandboxRoot 'SOURCE_DB.txt') (Join-Path $outputRoot 'SOURCE_DB.txt') -Force -ErrorAction SilentlyContinue

    # ── 2. scout 2-3 spots where this family stands ──────────────────────────
    if ($Stage -in @('all','scout')) {
        Invoke-Godot @("--devlog-mode=townscout", "--devlog-family=$family", "--devlog-out=$outputRoot",
                       "--devlog-snapshot=$snapshot") (Join-Path $outputRoot 'scout_godot.log')
        if (-not (Test-Path (Join-Path $outputRoot 'spots.json'))) { throw "scout produced no spots.json for $family" }
    }

    # ── 3. record 4 clips per spot ───────────────────────────────────────────
    if ($Stage -in @('all','record')) {
        $spots = (Get-Content (Join-Path $outputRoot 'spots.json') -Raw | ConvertFrom-Json).spots
        foreach ($loc in $spots.PSObject.Properties.Name) {
            $s = $spots.$loc
            $locDir = Join-Path $outputRoot $loc
            New-Item -ItemType Directory -Force -Path $locDir | Out-Null
            foreach ($renderer in ($Renderers -split ',')) {
                foreach ($variant in ($Variants -split ',')) {
                    $clip = "${renderer}_$variant"
                    $clipDir = Join-Path $locDir $clip
                    if (Test-Path $clipDir) { Remove-Item -Recurse -Force $clipDir }
                    New-Item -ItemType Directory -Force -Path $clipDir | Out-Null
                    $a = @("--devlog-mode=record", "--devlog-out=$clipDir", "--devlog-snapshot=$snapshot",
                           "--devlog-town=$loc", "--devlog-renderer=$renderer",
                           ("--devlog-spot={0},{1}" -f [math]::Round($s.x), [math]::Round($s.y)),
                           ("--devlog-look={0},{1}" -f [math]::Round($s.look_x), [math]::Round($s.look_y)))
                    if ($variant -eq 'old') { $a += "--procedural-$family" }
                    Invoke-Godot $a (Join-Path $locDir "$clip`_godot.log")
                    $frames = Join-Path $clipDir 'frames'
                    $count = (Get-ChildItem $frames -Filter '*.png' -ErrorAction SilentlyContinue | Measure-Object).Count
                    if ($count -lt 150) { Write-Warning "$family $loc $clip : only $count frames"; continue }
                    $mp4 = Join-Path $locDir "$clip.mp4"
                    & $ffmpeg -y -loglevel error -framerate 30 -i (Join-Path $frames '%04d.png') `
                        -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -r 30 -movflags +faststart $mp4
                    Copy-Item (Join-Path $frames '0000.png') (Join-Path $locDir "$clip`_first_frame.png") -Force
                    Move-Item (Join-Path $clipDir 'meta.json') (Join-Path $locDir "$clip`_meta.json") -Force
                    Remove-Item -Recurse -Force $clipDir
                    Write-Host "encoded $family/$loc/$clip.mp4 ($count frames)"
                }
            }
        }
    }
    Write-Host "DONE $family -> $outputRoot"
}
