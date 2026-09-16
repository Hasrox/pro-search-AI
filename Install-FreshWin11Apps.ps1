#Requires -Version 5.1
# Fresh Windows 11 bootstrap installer.
# Save this file as ANSI / UTF-8. Run in an elevated PowerShell window:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\Install-FreshWin11Apps.ps1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipInstalled = $true,
    [string]$ReportDirectory = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'Continue'

$Script:StartTime     = Get-Date
$Script:LogDirectory  = Join-Path $env:TEMP 'Win11FreshInstall'
$Script:DownloadDir   = Join-Path $Script:LogDirectory 'downloads'
$Script:LogFile       = Join-Path $Script:LogDirectory ('install-{0:yyyyMMdd-HHmmss}.log' -f $Script:StartTime)
$Script:Results       = New-Object System.Collections.Generic.List[object]

$Script:FallbackUrls = @{
    FanControl = 'https://github.com/Rem0o/FanControl.Releases/releases/download/V277/FanControl_277_net_10_0_Installer.exe'
    BattleNet  = 'https://downloader.battle.net/download/getInstallerForOs'
    EaApp      = 'https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe'
    Ubisoft    = 'https://ubistatic3-a.akamaihd.net/orbit/launcher_installer/UbisoftConnectInstaller.exe'
    Steam      = 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe'
    Epic       = 'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi'
    Chrome     = 'https://dl.google.com/chrome/install/latest/chrome_installer.exe'
    NvidiaApp  = 'https://us.download.nvidia.com/nvapp/client/11.0.9.251/NVIDIA_app_v11.0.9.251.exe'
}

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

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')]
        [string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '[{0}] [{1,-5}] {2}' -f $stamp, $Level, $Message
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8

    $color = 'Gray'
    switch ($Level) {
        'OK'    { $color = 'Green' }
        'WARN'  { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        'STEP'  { $color = 'Cyan' }
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
        $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
        exit 0
    }
}

function Initialize-Workspace {
    New-Item -ItemType Directory -Force -Path $Script:LogDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $Script:DownloadDir | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log ('Log file: {0}' -f $Script:LogFile)
    Write-Log ('Downloads: {0}' -f $Script:DownloadDir)
    Write-Log ('Host: {0} | OS: {1} | PS: {2}' -f $env:COMPUTERNAME, [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion)
}

function Test-WingetAvailable {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Update-WingetSources {
    if (-not (Test-WingetAvailable)) {
        Write-Log 'winget not found. Installers will use direct downloads only.' 'WARN'
        return $false
    }
    try {
        Write-Log 'Refreshing winget sources...'
        cmd /c 'winget source update --disable-interactivity >nul 2>&1'
        return $true
    }
    catch {
        Write-Log ('winget source update failed: {0}' -f $_.Exception.Message) 'WARN'
        return $true
    }
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][string]$Id)
    if (-not (Test-WingetAvailable)) { return $false }
    $output = cmd /c "winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>nul"
    if (-not $output) { return $false }
    return (($output -join "`n") -match [regex]::Escape($Id))
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
    $percent = 0
    if ($Total -gt 0) { $percent = [int](($Index / $Total) * 100) }
    $activity = 'Fresh Windows 11 installer  [{0}/{1}]' -f $Index, $Total
    $status   = '{0} - {1}' -f $State, $Name
    Write-Progress -Id 1 -Activity $activity -Status $status -PercentComplete $percent
    Write-Log ('[{0}/{1}] {2}: {3}' -f $Index, $Total, $State, $Name) 'STEP'
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$Id
    )
    Write-Log ('winget install --id {0} --exact --scope machine' -f $Id)
    $cmdLine = 'winget install --id {0} --exact --accept-package-agreements --accept-source-agreements --disable-interactivity --scope machine' -f $Id
    cmd /c $cmdLine
    $code = $LASTEXITCODE
    # 0 = success; -1978335189 often means already installed
    if ($code -eq 0 -or $code -eq -1978335189) { return $true }
    Write-Log ('winget exit code {0} for {1}' -f $code, $Id) 'WARN'
    return $false
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    Write-Log ('Downloading {0}' -f $Url)
    try {
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 Win11FreshInstall/1.0' }
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers $headers -MaximumRedirection 8
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
        return $false
    }
    catch {
        Write-Log ('Download failed: {0}' -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Invoke-VendorInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Arguments
    )
    if (-not (Test-Path $Path)) { throw ('Installer not found: {0}' -f $Path) }
    Write-Log ('Launching installer: {0} {1}' -f $Path, $Arguments)
    $isMsi = [IO.Path]::GetExtension($Path) -eq '.msi'
    if ($isMsi) {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', ('"{0}"' -f $Path), $Arguments) -Wait -PassThru
    }
    else {
        $proc = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    }
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010 -or $proc.ExitCode -eq 1641) { return $true }
    Write-Log ('Installer exit code {0}' -f $proc.ExitCode) 'WARN'
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
    $item = New-Object psobject -Property @{
        Name     = $Name
        Method   = $Method
        Status   = $Status
        Detail   = $Detail
        Finished = Get-Date
    }
    $Script:Results.Add($item) | Out-Null
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
        if ($Package.ContainsKey('WingetId') -and $Package.WingetId) {
            if (Test-WingetPackageInstalled -Id $Package.WingetId) { $already = $true }
        }
        if (-not $already -and $Package.ContainsKey('Detect') -and $Package.Detect) {
            if (Test-AppInstalledByName -NamePatterns $Package.Detect) { $already = $true }
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

        if ($Package.ContainsKey('WingetId') -and $Package.WingetId -and (Test-WingetAvailable)) {
            Show-InstallProgress -Name $name -Index $Index -Total $Total -State Installing
            try {
                $installed = Invoke-WingetInstall -Id $Package.WingetId
                if ($installed) { $method = 'winget:' + $Package.WingetId }
            }
            catch {
                $errorText = $_.Exception.Message
                Write-Log $errorText 'ERROR'
            }
        }

        if (-not $installed -and $Package.ContainsKey('Url') -and $Package.Url) {
            Show-InstallProgress -Name $name -Index $Index -Total $Total -State Downloading
            $ext = '.exe'
            if ($Package.Url -match '\.msi(\?|$)') { $ext = '.msi' }
            $safeName = ($name -replace '[^\w\.-]', '_')
            $dest = Join-Path $Script:DownloadDir ($safeName + $ext)
            if (Get-RemoteFile -Url $Package.Url -OutFile $dest) {
                Show-InstallProgress -Name $name -Index $Index -Total $Total -State Installing
                $args = $Script:SilentArgs.GenericExe
                if ($Package.ContainsKey('SilentArgs') -and $Package.SilentArgs) { $args = $Package.SilentArgs }
                try {
                    $installed = Invoke-VendorInstaller -Path $dest -Arguments $args
                    if ($installed) { $method = 'download:' + $Package.Url }
                    else { $errorText = 'Vendor installer returned a non-success exit code.' }
                }
                catch {
                    $errorText = $_.Exception.Message
                    Write-Log $errorText 'ERROR'
                }
            }
            else {
                $errorText = 'Failed to download ' + $Package.Url
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
        Add-Result -Name $name -Method 'WhatIf' -Status Skipped -Detail 'WhatIf - not installed'
    }
}

function Write-FinalReport {
    $end = Get-Date
    $duration = $end - $Script:StartTime
    $ok   = @($Script:Results | Where-Object { $_.Status -eq 'Succeeded' }).Count
    $skip = @($Script:Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $fail = @($Script:Results | Where-Object { $_.Status -eq 'Failed' }).Count

    Write-Progress -Id 1 -Activity 'Fresh Windows 11 installer' -Completed

    $stamp = $end.ToString('yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Force -Path $ReportDirectory | Out-Null
    $txtPath  = Join-Path $ReportDirectory ('Win11-Install-Report-{0}.txt' -f $stamp)
    $htmlPath = Join-Path $ReportDirectory ('Win11-Install-Report-{0}.html' -f $stamp)

    $mins = [int]$duration.TotalMinutes
    $secs = $duration.Seconds

    $summaryLines = New-Object System.Collections.Generic.List[string]
    [void]$summaryLines.Add('============================================================')
    [void]$summaryLines.Add(' Windows 11 Fresh Install Report')
    [void]$summaryLines.Add('============================================================')
    [void]$summaryLines.Add((' Computer : {0}' -f $env:COMPUTERNAME))
    [void]$summaryLines.Add((' User     : {0}' -f $env:USERNAME))
    [void]$summaryLines.Add((' Started  : {0}' -f $Script:StartTime.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$summaryLines.Add((' Finished : {0}' -f $end.ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$summaryLines.Add((' Duration : {0} min {1} sec' -f $mins, $secs))
    [void]$summaryLines.Add((' Log      : {0}' -f $Script:LogFile))
    [void]$summaryLines.Add('------------------------------------------------------------')
    [void]$summaryLines.Add((' Succeeded : {0}' -f $ok))
    [void]$summaryLines.Add((' Skipped   : {0}' -f $skip))
    [void]$summaryLines.Add((' Failed    : {0}' -f $fail))
    [void]$summaryLines.Add('------------------------------------------------------------')

    foreach ($r in $Script:Results) {
        $line = '{0,-36} {1,-10} {2,-28} {3}' -f $r.Name, $r.Status, $r.Method, $r.Detail
        [void]$summaryLines.Add($line)
    }
    [void]$summaryLines.Add('============================================================')

    $text = $summaryLines -join [Environment]::NewLine
    Set-Content -Path $txtPath -Value $text -Encoding UTF8

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8"/>')
    [void]$sb.AppendLine('<title>Windows 11 Fresh Install Report</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('body{font-family:Segoe UI,sans-serif;background:#0f172a;color:#e2e8f0;margin:32px}')
    [void]$sb.AppendLine('h1{margin-bottom:4px}')
    [void]$sb.AppendLine('.meta{color:#94a3b8;margin-bottom:24px}')
    [void]$sb.AppendLine('.cards{display:flex;gap:12px;margin:16px 0 24px}')
    [void]$sb.AppendLine('.card{background:#1e293b;border-radius:12px;padding:16px 20px;min-width:120px}')
    [void]$sb.AppendLine('.card b{display:block;font-size:28px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;background:#1e293b;border-radius:12px;overflow:hidden}')
    [void]$sb.AppendLine('th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #334155}')
    [void]$sb.AppendLine('th{background:#334155}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<h1>Windows 11 Fresh Install Report</h1>')
    [void]$sb.AppendLine(('<div class="meta">{0} | {1} | {2} to {3} ({4}m {5}s)</div>' -f `
        $env:COMPUTERNAME, $env:USERNAME, `
        $Script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'), `
        $end.ToString('yyyy-MM-dd HH:mm:ss'), $mins, $secs))
    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine(('<div class="card"><span>Succeeded</span><b style="color:#4ade80">{0}</b></div>' -f $ok))
    [void]$sb.AppendLine(('<div class="card"><span>Skipped</span><b style="color:#facc15">{0}</b></div>' -f $skip))
    [void]$sb.AppendLine(('<div class="card"><span>Failed</span><b style="color:#f87171">{0}</b></div>' -f $fail))
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('<table><thead><tr><th>Package</th><th>Status</th><th>Method</th><th>Detail</th></tr></thead><tbody>')
    foreach ($r in $Script:Results) {
        $color = '#991b1b'
        $bg    = '#fee2e2'
        if ($r.Status -eq 'Succeeded') { $color = '#166534'; $bg = '#dcfce7' }
        elseif ($r.Status -eq 'Skipped') { $color = '#854d0e'; $bg = '#fef9c3' }
        $n = [System.Net.WebUtility]::HtmlEncode([string]$r.Name)
        $m = [System.Net.WebUtility]::HtmlEncode([string]$r.Method)
        $d = [System.Net.WebUtility]::HtmlEncode([string]$r.Detail)
        $row = '<tr><td>{0}</td><td style="background:{1};color:{2};font-weight:600">{3}</td><td>{4}</td><td>{5}</td></tr>' -f $n, $bg, $color, $r.Status, $m, $d
        [void]$sb.AppendLine($row)
    }
    [void]$sb.AppendLine('</tbody></table>')
    [void]$sb.AppendLine(('<p class="meta">Full log: {0}</p>' -f [System.Net.WebUtility]::HtmlEncode($Script:LogFile)))
    [void]$sb.AppendLine('</body></html>')
    Set-Content -Path $htmlPath -Value $sb.ToString() -Encoding UTF8

    Write-Host ''
    Write-Host $text -ForegroundColor White
    Write-Host ''
    Write-Log ('Text report : {0}' -f $txtPath) 'OK'
    Write-Log ('HTML report : {0}' -f $htmlPath) 'OK'

    try { Start-Process $htmlPath } catch { }

    if ($fail -gt 0) {
        Write-Log 'One or more packages failed. Re-run the script; already-installed items will be skipped.' 'WARN'
        return 1
    }
    return 0
}

function Get-PackageCatalog {
    $list = @()
    $list += @{ Group = 'Runtimes'; Name = 'DirectX End-User Runtime'; WingetId = 'Microsoft.DirectX'; Detect = @('DirectX*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2005 Redistributable (x86)'; WingetId = 'Microsoft.VCRedist.2005.x86'; Detect = @('Microsoft Visual C++ 2005 Redistributable*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2005 Redistributable (x64)'; WingetId = 'Microsoft.VCRedist.2005.x64'; Detect = @('Microsoft Visual C++ 2005 Redistributable (x64)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2008 Redistributable (x86)'; WingetId = 'Microsoft.VCRedist.2008.x86'; Detect = @('Microsoft Visual C++ 2008 Redistributable*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2008 Redistributable (x64)'; WingetId = 'Microsoft.VCRedist.2008.x64'; Detect = @('Microsoft Visual C++ 2008 Redistributable (x64)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2010 Redistributable (x86)'; WingetId = 'Microsoft.VCRedist.2010.x86'; Detect = @('Microsoft Visual C++ 2010  x86 Redistributable*','Microsoft Visual C++ 2010 Redistributable (x86)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2010 Redistributable (x64)'; WingetId = 'Microsoft.VCRedist.2010.x64'; Detect = @('Microsoft Visual C++ 2010  x64 Redistributable*','Microsoft Visual C++ 2010 Redistributable (x64)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2012 Redistributable (x86)'; WingetId = 'Microsoft.VCRedist.2012.x86'; Detect = @('Microsoft Visual C++ 2012 Redistributable (x86)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2012 Redistributable (x64)'; WingetId = 'Microsoft.VCRedist.2012.x64'; Detect = @('Microsoft Visual C++ 2012 Redistributable (x64)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2013 Redistributable (x86)'; WingetId = 'Microsoft.VCRedist.2013.x86'; Detect = @('Microsoft Visual C++ 2013 Redistributable (x86)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2013 Redistributable (x64)'; WingetId = 'Microsoft.VCRedist.2013.x64'; Detect = @('Microsoft Visual C++ 2013 Redistributable (x64)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2015-2026 Redistributable (x86)'; WingetId = 'Microsoft.VCRedist.2015+.x86'; Detect = @('Microsoft Visual C++ 2015-2022 Redistributable (x86)*','Microsoft Visual C++ 2015-2026 Redistributable (x86)*') }
    $list += @{ Group = 'Runtimes'; Name = 'Visual C++ 2015-2026 Redistributable (x64)'; WingetId = 'Microsoft.VCRedist.2015+.x64'; Detect = @('Microsoft Visual C++ 2015-2022 Redistributable (x64)*','Microsoft Visual C++ 2015-2026 Redistributable (x64)*') }
    $list += @{ Group = 'Runtimes'; Name = '.NET Desktop Runtime 6'; WingetId = 'Microsoft.DotNet.DesktopRuntime.6'; Detect = @('Microsoft Windows Desktop Runtime - 6*') }
    $list += @{ Group = 'Runtimes'; Name = '.NET Desktop Runtime 8'; WingetId = 'Microsoft.DotNet.DesktopRuntime.8'; Detect = @('Microsoft Windows Desktop Runtime - 8*') }
    $list += @{ Group = 'Runtimes'; Name = '.NET Desktop Runtime 9'; WingetId = 'Microsoft.DotNet.DesktopRuntime.9'; Detect = @('Microsoft Windows Desktop Runtime - 9*') }
    $list += @{ Group = 'Runtimes'; Name = '.NET Desktop Runtime 10'; WingetId = 'Microsoft.DotNet.DesktopRuntime.10'; Detect = @('Microsoft Windows Desktop Runtime - 10*') }
    $list += @{ Group = 'Launchers'; Name = 'Steam'; WingetId = 'Valve.Steam'; Url = $Script:FallbackUrls.Steam; SilentArgs = $Script:SilentArgs.Steam; Detect = @('Steam') }
    $list += @{ Group = 'Launchers'; Name = 'Battle.net'; WingetId = 'Blizzard.BattleNet'; Url = $Script:FallbackUrls.BattleNet; SilentArgs = $Script:SilentArgs.BattleNet; Detect = @('Battle.net*','Blizzard App*') }
    $list += @{ Group = 'Launchers'; Name = 'EA App (Origins successor)'; WingetId = 'ElectronicArts.EADesktop'; Url = $Script:FallbackUrls.EaApp; SilentArgs = $Script:SilentArgs.EaApp; Detect = @('EA app*','EA Desktop*','Origin') }
    $list += @{ Group = 'Launchers'; Name = 'Ubisoft Connect'; WingetId = 'Ubisoft.Connect'; Url = $Script:FallbackUrls.Ubisoft; SilentArgs = $Script:SilentArgs.Ubisoft; Detect = @('Ubisoft Connect*','Uplay*') }
    $list += @{ Group = 'Launchers'; Name = 'Epic Games Launcher'; WingetId = 'EpicGames.EpicGamesLauncher'; Url = $Script:FallbackUrls.Epic; SilentArgs = $Script:SilentArgs.Epic; Detect = @('Epic Games Launcher*') }
    $list += @{ Group = 'Utilities'; Name = 'NVIDIA App'; WingetId = 'Nvidia.App'; Url = $Script:FallbackUrls.NvidiaApp; SilentArgs = $Script:SilentArgs.NvidiaApp; Detect = @('NVIDIA App*','NVIDIA GeForce Experience*') }
    $list += @{ Group = 'Utilities'; Name = 'Google Chrome'; WingetId = 'Google.Chrome'; Url = $Script:FallbackUrls.Chrome; SilentArgs = $Script:SilentArgs.Chrome; Detect = @('Google Chrome*') }
    $list += @{ Group = 'Utilities'; Name = 'FanControl V277'; WingetId = 'Rem0o.FanControl'; Url = $Script:FallbackUrls.FanControl; SilentArgs = $Script:SilentArgs.FanControl; Detect = @('FanControl*') }
    return $list
}

Assert-Administrator
Initialize-Workspace
Update-WingetSources | Out-Null

$catalog = @(Get-PackageCatalog)
$total = $catalog.Count

Write-Log ('Planning {0} packages' -f $total)
Write-Host ''
Write-Host '  Fresh Windows 11 application bootstrap' -ForegroundColor Cyan
Write-Host ('  {0} packages  |  skip already installed: {1}' -f $total, [bool]$SkipInstalled) -ForegroundColor DarkCyan
Write-Host ''

$i = 0
foreach ($pkg in $catalog) {
    $i++
    try {
        Install-Package -Package $pkg -Index $i -Total $total
    }
    catch {
        Write-Log ('Unhandled error installing {0}: {1}' -f $pkg.Name, $_.Exception.Message) 'ERROR'
        Add-Result -Name $pkg.Name -Method 'Exception' -Status Failed -Detail $_.Exception.Message
    }
}

$exitCode = Write-FinalReport
exit $exitCode
