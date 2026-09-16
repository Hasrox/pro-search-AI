#Requires -Version 5.1
<#
.SYNOPSIS
    Fresh Windows 11 bootstrap installer for runtimes, game launchers, and utilities.

.DESCRIPTION
    Installs DirectX End-User Runtime, Visual C++ Redistributables (2005–present),
    .NET Desktop Runtimes, Steam, Battle.net, EA App, Ubisoft Connect, Epic Games
    Launcher, NVIDIA App, Google Chrome, and FanControl.

    Prefers winget. Falls back to official vendor installers when a package is
    missing from the catalog or the winget install fails.

    Writes a console progress log plus a timestamped HTML + text report.

.NOTES
    Run elevated:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-FreshWin11Apps.ps1

    Optional switches:
        -SkipInstalled   Skip packages already detected (default: $true)
        -WhatIf          Print the plan without installing
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipInstalled = $true,
    [string]$ReportDirectory = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'Continue'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$Script:StartTime      = Get-Date
$Script:LogDirectory   = Join-Path $env:TEMP 'Win11FreshInstall'
$Script:DownloadDir    = Join-Path $Script:LogDirectory 'downloads'
$Script:LogFile        = Join-Path $Script:LogDirectory ("install-{0:yyyyMMdd-HHmmss}.log" -f $Script:StartTime)
$Script:Results        = New-Object System.Collections.Generic.List[object]
$Script:CurrentIndex   = 0
$Script:TotalPackages  = 0

# Official / stable vendor URLs used only when winget is unavailable.
$Script:FallbackUrls = @{
    FanControl  = 'https://github.com/Rem0o/FanControl.Releases/releases/download/V277/FanControl_277_net_10_0_Installer.exe'
    BattleNet   = 'https://downloader.battle.net/download/getInstallerForOs'
    EaApp       = 'https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe'
    Ubisoft     = 'https://ubistatic3-a.akamaihd.net/orbit/launcher_installer/UbisoftConnectInstaller.exe'
    Steam       = 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe'
    Epic        = 'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi'
    Chrome      = 'https://dl.google.com/chrome/install/latest/chrome_installer.exe'
    NvidiaApp   = 'https://us.download.nvidia.com/nvapp/client/11.0.9.251/NVIDIA_app_v11.0.9.251.exe'
}

# Silent-install argument sets for downloaded EXEs / MSIs.
$Script:SilentArgs = @{
    FanControl = '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES'
    BattleNet  = '--lang=enUS'
    EaApp      = '/quiet'
    Ubisoft    = '/S'
    Steam      = '/S'
    Epic       = '/qn /norestart'
    Chrome     = '/silent /install'
    NvidiaApp  = '-s'
    GenericExe = '/S'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')]
        [string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '[{0}] [{1,-5}] {2}' -f $stamp, $Level, $Message
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        Write-Host 'This script must run as Administrator. Relaunching...' -ForegroundColor Yellow
        $args = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath)
        )
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args
        exit 0
    }
}

function Initialize-Workspace {
    New-Item -ItemType Directory -Force -Path $Script:LogDirectory, $Script:DownloadDir | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Log "Log file: $($Script:LogFile)" 'INFO'
    Write-Log "Downloads: $($Script:DownloadDir)" 'INFO'
    Write-Log ("Host: {0} | OS: {1} | PS: {2}" -f $env:COMPUTERNAME, [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion) 'INFO'
}

function Test-WingetAvailable {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    return [bool]$cmd
}

function Update-WingetSources {
    if (-not (Test-WingetAvailable)) {
        Write-Log 'winget not found. Installers will use direct downloads only.' 'WARN'
        return $false
    }

    try {
        Write-Log 'Refreshing winget sources...' 'INFO'
        & winget source update --disable-interactivity 2>&1 | Out-Null
        return $true
    }
    catch {
        Write-Log ("winget source update failed: {0}" -f $_.Exception.Message) 'WARN'
        return $true
    }
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][string]$Id)

    if (-not (Test-WingetAvailable)) { return $false }

    $output = & winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) { return $false }
    return ($output -join "`n") -match [regex]::Escape($Id)
}

function Test-AppInstalledByName {
    param([string[]]$NamePatterns)

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $displayNames = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object -ExpandProperty DisplayName

    foreach ($pattern in $NamePatterns) {
        if ($displayNames | Where-Object { $_ -like $pattern }) { return $true }
    }
    return $false
}

function Show-InstallProgress {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total,
        [ValidateSet('Checking', 'Installing', 'Downloading', 'Skipped', 'Succeeded', 'Failed')]
        [string]$State
    )

    $percent = if ($Total -gt 0) { [int](($Index / $Total) * 100) } else { 0 }
    $activity = 'Fresh Windows 11 installer  [{0}/{1}]' -f $Index, $Total
    Write-Progress -Id 1 -Activity $activity -Status ("{0} — {1}" -f $State, $Name) -PercentComplete $percent
    Write-Log ("[{0}/{1}] {2}: {3}" -f $Index, $Total, $State, $Name) 'STEP'
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Override
    )

    $wingetArgs = @(
        'install',
        '--id', $Id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--scope', 'machine'
    )
    if ($Override) { $wingetArgs += @('--override', $Override) }

    Write-Log ("winget {0}" -f ($wingetArgs -join ' ')) 'INFO'

    & winget @wingetArgs
    $code = $LASTEXITCODE

    # 0 = success, -1978335189 (0x8A15002B) often means already installed
    if ($code -eq 0 -or $code -eq -1978335189) { return $true }

    Write-Log ("winget exit code {0} for {1}" -f $code, $Id) 'WARN'
    return $false
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )

    Write-Log "Downloading $Url" 'INFO'
    $headers = @{ 'User-Agent' = 'Mozilla/5.0 Win11FreshInstall/1.0' }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers $headers -MaximumRedirection 8
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
        return $false
    }
    catch {
        Write-Log ("Download failed: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Invoke-VendorInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Arguments
    )

    if (-not (Test-Path $Path)) { throw "Installer not found: $Path" }

    Write-Log ("Launching installer: {0} {1}" -f $Path, $Arguments) 'INFO'

    $isMsi = [IO.Path]::GetExtension($Path) -eq '.msi'
    if ($isMsi) {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$Path`"", $Arguments) -Wait -PassThru
    }
    else {
        $proc = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    }

    # Many vendor bootstrappers return 0 / 3010 (reboot required).
    if ($proc.ExitCode -in 0, 3010, 1641) { return $true }

    Write-Log ("Installer exit code {0}" -f $proc.ExitCode) 'WARN'
    return $false
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][ValidateSet('Succeeded', 'Skipped', 'Failed')]
        [string]$Status,
        [string]$Detail = ''
    )

    $Script:Results.Add([pscustomobject]@{
            Name     = $Name
            Method   = $Method
            Status   = $Status
            Detail   = $Detail
            Finished = (Get-Date)
        }) | Out-Null
}

function Install-Package {
    param(
        [Parameter(Mandatory)][hashtable]$Package,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total
    )

    $name = $Package.Name
    Show-InstallProgress -Name $name -Index $Index -Total $Total -State Checking

    $already = $false
    if ($SkipInstalled) {
        if ($Package.WingetId -and (Test-WingetPackageInstalled -Id $Package.WingetId)) {
            $already = $true
        }
        elseif ($Package.Detect -and (Test-AppInstalledByName -NamePatterns $Package.Detect)) {
            $already = $true
        }
    }

    if ($already) {
        Show-InstallProgress -Name $name -Index $Index -Total $Total -State Skipped
        Add-Result -Name $name -Method 'Detection' -Status Skipped -Detail 'Already installed'
        return
    }

    if ($PSCmdlet.ShouldProcess($name, 'Install')) {
        $installed = $false
        $method    = 'None'
        $errorText = ''

        if ($Package.WingetId -and (Test-WingetAvailable)) {
            Show-InstallProgress -Name $name -Index $Index -Total $Total -State Installing
            try {
                $installed = Invoke-WingetInstall -Id $Package.WingetId
                if ($installed) { $method = "winget:$($Package.WingetId)" }
            }
            catch {
                $errorText = $_.Exception.Message
                Write-Log $errorText 'ERROR'
            }
        }

        if (-not $installed -and $Package.Url) {
            Show-InstallProgress -Name $name -Index $Index -Total $Total -State Downloading
            $ext      = if ($Package.Url -match '\.msi(\?|$)') { '.msi' } else { '.exe' }
            $fileName = ($name -replace '[^\w\.-]', '_') + $ext
            $dest     = Join-Path $Script:DownloadDir $fileName

            if (Get-RemoteFile -Url $Package.Url -OutFile $dest) {
                Show-InstallProgress -Name $name -Index $Index -Total $Total -State Installing
                $args = if ($Package.SilentArgs) { $Package.SilentArgs } else { $Script:SilentArgs.GenericExe }
                try {
                    $installed = Invoke-VendorInstaller -Path $dest -Arguments $args
                    if ($installed) { $method = "download:$($Package.Url)" }
                    else { $errorText = 'Vendor installer returned a non-success exit code.' }
                }
                catch {
                    $errorText = $_.Exception.Message
                    Write-Log $errorText 'ERROR'
                }
            }
            else {
                $errorText = "Failed to download $($Package.Url)"
            }
        }

        if ($installed) {
            Show-InstallProgress -Name $name -Index $Index -Total $Total -State Succeeded
            Add-Result -Name $name -Method $method -Status Succeeded
        }
        else {
            Show-InstallProgress -Name $name -Index $Index -Total $Total -State Failed
            if (-not $errorText) { $errorText = 'No installer method succeeded.' }
            Add-Result -Name $name -Method $method -Status Failed -Detail $errorText
        }
    }
    else {
        Add-Result -Name $name -Method 'WhatIf' -Status Skipped -Detail 'WhatIf — not installed'
    }
}

function Write-FinalReport {
    $end      = Get-Date
    $duration = $end - $Script:StartTime
    $ok       = @($Script:Results | Where-Object Status -eq 'Succeeded').Count
    $skip     = @($Script:Results | Where-Object Status -eq 'Skipped').Count
    $fail     = @($Script:Results | Where-Object Status -eq 'Failed').Count

    Write-Progress -Id 1 -Activity 'Fresh Windows 11 installer' -Completed

    $stamp      = $end.ToString('yyyyMMdd-HHmmss')
    $txtPath    = Join-Path $ReportDirectory "Win11-Install-Report-$stamp.txt"
    $htmlPath   = Join-Path $ReportDirectory "Win11-Install-Report-$stamp.html"
    New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null

    $summaryLines = @(
        '============================================================'
        ' Windows 11 Fresh Install Report'
        '============================================================'
        " Computer : $env:COMPUTERNAME"
        " User     : $env:USERNAME"
        " Started  : $($Script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        " Finished : $($end.ToString('yyyy-MM-dd HH:mm:ss'))"
        " Duration : $([int]$duration.TotalMinutes) min $($duration.Seconds) sec"
        " Log      : $($Script:LogFile)"
        '------------------------------------------------------------'
        (" Succeeded : {0}" -f $ok)
        (" Skipped   : {0}" -f $skip)
        (" Failed    : {0}" -f $fail)
        '------------------------------------------------------------'
    )

    $rows = $Script:Results | ForEach-Object {
        '{0,-36} {1,-10} {2,-28} {3}' -f $_.Name, $_.Status, $_.Method, $_.Detail
    }

    $text = ($summaryLines + $rows + '============================================================') -join [Environment]::NewLine
    Set-Content -Path $txtPath -Value $text -Encoding UTF8

    $rowHtml = ($Script:Results | ForEach-Object {
            $color = switch ($_.Status) {
                'Succeeded' { '#166534' }
                'Skipped'   { '#854d0e' }
                default     { '#991b1b' }
            }
            $bg = switch ($_.Status) {
                'Succeeded' { '#dcfce7' }
                'Skipped'   { '#fef9c3' }
                default     { '#fee2e2' }
            }
            '<tr><td>{0}</td><td style="background:{1};color:{2};font-weight:600">{3}</td><td>{4}</td><td>{5}</td></tr>' -f `
            [System.Net.WebUtility]::HtmlEncode($_.Name), $bg, $color, $_.Status, `
            [System.Net.WebUtility]::HtmlEncode($_.Method), [System.Net.WebUtility]::HtmlEncode($_.Detail)
        }) -join [Environment]::NewLine

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>Windows 11 Fresh Install Report</title>
<style>
  body { font-family: Segoe UI, system-ui, sans-serif; background:#0f172a; color:#e2e8f0; margin:32px; }
  h1 { margin-bottom:4px; }
  .meta { color:#94a3b8; margin-bottom:24px; }
  .cards { display:flex; gap:12px; margin:16px 0 24px; }
  .card { background:#1e293b; border-radius:12px; padding:16px 20px; min-width:120px; }
  .card b { display:block; font-size:28px; }
  table { border-collapse:collapse; width:100%; background:#1e293b; border-radius:12px; overflow:hidden; }
  th, td { text-align:left; padding:10px 12px; border-bottom:1px solid #334155; }
  th { background:#334155; }
</style>
</head>
<body>
  <h1>Windows 11 Fresh Install Report</h1>
  <div class="meta">
    $env:COMPUTERNAME &middot; $env:USERNAME &middot;
    $($Script:StartTime.ToString('yyyy-MM-dd HH:mm:ss')) → $($end.ToString('yyyy-MM-dd HH:mm:ss'))
    ($([int]$duration.TotalMinutes)m $($duration.Seconds)s)
  </div>
  <div class="cards">
    <div class="card"><span>Succeeded</span><b style="color:#4ade80">$ok</b></div>
    <div class="card"><span>Skipped</span><b style="color:#facc15">$skip</b></div>
    <div class="card"><span>Failed</span><b style="color:#f87171">$fail</b></div>
  </div>
  <table>
    <thead><tr><th>Package</th><th>Status</th><th>Method</th><th>Detail</th></tr></thead>
    <tbody>
      $rowHtml
    </tbody>
  </table>
  <p class="meta">Full log: $($Script:LogFile)</p>
</body>
</html>
"@
    Set-Content -Path $htmlPath -Value $html -Encoding UTF8

    Write-Host ''
    Write-Host $text -ForegroundColor White
    Write-Host ''
    Write-Log "Text report : $txtPath" 'OK'
    Write-Log "HTML report : $htmlPath" 'OK'

    if ($fail -gt 0) {
        Write-Log 'One or more packages failed. Re-run the script; already-installed items will be skipped.' 'WARN'
        try { Start-Process $htmlPath } catch { }
        return 1
    }

    try { Start-Process $htmlPath } catch { }
    return 0
}

# ---------------------------------------------------------------------------
# Catalog
# Visual C++ 2015+ covers VS 2015 / 2017 / 2019 / 2022 / 2026 (v14 ABI).
# 2008 is the closest official year to "2009"; 2005 is included for old games.
# FanControl V277 targets .NET 10, so Desktop Runtime 10 is required.
# ---------------------------------------------------------------------------
function Get-PackageCatalog {
    return @(
        @{
            Group = 'Runtimes'
            Name = 'DirectX End-User Runtime'
            WingetId = 'Microsoft.DirectX'
            Detect = @('DirectX*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2005 Redistributable (x86)'
            WingetId = 'Microsoft.VCRedist.2005.x86'
            Detect = @('Microsoft Visual C++ 2005 Redistributable*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2005 Redistributable (x64)'
            WingetId = 'Microsoft.VCRedist.2005.x64'
            Detect = @('Microsoft Visual C++ 2005 Redistributable (x64)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2008 Redistributable (x86)'
            WingetId = 'Microsoft.VCRedist.2008.x86'
            Detect = @('Microsoft Visual C++ 2008 Redistributable*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2008 Redistributable (x64)'
            WingetId = 'Microsoft.VCRedist.2008.x64'
            Detect = @('Microsoft Visual C++ 2008 Redistributable (x64)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2010 Redistributable (x86)'
            WingetId = 'Microsoft.VCRedist.2010.x86'
            Detect = @('Microsoft Visual C++ 2010  x86 Redistributable*', 'Microsoft Visual C++ 2010 Redistributable (x86)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2010 Redistributable (x64)'
            WingetId = 'Microsoft.VCRedist.2010.x64'
            Detect = @('Microsoft Visual C++ 2010  x64 Redistributable*', 'Microsoft Visual C++ 2010 Redistributable (x64)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2012 Redistributable (x86)'
            WingetId = 'Microsoft.VCRedist.2012.x86'
            Detect = @('Microsoft Visual C++ 2012 Redistributable (x86)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2012 Redistributable (x64)'
            WingetId = 'Microsoft.VCRedist.2012.x64'
            Detect = @('Microsoft Visual C++ 2012 Redistributable (x64)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2013 Redistributable (x86)'
            WingetId = 'Microsoft.VCRedist.2013.x86'
            Detect = @('Microsoft Visual C++ 2013 Redistributable (x86)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2013 Redistributable (x64)'
            WingetId = 'Microsoft.VCRedist.2013.x64'
            Detect = @('Microsoft Visual C++ 2013 Redistributable (x64)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2015-2026 Redistributable (x86)'
            WingetId = 'Microsoft.VCRedist.2015+.x86'
            Detect = @('Microsoft Visual C++ 2015-2022 Redistributable (x86)*', 'Microsoft Visual C++ 2015-2026 Redistributable (x86)*')
        }
        @{
            Group = 'Runtimes'
            Name = 'Visual C++ 2015-2026 Redistributable (x64)'
            WingetId = 'Microsoft.VCRedist.2015+.x64'
            Detect = @('Microsoft Visual C++ 2015-2022 Redistributable (x64)*', 'Microsoft Visual C++ 2015-2026 Redistributable (x64)*')
        }
        @{
            Group = 'Runtimes'
            Name = '.NET Desktop Runtime 6'
            WingetId = 'Microsoft.DotNet.DesktopRuntime.6'
            Detect = @('Microsoft Windows Desktop Runtime - 6*')
        }
        @{
            Group = 'Runtimes'
            Name = '.NET Desktop Runtime 8'
            WingetId = 'Microsoft.DotNet.DesktopRuntime.8'
            Detect = @('Microsoft Windows Desktop Runtime - 8*')
        }
        @{
            Group = 'Runtimes'
            Name = '.NET Desktop Runtime 9'
            WingetId = 'Microsoft.DotNet.DesktopRuntime.9'
            Detect = @('Microsoft Windows Desktop Runtime - 9*')
        }
        @{
            Group = 'Runtimes'
            Name = '.NET Desktop Runtime 10'
            WingetId = 'Microsoft.DotNet.DesktopRuntime.10'
            Detect = @('Microsoft Windows Desktop Runtime - 10*')
        }
        @{
            Group = 'Launchers'
            Name = 'Steam'
            WingetId = 'Valve.Steam'
            Url = $Script:FallbackUrls.Steam
            SilentArgs = $Script:SilentArgs.Steam
            Detect = @('Steam')
        }
        @{
            Group = 'Launchers'
            Name = 'Battle.net'
            WingetId = 'Blizzard.BattleNet'
            Url = $Script:FallbackUrls.BattleNet
            SilentArgs = $Script:SilentArgs.BattleNet
            Detect = @('Battle.net*', 'Blizzard App*')
        }
        @{
            Group = 'Launchers'
            Name = 'EA App (Origins successor)'
            WingetId = 'ElectronicArts.EADesktop'
            Url = $Script:FallbackUrls.EaApp
            SilentArgs = $Script:SilentArgs.EaApp
            Detect = @('EA app*', 'EA Desktop*', 'Origin')
        }
        @{
            Group = 'Launchers'
            Name = 'Ubisoft Connect'
            WingetId = 'Ubisoft.Connect'
            Url = $Script:FallbackUrls.Ubisoft
            SilentArgs = $Script:SilentArgs.Ubisoft
            Detect = @('Ubisoft Connect*', 'Uplay*')
        }
        @{
            Group = 'Launchers'
            Name = 'Epic Games Launcher'
            WingetId = 'EpicGames.EpicGamesLauncher'
            Url = $Script:FallbackUrls.Epic
            SilentArgs = $Script:SilentArgs.Epic
            Detect = @('Epic Games Launcher*')
        }
        @{
            Group = 'Utilities'
            Name = 'NVIDIA App'
            WingetId = 'Nvidia.App'
            Url = $Script:FallbackUrls.NvidiaApp
            SilentArgs = $Script:SilentArgs.NvidiaApp
            Detect = @('NVIDIA App*', 'NVIDIA GeForce Experience*')
        }
        @{
            Group = 'Utilities'
            Name = 'Google Chrome'
            WingetId = 'Google.Chrome'
            Url = $Script:FallbackUrls.Chrome
            SilentArgs = $Script:SilentArgs.Chrome
            Detect = @('Google Chrome*')
        }
        @{
            Group = 'Utilities'
            Name = 'FanControl V277'
            WingetId = 'Rem0o.FanControl'
            Url = $Script:FallbackUrls.FanControl
            SilentArgs = $Script:SilentArgs.FanControl
            Detect = @('FanControl*')
        }
    )
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Assert-Administrator
Initialize-Workspace
Update-WingetSources | Out-Null

$catalog = Get-PackageCatalog
$Script:TotalPackages = $catalog.Count

Write-Log ("Planning {0} packages" -f $Script:TotalPackages) 'INFO'
Write-Host ''
Write-Host '  Fresh Windows 11 application bootstrap' -ForegroundColor Cyan
Write-Host ("  {0} packages  |  skip already installed: {1}" -f $Script:TotalPackages, [bool]$SkipInstalled) -ForegroundColor DarkCyan
Write-Host ''

$i = 0
foreach ($pkg in $catalog) {
    $i++
    $Script:CurrentIndex = $i
    try {
        Install-Package -Package $pkg -Index $i -Total $Script:TotalPackages
    }
    catch {
        Write-Log ("Unhandled error installing {0}: {1}" -f $pkg.Name, $_.Exception.Message) 'ERROR'
        Add-Result -Name $pkg.Name -Method 'Exception' -Status Failed -Detail $_.Exception.Message
    }
}

$exitCode = Write-FinalReport
exit $exitCode
