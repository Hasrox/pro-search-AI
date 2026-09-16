## How to run

Open **PowerShell as Administrator** on the fresh Windows 11 box:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Install-FreshWin11Apps.ps1
```

Dry run (prints the plan, installs nothing):

```powershell
.\Install-FreshWin11Apps.ps1 -WhatIf
```

Reports land on the Desktop as:

- `Win11-Install-Report-yyyyMMdd-HHmmss.txt`
- `Win11-Install-Report-yyyyMMdd-HHmmss.html` (opens automatically)
- Full log under `%TEMP%\Win11FreshInstall\`

---

## What it installs

| Group | Packages |
|---|---|
| Runtimes | DirectX End-User Runtime; VC++ 2005 / 2008 / 2010 / 2012 / 2013 / **2015–2026** (x86 + x64); .NET Desktop Runtime **6, 8, 9, 10** |
| Launchers | Steam, Battle.net, EA App (Origin’s successor), Ubisoft Connect, Epic Games Launcher |
| Utilities | NVIDIA App, Chrome, FanControl **V277** (your exact GitHub URL) |

There is no official “VC++ 2009” redist. 2008 and 2010 are the adjacent Microsoft packages; 2015+ is one ABI that covers VS 2015 through 2026.

FanControl V277 is a .NET 10 build, so Desktop Runtime 10 is installed before it.

---

## Key architectural choices

1. **winget first, vendor URL fallback.** Windows 11 already ships winget. If a catalog ID is missing or winget returns a non-zero code, the script downloads the official installer and runs it silently.
2. **Idempotent.** `-SkipInstalled` (default) checks `winget list` and the Uninstall registry so re-runs only retry failures.
3. **Progress + report.** `Write-Progress` for the bar, colorized step log, then a summary with Succeeded / Skipped / Failed.
4. **Self-elevation.** If you forget “Run as admin”, it relaunches itself with `RunAs`.
5. **Self-contained.** No modules, no Chocolatey, no external scripts.

NVIDIA App is often **not** in winget (hardware-check policy). The script tries `Nvidia.App`, then falls back to NVIDIA’s published `NVIDIA_app_v11.0.9.251.exe`. That installer will fail on machines with no NVIDIA GPU — expected.

---

## Complexity

- Time: `O(N)` packages, dominated by download + installer runtime, not the script.
- Space: installer cache under `%TEMP%\Win11FreshInstall\downloads`.

---

## Edge cases

- Battle.net’s bootstrapper is only *mostly* silent (`--lang=enUS`). A short vendor window can still appear.
- EA “Origins” is the **EA App**. The script detects legacy Origin as already present so it does not double-install.
- `3010` / `1641` from MSI/EXE are treated as success (reboot required).
- TLS 1.2 is forced for older PowerShell 5.1 hosts.
- Re-run after a failure; already-installed items are skipped.

If you want the next revision to pin install paths (e.g. `D:\Games\Steam`) or add Discord / 7-Zip / GPU drivers, say so and I’ll extend the catalog.