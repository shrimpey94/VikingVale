# DEVLOG CAPTURE RULE implementation for the 1.7.2 forest batch (trees + Stick Pickup).
#
# Builds an ISOLATED sandbox project (junctions + offline network stub + redirected
# APPDATA), exports the login-burst world state from a COPY of the newest server DB
# backup, scouts one camera spot just outside each of the five villages, then records
# 2d_old / 2d_new / 3d_old / 3d_new per village: identical camera, 150 frames at 30 fps,
# 1080x960, no HUD. "old" = --procedural-forest. Frames are encoded to H.264 MP4 with
# D:\ffmpeg (first frame kept as a PNG still). Capture only: no game code, no commits.
#
#   -Stage all|snapshot|scout|record   -Towns kjelvik,frostheim,...   -Release 1.7.2_forest
param([ValidateSet('all','snapshot','scout','record')][string]$Stage = 'all',
      [string]$Towns = 'kjelvik,frostheim,ironwood_keep,eastmark_post,bjorns_landing',
      [string]$Release = '1.7.2_forest',
      [string]$Renderers = '2d,3d',
      [string]$Variants = 'old,new',
      [string]$OldFlags = '--procedural-forest',   # kill-switches applied to the "old" passes (comma-separated)
      [string]$Species = '',                        # batch display names for the scout (default: 1.7.2 forest trees)
      [string]$Types = '',                          # their type_strs (e.g. 'rock,herb')
      [string]$Backup = '')
$ErrorActionPreference = 'Stop'
$godot  = 'D:\GoDot\Godot_v4.6.2-stable_win64_console.exe'
$ffmpeg = 'D:\ffmpeg\bin\ffmpeg.exe'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sandboxRoot = Join-Path $projectRoot 'art_source\validation\devlog_capture'
$outputRoot  = Join-Path $projectRoot "art_source\previews\devlog\$Release"
$snapshot    = Join-Path $sandboxRoot 'world_snapshot.json'
New-Item -ItemType Directory -Force -Path $sandboxRoot, $outputRoot, (Join-Path $sandboxRoot 'db') | Out-Null

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
"extends Node`nfunc _ready() -> void:`n`tget_tree().root.add_child.call_deferred(preload(`"res://tools/art/devlog_capture_harness.gd`").new())`n")
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'devlog_boot.tscn'),
"[gd_scene load_steps=2 format=3]`n`n[ext_resource type=`"Script`" path=`"res://devlog_boot.gd`" id=`"1`"]`n`n[node name=`"Boot`" type=`"Node`"]`nscript = ExtResource(`"1`")`n")
$env:APPDATA = Join-Path $sandboxRoot 'userdata'

function Invoke-Godot([string[]]$UserArgs, [string]$LogName) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $godot --path $sandboxRoot --audio-driver Dummy --resolution 1080x960 --minimized --fixed-fps 30 `
        --log-file (Join-Path $outputRoot $LogName) 'res://devlog_boot.tscn' -- @UserArgs
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
    [IO.File]::WriteAllText((Join-Path $outputRoot 'SOURCE_DB.txt'), "Snapshot exported from a copy of: $Backup`r`n")
}

# ── 2. scout one spot per village ────────────────────────────────────────────
if ($Stage -in @('all','scout')) {
    $scoutArgs = @("--devlog-mode=scout", "--devlog-out=$outputRoot", "--devlog-snapshot=$snapshot")
    if ($PSBoundParameters.ContainsKey('Towns')) { $scoutArgs += "--devlog-towns=$Towns" }   # re-scout only these; others kept
    if ($Species) { $scoutArgs += "--devlog-species=$Species" }
    if ($Types)   { $scoutArgs += "--devlog-types=$Types" }
    Invoke-Godot $scoutArgs 'scout_godot.log'
    if (-not (Test-Path (Join-Path $outputRoot 'spots.json'))) { throw 'scout produced no spots.json' }
}

# ── 3. record 4 clips per village ────────────────────────────────────────────
if ($Stage -in @('all','record')) {
    $spots = (Get-Content (Join-Path $outputRoot 'spots.json') -Raw | ConvertFrom-Json).spots
    foreach ($town in ($Towns -split ',')) {
        $s = $spots.$town
        if ($null -eq $s) { Write-Warning "no spot for $town"; continue }
        $townDir = Join-Path $outputRoot $town
        New-Item -ItemType Directory -Force -Path $townDir | Out-Null
        foreach ($renderer in ($Renderers -split ',')) {
            foreach ($variant in ($Variants -split ',')) {
                $clip = "${renderer}_$variant"
                $clipDir = Join-Path $townDir $clip
                if (Test-Path $clipDir) { Remove-Item -Recurse -Force $clipDir }
                New-Item -ItemType Directory -Force -Path $clipDir | Out-Null
                $args = @("--devlog-mode=record", "--devlog-out=$clipDir", "--devlog-snapshot=$snapshot",
                          "--devlog-town=$town", "--devlog-renderer=$renderer",
                          ("--devlog-spot={0},{1}" -f [math]::Round($s.x), [math]::Round($s.y)),
                          ("--devlog-look={0},{1}" -f [math]::Round($s.look_x), [math]::Round($s.look_y)))
                if ($variant -eq 'old') { $args += ($OldFlags -split ',') }
                Invoke-Godot $args "$town`_$clip`_godot.log"
                $frames = Join-Path $clipDir 'frames'
                $count = (Get-ChildItem $frames -Filter '*.png' -ErrorAction SilentlyContinue | Measure-Object).Count
                if ($count -lt 150) { Write-Warning "$town $clip : only $count frames"; continue }
                $mp4 = Join-Path $townDir "$clip.mp4"
                & $ffmpeg -y -loglevel error -framerate 30 -i (Join-Path $frames '%04d.png') `
                    -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -r 30 -movflags +faststart $mp4
                Copy-Item (Join-Path $frames '0000.png') (Join-Path $townDir "$clip`_first_frame.png") -Force
                Move-Item (Join-Path $clipDir 'meta.json') (Join-Path $townDir "$clip`_meta.json") -Force
                Remove-Item -Recurse -Force $clipDir
                Write-Host "encoded $town/$clip.mp4 ($count frames)"
            }
        }
    }
}
Write-Host "DONE -> $outputRoot"
