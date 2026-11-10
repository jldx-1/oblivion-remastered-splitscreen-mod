param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (!$OutputDirectory) { $OutputDirectory = Join-Path $project 'release' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$stage = Join-Path $output ('stage-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage 'payload'
$ue = Join-Path $payload 'ue4ss'
$scripts = Join-Path $ue 'Mods\LocalSplitScreen\Scripts'
New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'lib') | Out-Null

$vendor = Join-Path $project 'vendor'
Copy-Item -LiteralPath "$vendor\ue4ss\dwmapi.dll" -Destination $payload
Copy-Item -LiteralPath "$vendor\ue4ss\ue4ss\UE4SS.dll","$vendor\ue4ss\ue4ss\LICENSE" -Destination $ue
$settings = [IO.File]::ReadAllText("$vendor\ue4ss\ue4ss\UE4SS-settings.ini")
$settings = $settings -replace '(?m)^SecondsToScanBeforeGivingUp = \d+', 'SecondsToScanBeforeGivingUp = 30'
$settings = $settings -replace '(?m)^bUseUObjectArrayCache = true', 'bUseUObjectArrayCache = false'
$settings = $settings -replace '(?m)^bForceGUObjectArrayForIteration = false', 'bForceGUObjectArrayForIteration = true'
$settings = $settings -replace '(?m)^(ConsoleEnabled|GuiConsoleEnabled|GuiConsoleVisible) = 1', '$1 = 0'
[IO.File]::WriteAllText((Join-Path $ue 'UE4SS-settings.ini'), $settings)

$main = [IO.File]::ReadAllText("$project\src\main.lua")
$main = $main -replace 'preload\.save_id or "[0-9A-F]{32}"', 'preload.save_id'
[IO.File]::WriteAllText((Join-Path $scripts 'main.lua'), $main)
Copy-Item -LiteralPath "$project\build\Release\lss_native_v2.dll","$project\build\Release\SDL3.dll" -Destination $scripts
Get-ChildItem -LiteralPath "$project\src\lib" -Filter '*.lua' -File | Copy-Item -Destination "$scripts\lib"
Set-Content -LiteralPath "$scripts\config.lua" -Encoding ASCII -Value 'return {development=false, companion_prototype=true, user_profiles=true}'
$mod = Split-Path -Parent $scripts
Copy-Item -LiteralPath "$vendor\sdl3\SDL3-3.4.20\LICENSE.txt" -Destination "$mod\SDL-LICENSE.txt"
Copy-Item -LiteralPath "$vendor\lua-5.4.8\doc\readme.html" -Destination "$mod\Lua-LICENSE.html"
Copy-Item -LiteralPath "$PSScriptRoot\installer\Install.ps1" -Destination $stage

$archive = Join-Path $output 'LocalSplitScreen-Windows.zip'
Compress-Archive -Path "$stage\*" -DestinationPath $archive -Force
$setup = Join-Path $output 'LocalSplitScreen-Setup.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$arguments = @(
    '/nologo', '/target:winexe', '/optimize+', '/platform:x64', "/out:$setup",
    "/win32manifest:$PSScriptRoot\installer\Setup.manifest", "/resource:$archive,installer.zip",
    '/reference:System.IO.Compression.FileSystem.dll', '/reference:System.Windows.Forms.dll',
    "$PSScriptRoot\installer\Setup.cs"
)
& $csc @arguments
if ($LASTEXITCODE -ne 0) { throw 'Windows setup compilation failed.' }
Get-FileHash -LiteralPath $setup,$archive | Select-Object Hash,Path
