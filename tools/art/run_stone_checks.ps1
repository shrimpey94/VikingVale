param([switch]$Procedural, [switch]$Preview, [switch]$Toggle)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sandboxRoot = Join-Path $projectRoot 'art_source\validation\stone_pickup_v001'
$outputRoot = Join-Path $projectRoot 'art_source\previews\stone_pickup\v001'
New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
# Junctions expose the actual source and imported resources without copying or
# editing game files. No editor/import is run against this validation project.
foreach ($name in @('scripts', 'assets', 'scenes', 'shaders', 'tools', '.godot')) {
    $link = Join-Path $sandboxRoot $name
    if (-not (Test-Path -LiteralPath $link)) {
        New-Item -ItemType Junction -Path $link -Target (Join-Path $projectRoot $name) | Out-Null
    }
}
foreach ($name in @('world.tscn', 'world3d.tscn', 'player.tscn', 'boot.tscn')) {
    $link = Join-Path $sandboxRoot $name
    if (-not (Test-Path -LiteralPath $link)) {
        New-Item -ItemType HardLink -Path $link -Target (Join-Path $projectRoot $name) | Out-Null
    }
}
$config = [IO.File]::ReadAllText((Join-Path $projectRoot 'project.godot'))
$config = $config.Replace('res://scripts/autoloads/NetworkManager.gd', 'res://tools/art/offline_network.gd')
$config = $config.Replace('config/icon="res://icon.svg"', '')
[IO.File]::WriteAllText((Join-Path $sandboxRoot 'project.godot'), $config)
[IO.File]::WriteAllText((Join-Path $sandboxRoot '.gitignore'), "*`n")
# Runtime user-data/logs stay inside the project, never in the player's profile.
$env:APPDATA = Join-Path $sandboxRoot 'userdata'
$env:VIKINGVALE_TEST_OUTPUT = $outputRoot
$mode = if ($Procedural) { 'fallback' } else { 'authored' }
if ($Preview) { $mode = "preview_$mode" }
if ($Toggle) { $mode = "toggle_$mode" }
$arguments = @('--path', $sandboxRoot, '--audio-driver', 'Dummy', '--log-file', (Join-Path $outputRoot "checks_$mode.log"))
if ($Toggle) {
    $arguments += @('--rendering-method', 'gl_compatibility', '--minimized', '--resolution', '1000x640', 'res://tools/art/verify_stone_toggle.tscn')
} elseif ($Preview) {
    $arguments += @('--rendering-method', 'gl_compatibility', '--minimized', '--resolution', '1000x640', 'res://tools/art/preview_stone_pickup.tscn')
} else {
    $arguments += @('--headless', 'res://tools/art/verify_stone_pickup.tscn')
}
if ($Procedural) { $arguments += @('--', '--procedural-stone') }
& 'D:\GoDot\Godot_v4.6.2-stable_win64_console.exe' @arguments
exit $LASTEXITCODE
