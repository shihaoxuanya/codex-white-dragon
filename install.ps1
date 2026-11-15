param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexWhiteDragon'),
    [string]$DesktopPath = [Environment]::GetFolderPath('DesktopDirectory'),
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

function Notify([string]$message, [bool]$failed = $false) {
    if ($Quiet) { Write-Output $message; return }
    Add-Type -AssemblyName System.Windows.Forms
    $kind = if ($failed) { [System.Windows.Forms.MessageBoxIcon]::Error } else { [System.Windows.Forms.MessageBoxIcon]::Information }
    [void][System.Windows.Forms.MessageBox]::Show($message, 'Codex 白龙启动', [System.Windows.Forms.MessageBoxButtons]::OK, $kind)
}

try {
    $payload = @(
        'Start-Codex-Animation.vbs', 'Preview-Animation.vbs', 'launcher.ps1', 'animation.html',
        'celestial-background.png', 'character-before.png', 'character-dragon.png', 'white-dragon-icon.ico'
    )
    foreach ($name in $payload) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
            throw "缺少文件：$name。请先完整解压下载的项目文件。"
        }
    }
    if (-not (Test-Path -LiteralPath $DesktopPath -PathType Container)) { throw '找不到桌面文件夹。' }
    $requestedRoot = [IO.Path]::GetFullPath($InstallRoot)
    $markerName = '.codex-white-dragon-install'
    $markerValue = 'CodexWhiteDragonInstaller-v1'
    $root = $requestedRoot
    $suffix = 1
    while (Test-Path -LiteralPath $root) {
        $marker = Join-Path $root $markerName
        if ((Test-Path -LiteralPath $marker -PathType Leaf) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $markerValue)) { break }
        $suffix++
        $root = $requestedRoot + '-' + $suffix
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $marker = Join-Path $root $markerName
    if (-not (Test-Path -LiteralPath $marker)) { Set-Content -LiteralPath $marker -Value $markerValue -Encoding ASCII }
    # Each update gets a fresh version directory. Existing launchers remain
    # usable until the desktop shortcut is switched to the completed copy.
    $versions = Join-Path $root 'Versions'
    $version = Join-Path $versions ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $version -Force | Out-Null
    foreach ($name in $payload) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $version $name) }

    $shell = New-Object -ComObject WScript.Shell
    $wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $launchFile = Join-Path $version 'Start-Codex-Animation.vbs'
    $linkBase = 'Codex 白龙启动'
    $link = Join-Path $DesktopPath ($linkBase + '.lnk')
    $i = 1
    while (Test-Path -LiteralPath $link) {
        $existing = $shell.CreateShortcut($link)
        $args = $existing.Arguments
        $owned = $false
        if ($existing.TargetPath -ieq $wscriptPath -and $args -match '^"([^"]+)"$') {
            try {
                $oldTarget = [IO.Path]::GetFullPath($Matches[1])
                $prefix = [IO.Path]::GetFullPath($versions).TrimEnd('\') + '\'
                $owned = $oldTarget.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($oldTarget) -ieq 'Start-Codex-Animation.vbs'
            } catch { $owned = $false }
        }
        if ($owned) { break }
        $i++
        $link = Join-Path $DesktopPath ($linkBase + ' (' + $i + ').lnk')
    }
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $wscriptPath
    $shortcut.Arguments = '"' + $launchFile + '"'
    $shortcut.WorkingDirectory = $version
    $shortcut.IconLocation = (Join-Path $version 'white-dragon-icon.ico') + ',0'
    $shortcut.Description = '播放白龙变身动画并启动 Codex'
    $shortcut.Save()
    Notify "安装完成！`n`n桌面快捷方式：$([IO.Path]::GetFileName($link))`n安装目录：$root`n`n双击桌面快捷方式即可使用。"
} catch {
    Notify ("安装失败：$($_.Exception.Message)") $true
    exit 1
}
