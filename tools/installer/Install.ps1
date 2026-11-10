param(
    [string]$GameDirectory,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$exe = 'OblivionRemastered\Binaries\Win64\OblivionRemastered-Win64-Shipping.exe'
$supportedHash = 'B7BE7E6EBE9424F6FDF274F5E7A59372DE103E043AB5B66C60E021C0C89DF457'
$payload = Join-Path $PSScriptRoot 'payload'

function Find-Game {
    $steam = @(
        (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
        (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $steam) {
        $libraries = @($root)
        $manifest = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $manifest) {
            $libraries += [regex]::Matches([IO.File]::ReadAllText($manifest), '(?m)^\s*"path"\s*"([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value.Replace('\\','\') }
        }
        foreach ($library in $libraries) {
            $candidate = Join-Path $library 'steamapps\common\Oblivion Remastered'
            if (Test-Path -LiteralPath (Join-Path $candidate $exe) -PathType Leaf) { return $candidate }
        }
    }
}

function Assert-RegularPath([string]$Path, [string]$Root) {
    $cursor = $Path
    while ($cursor.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Installation encountered a linked path at $cursor"
            }
        }
        if ($cursor -eq $Root) { return }
        $cursor = Split-Path -Parent $cursor
    }
    throw "Invalid destination $Path"
}

function Test-PlaytestFile($Relative, $Destination, $Source, $CurrentHash) {
    switch -Exact ($Relative) {
        'ue4ss\Mods\LocalSplitScreen\Scripts\config.lua' {
            # The default config deployed by the development playtest runner.
            return $CurrentHash -eq '1F4D8EF9B0BA578F940C60415DAE16197185A5A6E66CC5BF8AA7EAB886FF12EE'
        }
        'ue4ss\Mods\LocalSplitScreen\Scripts\main.lua' {
            # The release build removes the development fixture's fallback ID.
            $playtest = [IO.File]::ReadAllText($Destination)
            $preview = $playtest -replace 'preload\.save_id or "[0-9A-F]{32}"', 'preload.save_id'
            return $preview -ceq [IO.File]::ReadAllText($Source)
        }
    }
    return $false
}

if (Get-Process -Name 'OblivionRemastered-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Close Oblivion Remastered before running the installer.'
}
if (!$GameDirectory) { $GameDirectory = Find-Game }
if (!$GameDirectory) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Select the Oblivion Remastered installation folder'
    $picker.ShowNewFolderButton = $false
    try {
        if ($picker.ShowDialog() -ne 'OK') { throw 'Installation cancelled.' }
        $GameDirectory = $picker.SelectedPath
    } finally { $picker.Dispose() }
}
$game = (Resolve-Path -LiteralPath $GameDirectory).Path
$shipping = Join-Path $game $exe
Assert-RegularPath $shipping $game
if (!(Test-Path -LiteralPath $shipping -PathType Leaf)) { throw 'The selected folder is not an Oblivion Remastered installation.' }
if ((Get-FileHash -LiteralPath $shipping).Hash -ne $supportedHash) {
    throw 'This preview supports only the tested Steam game build (1.512.105).'
}

$bin = Split-Path -Parent $shipping
$list = Join-Path $bin 'ue4ss\Mods\mods.txt'
$manifest = Join-Path $bin 'ue4ss\Mods\LocalSplitScreen\installed-files.json'
Assert-RegularPath $list $game
Assert-RegularPath $manifest $game
$owned = @{}
if (Test-Path -LiteralPath $manifest) {
    foreach ($entry in (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json)) {
        $owned[$entry.path] = $entry.hash
    }
}
$writes = @()
foreach ($file in Get-ChildItem -LiteralPath $payload -File -Recurse) {
    $relative = $file.FullName.Substring($payload.Length + 1)
    $destination = Join-Path $bin $relative
    Assert-RegularPath $destination $game
    $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
    $copy = $true
    if (Test-Path -LiteralPath $destination) {
        $current = (Get-FileHash -LiteralPath $destination).Hash
        if ($current -eq $hash) { $copy = $false }
        elseif ($relative -eq 'ue4ss\UE4SS-settings.ini' -and !$owned.ContainsKey($relative)) {
            # Respect settings from an existing compatible loader.
            continue
        }
        elseif ($owned[$relative] -ne $current -and
            ($owned.ContainsKey($relative) -or !(Test-PlaytestFile $relative $destination $file.FullName $current))) {
            throw "An existing file would be overwritten at $destination"
        }
    }
    $writes += @{ source=$file.FullName; destination=$destination; copy=$copy; path=$relative; hash=$hash }
}
if ($VerifyOnly) { Write-Output "Verified installer and game folder at $game"; return }

foreach ($write in $writes) {
    if ($write.copy) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $write.destination) | Out-Null
        Copy-Item -LiteralPath $write.source -Destination $write.destination
    }
}
$writes | Select-Object @{n='path';e={$_.path}},@{n='hash';e={$_.hash}} | ConvertTo-Json |
    Set-Content -LiteralPath $manifest -Encoding UTF8
$mods = if (Test-Path -LiteralPath $list) { [IO.File]::ReadAllText($list) } else { '' }
$mods = [regex]::Replace($mods, '(?im)^[ \t]*LocalSplitScreen[ \t]*:[^\r\n]*', '')
[IO.File]::WriteAllText($list, "LocalSplitScreen : 1`r`n" + $mods.TrimStart([char[]]"`r`n"), [Text.UTF8Encoding]::new($false))
Write-Output 'Installed Local Split Screen. Launch the game normally from Steam.'
