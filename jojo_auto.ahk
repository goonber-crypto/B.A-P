; =======================================================================
;   B.A.P - Best Auto Prestiger  (AHK v2)
;   F6 = Start / Stop  |  Setup captures button images via R key
;
;   MODES:  Story       - CNF > Prestige > Story > Attack (with Heal)
;           World Boss  - CNF > Go to WB > Enter Fight > Attack
;           Inf Dungeon - Go to Dungeon > Scroll > Start > Atk exhaust > Flee
;
;   Reconnect is universal (shared across all modes).
;   After Reconnect: Recovery sequence navigates back to the correct screen.
; =======================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force

; Coordinates must match physical pixels — keep consistent with GrabScreen/ImageSearch
DllCall("SetThreadDpiAwarenessContext", "Ptr", -3, "Ptr")

CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")
SetMouseDelay(2)     ; minimal internal delay between mouse events

; =======================================================================
;             C L A S S   D E F I N I T I O N S
; =======================================================================

; ---- Logger ------------------------------------------------------------
; Buffered file logger.  Entries are batched and flushed every second or
; when 50 accumulate.  Use LogOnce() in hot paths to rate-limit output.
; Maintains a small ring-buffer of recent lines for the debug overlay.
class Logger {
    static Level_DEBUG := 0
    static Level_INFO  := 1
    static Level_WARN  := 2
    static Level_ERROR := 3
    static Level_FATAL := 4

    __New(filepath, defaultLevel := Logger.Level_INFO, maxBytes := 2097152) {
        this.filepath     := filepath
        this.defaultLevel := defaultLevel
        this.maxBytes     := maxBytes        ; 2 MB before rotation
        this.buffer       := []
        this.lastFlush    := A_TickCount
        this._rateMap     := Map()
        this._rotatePath  := filepath ".old"
        this.recent       := []              ; ring buffer for overlay
        this.recentMax    := 8
    }

    Log(level, category, message) {
        if level < this.defaultLevel
            return
        local labels := ["DEBUG","INFO ","WARN ","ERROR","FATAL"]
        local label  := (level >= 0 && level <= 4) ? labels[level + 1] : "?????"
        local ts     := FormatTime(, "HH:mm:ss")
        local entry  := ts " [" label "] " category ": " message
        this.buffer.Push(entry)
        this.recent.Push(entry)
        while this.recent.Length > this.recentMax
            this.recent.RemoveAt(1)
        if this.buffer.Length >= 50 || (A_TickCount - this.lastFlush) >= 1000
            this.Flush()
    }

    ; Rate-limited log: emit at most once per intervalMs for a given key
    LogOnce(level, category, message, key := "", intervalMs := 5000) {
        local k   := category ":" (key != "" ? key : message)
        local now := A_TickCount
        if this._rateMap.Has(k) && (now - this._rateMap[k]) < intervalMs
            return
        this._rateMap[k] := now
        this.Log(level, category, message)
    }

    Debug(cat, msg) {
        this.Log(Logger.Level_DEBUG, cat, msg)
    }
    Info(cat, msg) {
        this.Log(Logger.Level_INFO, cat, msg)
    }
    Warn(cat, msg) {
        this.Log(Logger.Level_WARN, cat, msg)
    }
    Error(cat, msg) {
        this.Log(Logger.Level_ERROR, cat, msg)
    }
    Fatal(cat, msg) {
        this.Log(Logger.Level_FATAL, cat, msg)
        this.Flush()
    }

    Flush() {
        if !this.buffer.Length {
            this.lastFlush := A_TickCount
            return
        }
        local lines := []
        for e in this.buffer
            lines.Push(e)
        this.buffer.Length := 0
        this.lastFlush := A_TickCount
        try {
            if FileExist(this.filepath) {
                try {
                    local sz := FileGetSize(this.filepath)
                    if sz >= this.maxBytes {
                        try FileDelete(this._rotatePath)
                        try FileMove(this.filepath, this._rotatePath)
                    }
                }
            }
            local fh := FileOpen(this.filepath, "a", "UTF-8")
            if fh {
                for ln in lines
                    fh.WriteLine(ln)
                fh.Close()
            }
        }
    }

    SetLevel(level) {
        this.defaultLevel := level
    }

    GetRecent(n := 4) {
        local out := [], start := Max(1, this.recent.Length - n + 1)
        local count := this.recent.Length - start + 1
        Loop count
            out.Push(this.recent[start + A_Index - 1])
        return out
    }
}

; ---- RuntimeValidator --------------------------------------------------
; Validates image assets, screenshot captures, and runtime state.
; Emits structured log entries rather than silently returning false.
class RuntimeValidator {
    __New(logger) {
        this._log := logger
    }

    ; Check all required image files exist on disk for the current mode
    ValidateAssets(imgDir, btnNames, hasCNF, reconPath) {
        local ok := true
        Loop btnNames.Length {
            local p := imgDir "\btn_" A_Index ".png"
            if !FileExist(p) {
                this._log.Warn("VALIDATE", "Missing asset: " p)
                ok := false
            }
        }
        if hasCNF {
            local cp := imgDir "\cnf.png"
            if !FileExist(cp) {
                this._log.Warn("VALIDATE", "Missing CNF asset: " cp)
                ok := false
            }
        }
        if reconPath != "" && !FileExist(reconPath) {
            this._log.Warn("VALIDATE", "Missing recon asset: " reconPath)
            ok := false
        }
        return ok
    }

    ; Confirm a screenshot was actually written to disk and is non-trivial size
    ValidateCapture(path) {
        if !FileExist(path) {
            this._log.Error("VALIDATE", "Capture not written to disk: " path)
            return false
        }
        try {
            if FileGetSize(path) < 64 {
                this._log.Error("VALIDATE", "Capture file appears corrupt (<64 bytes): " path)
                return false
            }
        }
        return true
    }
}

; ---- MacroState ----------------------------------------------------
; Single owner of all macro lifecycle and phase data.
; Exposes named reset methods so call sites document *why* they reset.
; All properties mirror the corresponding globals; globals are written
; back by each Reset* method so existing code continues to work.
class MacroState {
    __New() {
        this.running         := false
        this.phase           := 0
        this.phaseStartTime  := 0
        this.battleCount     := 0
        this.attackClicks    := 0
        this.runCount        := 0
        this.prestigeCount   := 0
        this.attackMissRun   := 0
        this.fleeMissRun     := 0
        this.nextAtk         := 1
        this.seqRevisit      := false
        this.lastAttackTime  := 0
        this.lastBattleEnd   := 0
        this.lastBtnSeen     := 0
        this.healCounter     := 0
        this.restCounter     := 0
        this.lastReconClick  := 0
        this.lastAnyDetect   := 0
        this.rejoinRetryDone := false
        this.rejoinRetryTime := 0
        this.needsRecovery   := false
        this.recoveryStep    := 0
        this.dungInitDone    := false
        this.dungInitStep    := 0
        this.dungInitStepTime := 0
        this.dungInitRetries := 0
        this.macroStartTime  := 0
        this.wbStep          := 0
        this.wbStepTime      := 0
        this.cnfClearCount   := 0
    }

    ; Full reset used by ResetToClean (reconnect/rejoin recovery)
    ResetClean() {
        global Phase, PhaseStartTime, BattleCount, AttackClicks, RunCount
        global PrestigeCount, AttackMissRun, FleeMissRun, NextAtk, SeqRevisit
        global LastAttackTime, LastBattleEnd, LastBtnSeen, HealCounter, RestCounter
        global LastReconnectClick, NeedsRecovery, RecoveryStep
        global DungeonInitDone, DungeonInitStep, DungeonInitStepTime, DungeonInitRetries
        global CnfClearCount, WBStep, WBStepTime
        this.phase           := PH_IDLE
        this.phaseStartTime  := A_TickCount
        this.battleCount     := 0
        this.attackClicks    := 0
        this.runCount        := 0
        this.prestigeCount   := 0
        this.attackMissRun   := 0
        this.fleeMissRun     := 0
        this.nextAtk         := 1
        this.seqRevisit      := false
        this.lastAttackTime  := 0
        this.lastBattleEnd   := 0
        this.lastBtnSeen     := A_TickCount
        this.healCounter     := 0
        this.restCounter     := 0
        this.lastReconClick  := 0
        this.needsRecovery   := false
        this.recoveryStep    := 0
        this.dungInitDone    := false
        this.dungInitStep    := 0
        this.dungInitStepTime := 0
        this.dungInitRetries := 0
        this.cnfClearCount   := 0
        this.wbStep          := 0
        this.wbStepTime      := 0
        this._WriteGlobals()
    }

    ; Partial reset on mode switch (counters only, not stats)
    ResetForMode() {
        global AttackMissRun, NextAtk, SeqRevisit, CnfClearCount
        global DungeonInitDone, DungeonInitStep, DungeonInitStepTime, DungeonInitRetries
        this.attackMissRun   := 0
        this.nextAtk         := 1
        this.seqRevisit      := false
        this.cnfClearCount   := 0
        this.dungInitDone    := false
        this.dungInitStep    := 0
        this.dungInitStepTime := 0
        this.dungInitRetries := 0
        AttackMissRun   := 0
        NextAtk         := 1
        SeqRevisit      := false
        CnfClearCount   := 0
        DungeonInitDone := false
        DungeonInitStep := 0
        DungeonInitStepTime := 0
        DungeonInitRetries  := 0
    }

    ; Reset on StartMacro (preserves AccumulatedTime and stats across stop/start)
    ResetForStart() {
        global Running, Phase, PhaseStartTime, BattleCount, AttackClicks, RunCount, PrestigeCount
        global AttackMissRun, FleeMissRun, NextAtk, SeqRevisit
        global LastAttackTime, LastBattleEnd, LastBtnSeen, HealCounter, RestCounter
        global LastReconnectClick, LastAnyDetection, RejoinRetryDone, RejoinRetryTime
        global NeedsRecovery, RecoveryStep
        global DungeonInitDone, DungeonInitStep, DungeonInitStepTime, DungeonInitRetries
        this.phase           := PH_IDLE
        this.phaseStartTime  := A_TickCount
        this.battleCount     := 0
        this.attackClicks    := 0
        this.runCount        := 0
        this.attackMissRun   := 0
        this.fleeMissRun     := 0
        this.nextAtk         := 1
        this.seqRevisit      := false
        this.lastAttackTime  := 0
        this.lastBattleEnd   := 0
        this.lastBtnSeen     := A_TickCount
        this.healCounter     := 0
        this.restCounter     := 0
        this.lastReconClick  := 0
        this.lastAnyDetect   := A_TickCount
        this.rejoinRetryDone := false
        this.rejoinRetryTime := 0
        this.needsRecovery   := false
        this.recoveryStep    := 0
        this.dungInitDone    := false
        this.dungInitStep    := 0
        this.dungInitStepTime := 0
        this.dungInitRetries := 0
        ; Preserve the headline Prestige stat across stop/start. The struct mirror is
        ; otherwise stale (live code increments the global directly), so without this
        ; sync _WriteGlobals would reset PrestigeCount to 0 on every Start.
        this.prestigeCount   := PrestigeCount
        this.running         := true
        this._WriteGlobals()
    }

    ; Sync all owned globals from the struct (call after any bulk update)
    _WriteGlobals() {
        global Running, Phase, PhaseStartTime, BattleCount, AttackClicks, RunCount
        global PrestigeCount, AttackMissRun, FleeMissRun, NextAtk, SeqRevisit
        global LastAttackTime, LastBattleEnd, LastBtnSeen, HealCounter, RestCounter
        global LastReconnectClick, LastAnyDetection, RejoinRetryDone, RejoinRetryTime
        global NeedsRecovery, RecoveryStep
        global DungeonInitDone, DungeonInitStep, DungeonInitStepTime, DungeonInitRetries
        global CnfClearCount, WBStep, WBStepTime
        Running           := this.running
        Phase             := this.phase
        PhaseStartTime    := this.phaseStartTime
        BattleCount       := this.battleCount
        AttackClicks      := this.attackClicks
        RunCount          := this.runCount
        PrestigeCount     := this.prestigeCount
        AttackMissRun     := this.attackMissRun
        FleeMissRun       := this.fleeMissRun
        NextAtk           := this.nextAtk
        SeqRevisit        := this.seqRevisit
        LastAttackTime    := this.lastAttackTime
        LastBattleEnd     := this.lastBattleEnd
        LastBtnSeen       := this.lastBtnSeen
        HealCounter       := this.healCounter
        RestCounter       := this.restCounter
        LastReconnectClick := this.lastReconClick
        LastAnyDetection  := this.lastAnyDetect
        RejoinRetryDone   := this.rejoinRetryDone
        RejoinRetryTime   := this.rejoinRetryTime
        NeedsRecovery     := this.needsRecovery
        RecoveryStep      := this.recoveryStep
        DungeonInitDone   := this.dungInitDone
        DungeonInitStep   := this.dungInitStep
        DungeonInitStepTime := this.dungInitStepTime
        DungeonInitRetries  := this.dungInitRetries
        CnfClearCount     := this.cnfClearCount
        WBStep            := this.wbStep
        WBStepTime        := this.wbStepTime
    }
}

; ---- DetectionState ------------------------------------------------
; Owns all mutable detection internals: CNF scan state, reconnect
; capture coordinates, button capture arrays, and search geometry.
; Capture coordinates are set once and never mutated by detection calls.
class DetectionState {
    __New() {
        ; CNF
        this.cnfImgOK    := 0
        this.cnfY        := 0
        this.cnfBaseX    := 0
        this.cnfLastX    := 0
        this.cnfBandH    := 30
        this.cnfScanHW   := 200
        this.cnfTol      := 100
        this.cnfCaptureSize := 20
        ; Reconnect
        this.reconX      := 0
        this.reconY      := 0
        this.reconOK     := 0
        ; Search geometry
        this.searchRadius    := 120
        this.imgTolerance    := 30
        this.captureSize     := 48
    }

    ; Clear only scan-position caches (called on mode switch, NOT on coord changes)
    ResetScanCache() {
        global CnfLastX
        this.cnfLastX := 0
        CnfLastX := 0
    }

    ; Push current values into globals so existing detection code keeps working
    SyncToGlobals() {
        global CnfImgOK, CnfY, CnfBaseX, CnfLastX, CnfBandH, CnfScanHalfW, CnfTolerance
        global CnfCaptureSize, ReconX, ReconY, ReconOK, SearchRadius
        global SavedImgTolerance, CaptureSize
        CnfImgOK      := this.cnfImgOK
        CnfY          := this.cnfY
        CnfBaseX      := this.cnfBaseX
        CnfLastX      := this.cnfLastX
        CnfBandH      := this.cnfBandH
        CnfScanHalfW  := this.cnfScanHW
        CnfTolerance  := this.cnfTol
        CnfCaptureSize := this.cnfCaptureSize
        ReconX        := this.reconX
        ReconY        := this.reconY
        ReconOK       := this.reconOK
        SearchRadius  := this.searchRadius
        SavedImgTolerance := this.imgTolerance
        CaptureSize   := this.captureSize
    }

    ; Pull latest values from globals (called after LoadConfig/LoadModeButtons)
    SyncFromGlobals() {
        global CnfImgOK, CnfY, CnfBaseX, CnfLastX, CnfBandH, CnfScanHalfW, CnfTolerance
        global CnfCaptureSize, ReconX, ReconY, ReconOK, SearchRadius
        global SavedImgTolerance, CaptureSize
        this.cnfImgOK  := CnfImgOK
        this.cnfY      := CnfY
        this.cnfBaseX  := CnfBaseX
        this.cnfLastX  := CnfLastX
        this.cnfBandH  := CnfBandH
        this.cnfScanHW := CnfScanHalfW
        this.cnfTol    := CnfTolerance
        this.cnfCaptureSize := CnfCaptureSize
        this.reconX    := ReconX
        this.reconY    := ReconY
        this.reconOK   := ReconOK
        this.searchRadius  := SearchRadius
        this.imgTolerance  := SavedImgTolerance
        this.captureSize   := CaptureSize
    }
}

; ---- RuntimeServices -----------------------------------------------
; Centralizes guard helpers and shared utilities so call sites import a
; single dependency.  Heavy operations (clicks, window queries) still
; live in their own functions; this class holds the shared guards that
; previously lived as scattered if-blocks.
class RuntimeServices {
    __New(logger, validator, macroState, detectState) {
        this._log      := logger
        this._val      := validator
        this._ms       := macroState
        this._ds       := detectState
    }

    ; Returns true if it is safe to run a tick (running + window found + not minimized)
    CanTick(robloxHwnd) {
        if !this._ms.running
            return false
        if !robloxHwnd
            return false
        if DllCall("IsIconic", "Ptr", robloxHwnd)
            return false
        return true
    }

    ; Returns true if a phase-change log should fire and updates LastPhase
    CheckPhaseChange(phase, lastPhase) {
        return phase != lastPhase
    }

    ; Validate all required assets for the given mode profile; log each gap
    ValidateMode(imgDir, btnNames, hasCNF) {
        if IsObject(this._val)
            return this._val.ValidateAssets(imgDir, btnNames, hasCNF, "")
        return true
    }

    ; Log a warning through the shared logger (no-op if logger absent)
    Warn(cat, msg) {
        if IsObject(this._log)
            this._log.Warn(cat, msg)
    }

    ; Log an info entry
    Info(cat, msg) {
        if IsObject(this._log)
            this._log.Info(cat, msg)
    }

    ; Flush the logger (call on exit/stop to avoid losing buffered entries)
    Flush() {
        if IsObject(this._log)
            this._log.Flush()
    }
}

; ----------------------- Phase Constants -----------------
global PH_IDLE      := 0   ; Scanning for entry button
global PH_BATTLE    := 1   ; In combat - spamming Attack
global PH_PRESTIGE  := 2   ; Clicked Prestige - cooldown (Story only)
global PH_CONFUSED  := 3   ; Confused - REST only until CNF clears
global PH_FLEEING   := 4   ; Spamming Flee until out (Inf Dungeon)
global PH_RECOVERY  := 5   ; Post-reconnect - navigating back to mode screen
global PH_WORLDBOSS := 6   ; Scheduled WB fight during Story mode

; ----------------------- Mode System ---------------------
global GameMode     := 1           ; 1=Story, 2=World Boss, 3=Inf Dungeon
global ModeNames    := ["Story", "World Boss", "Inf Dungeon"]
global ModeProfiles := Map()       ; populated by InitModeProfiles() at bootstrap

; Mode-specific indices (set by SwitchMode)
global AtkSlots     := []          ; attack button indices for round-robin / sequential
global RestIdx      := 0           ; rest button index (0 = none)
global PresIdx      := 0           ; prestige button index (0 = none)
global HealIdx      := 0           ; heal button index (0 = none)
global FleeIdx      := 0           ; flee button index (0 = none)
global NavIdx       := 0           ; navigation button index for recovery (0 = none)
global HasCNF       := true        ; whether this mode uses CNF detection
global SeqAttack    := false       ; true = exhaust atk1 then atk2 (Inf Dungeon)
global SeqRevisit   := false       ; true = currently re-checking an earlier slot (fast re-exhaust)
global NeedsScroll  := false       ; true = scroll down during recovery (Inf Dungeon)

; ----------------------- Healing -------------------------
global HealEnabled := 1            ; 1 = heal, 0 = disabled
global HealEvery   := 15           ; heal once every N attacks

; ----------------------- Rest (Inf Dungeon) --------------
global RestEnabled := 1            ; 1 = rest, 0 = disabled
global RestEvery   := 5            ; rest once every N attacks

; ----------------------- Universal Reconnect -------------
global ReconX       := 0
global ReconY       := 0
global ReconOK      := 0
global ReconImgPath := A_ScriptDir "\recon.png"

; ----------------------- Recovery State ------------------
global NeedsRecovery    := false
global RecoveryStep     := 0
global RecoveryStepTime := 0
global RecoveryWait     := 1500    ; ms between recovery steps
global ScrollTicks      := 5      ; mouse wheel ticks for dungeon scroll

; ----------------------- Dungeon Init State --------------
; First-time tab open + scroll for Inf Dungeon mode
global DungeonInitDone     := false
global DungeonInitStep     := 0
global DungeonInitStepTime := 0
global DungeonInitRetries  := 0      ; scroll-loop retry counter

; ----------------------- Runtime State -------------------
global Running         := false
global Phase           := 0
global PhaseStartTime  := 0
global PrestigeCount   := 0
global BattleCount     := 0
global AttackClicks    := 0
global RunCount        := 0
global HealCounter     := 0
global RestCounter     := 0
global AttackMissRun   := 0
global NextAtk         := 1
global LastAttackTime  := 0
global LastBattleEnd   := 0
global LastBtnSeen     := 0
global SetupActive     := false
global SetupIdx        := 0
global SetupPhase      := 0
global SetupSavedX     := 0
global SetupSavedY     := 0
global FleeMissRun     := 0        ; consecutive ticks Flee not found (Inf Dungeon)

; ----------------------- WB Schedule (Story mode) --------
global WBScheduleEnabled := 0      ; 1 = do a WB fight every hour at :00
global LastWBHour        := -1     ; hour (0-23) of the last scheduled WB run
global WBStep            := 0      ; step within the WB side-trip
global WBStepTime        := 0      ; tick of last step transition
; NOTE: PreWBPhase was declared here but was never actually consumed — WB
; step 3 always restores Phase := PH_IDLE directly.  Kept as a placeholder
; for a future "resume prior phase" feature; do not rely on its value.
global PreWBPhase        := 0

; ----------------------- CNF Detection State -------------
global CnfImgOK          := 0
global CnfY              := 0
global CnfBandH          := 30
global CnfLastX          := 0
global CnfBaseX          := 0      ; captured X - determines which half to scan
global CnfScanHalfW      := 200
global CnfTolerance      := 100
global CnfClearThreshold := 2
global CnfClearCount     := 0
global PreCnfPhase       := 0
global CnfCaptureSize    := 20

; ----------------------- Image Capture -------------------
global CaptureSize := 48

; ----------------------- Button Data ---------------------
; Set dynamically by SwitchMode() - varies per mode
global BtnNames := []
global BtnX     := []
global BtnY     := []
global BtnOK    := []

; ----------------------- Attack Toggles (all modes) ------
global AtkEnabled1 := 1
global AtkEnabled2 := 1
global AtkEnabled3 := 1
global AtkEnabled4 := 1

; ----------------------- Timing Defaults -----------------
global ClickCD          := 120
global ClickHold        := 60      ; ms to hold mouse button down per click
global ClickMethod      := 1       ; 1=Held, 2=Instant(SendInput), 3=Simple(Event)
global ClickVerifyWait  := 200     ; ms to wait after a click before re-scanning for state change
global LoopMS           := 100
global AttackGap        := 150
global PrestigeCooldown := 2500
global PrestigeReentryGuard := 4000   ; ms after a prestige completes before another prestige may be detected (anti re-fire)
global LastPrestigeDone     := 0      ; tick a prestige last completed (drives PrestigeReentryGuard)
global MissThreshold    := 8
global PostBattleDelay  := 2500
global FallbackDelay    := 5000
global ReconnectCooldown := 3000
global LastReconnectClick := 0
global SearchRadius     := 120
global SavedImgTolerance := 30     ; detection tolerance (used everywhere)

; ----------------------- Discord Webhook (optional) ------
global WebhookURL    := ""
global WebhookQueue  := []   ; item 16: async queue — SendWebhook pushes here

; ----------------------- Rejoin Failsafe -----------------
global LastAnyDetection    := 0        ; last tick any game UI was positively detected
global InactivityThreshold := 60000   ; ms of no detection before failsafe fires (default 60 s)
global RejoinRetryDone     := false   ; true after the single pre-rejoin retry attempt
global RejoinRetryTime     := 0       ; tick of that retry attempt
global LastRejoinTime      := 0       ; tick of the most recent rejoin launch
global RejoinGracePeriod   := 90000  ; ms after a rejoin before inactivity counting resumes
global PrivateServerURL    := ""      ; roblox.com private server URL (or roblox:// deep link)

; ----------------------- Updater -------------------------
global ScriptVersion := "1.12.1"
global UpdateURL     := "https://raw.githubusercontent.com/goonber-crypto/B.A-P/main/"

; ----------------------- Paths ---------------------------
global CfgFile := A_ScriptDir "\jojo_config.ini"
global ImgDir  := A_ScriptDir "\images_story"

; ----------------------- GUI Handles ---------------------
global mainGui     := ""
global setupGui    := ""
global settingsGui := ""
global GStatus     := ""
global GStats      := ""
global GDetail     := ""
global GModeDesc   := ""
global BtnRun      := ""
global GModeDD     := ""
global SStep       := ""
global SInstr      := ""
global SCoords     := ""
global SLines      := []

; Settings edits
global EClickCD    := ""
global EClickHold  := ""
global DDClickMethod := ""
global ELoopMS     := ""
global EEntryWait  := ""
global EAttackGap  := ""
global EPrestigeCD := ""
global EMissThresh := ""
global ESearchR    := ""
global EImgTol     := ""
global EPostBattle := ""
global EScrollT    := ""
global EDungHealEvery := ""
global CDungHeal   := ""
global ERestEvery  := ""
global CRestEnabled := ""
global CAtk1       := ""
global CAtk2       := ""
global CAtk3       := ""
global CAtk4       := ""
global CWBSchedule       := ""
global EWebhook          := ""
global EInactivityThresh := ""
global EPrivateSvrURL    := ""

; ----------------------- GDI+ Token ----------------------
global GdipToken := 0

; ----------------------- Service Instances ----------------
; Initialized in StartGdiplus() — available everywhere after bootstrap.
global gLog        := ""    ; Logger instance
global gValidator  := ""    ; RuntimeValidator instance
global gMacroState := ""    ; MacroState instance
global gDetectState := ""   ; DetectionState instance
global gServices   := ""    ; RuntimeServices instance

; ----------------------- Debug Overlay -------------------
global DebugEnabled := true    ; show debug log panel by default
global GDebugLines  := []      ; up to 4 text controls in overlay
global GDebugToggle := ""      ; toggle button control

; ----------------------- Phase-Change Tracking -----------
global LastPhase := -1         ; previous phase — used to log transitions

; ----------------------- Color Palette -------------------
global C_BG       := "0A0E14"    ; deep dark background
global C_PANEL    := "0F1923"    ; slightly lighter panel
global C_CARD     := "13212E"    ; card / section background
global C_BORDER   := "1A2B3C"    ; subtle borders
global C_ACCENT   := "00BFFF"    ; primary cyan accent
global C_ACCENT2  := "0099CC"    ; secondary accent (darker cyan)
global C_GREEN    := "00E676"    ; success / running green
global C_RED      := "FF3D5A"    ; stop / error red
global C_ORANGE   := "FFAB40"    ; warning orange
global C_TEXT     := "E0E8F0"    ; primary text
global C_TEXT2    := "7B8DA0"    ; secondary / muted text
global C_TEXT3    := "4A5B6D"    ; dim text
global C_PURPLE   := "BB86FC"    ; stats accent

; ---- JoJo Game Button Colors (from story mode) ---------
global C_GOLD     := "D4A017"    ; golden yellow  (Story button)
global C_VIOLET   := "7B2D8E"    ; deep purple    (Attack button)
global C_CRIMSON  := "8B1A2B"    ; crimson red    (Prestige button)
global C_VIVID_OR := "E8751A"    ; vivid orange   (Heal / Attack2/3)
global C_SLATE    := "3D4555"    ; dark slate     (Rest button)

; ----------------------- Additional GUI Handles ----------
global GCreditsGui   := ""
global GHelpGui      := ""
global GPhaseIcon    := ""
global GElapsed      := ""
global GReadyGrid    := []
global ElapsedTimer  := 0
global MacroStartTime := 0
global AccumulatedTime := 0        ; accumulated seconds across start/stop cycles
global SProgress     := ""        ; setup wizard progress bar

; ----------------------- Bootstrap -----------------------
StartGdiplus()
InitModeProfiles()
LoadConfig()
BuildGui()
ShowFirstRunInvite()
CheckForUpdate()

; ----------------------- Hotkey --------------------------
F6::ToggleMacro()


; =======================================================================
;              M O D E   P R O F I L E   S T O R E
; =======================================================================

class ModeProfile {
    ; Immutable per-mode configuration. Populated by InitModeProfiles().
    __New(o) {
        this.btnNames          := o.btnNames
        this.imgDir            := o.imgDir
        this.atkSlots          := o.atkSlots
        this.restIdx           := o.restIdx
        this.presIdx           := o.presIdx
        this.healIdx           := o.healIdx
        this.fleeIdx           := o.fleeIdx
        this.navIdx            := o.navIdx
        this.hasCNF            := o.hasCNF
        this.seqAttack         := o.seqAttack
        this.needsScroll       := o.needsScroll
        this.description       := o.description
        this.statsType         := o.statsType       ; 1=Prestige/PPH  2=Battles  3=Runs
        this.hints             := o.hints            ; Map(idx -> instruction text)
        ; item 14: profile-driven entry-wait (writable — synced from INI on load)
        this.entryWait         := o.entryWait        ; default entry wait in ms
        this.entryWaitLabel    := o.entryWaitLabel   ; settings label string
        ; item 17: legacy INI section fallbacks for backward compat ("" = no fallback)
        this.legacyBtnSection  := o.legacyBtnSection
        this.legacyCnfSection  := o.legacyCnfSection
        ; item 18: capability flags — drive mode-specific settings sections/fields
        this.hasPrestigeCooldown := o.hasPrestigeCooldown  ; show Prestige Cooldown in settings
        this.hasRestSettings     := o.hasRestSettings      ; show Rest Every + Enable Resting
        this.hasWBSchedule       := o.hasWBSchedule        ; show WB Schedule toggle
    }
}

InitModeProfiles() {
    global ModeProfiles
    ModeProfiles[1] := ModeProfile({
        btnNames:         ["Story", "Attack", "Prestige", "Heal", "Rest", "Attack2", "Attack3", "Go to Story", "Flee", "Attack4"],
        imgDir:           A_ScriptDir "\images_story",
        atkSlots:         [2, 6, 7, 10],
        restIdx:          5,
        presIdx:          3,
        healIdx:          4,
        fleeIdx:          9,
        navIdx:           8,
        hasCNF:           true,
        seqAttack:        false,
        needsScroll:      false,
        description:      "Story - CNF - Prestige",
        statsType:        1,
        entryWait:          600,
        entryWaitLabel:     "Story Wait",
        legacyBtnSection:   "Buttons",
        legacyCnfSection:   "CNF",
        hasPrestigeCooldown: true,
        hasRestSettings:     false,
        hasWBSchedule:       true,
        hints: Map(
            1,  "Hover the Story button (starts a story battle) -> press R",
            2,  "Hover Attack (your main attack move) -> press R",
            3,  "Hover Prestige (prestige/ascend button) -> press R",
            4,  "Hover Heal (healing button in battle) -> press R",
            5,  "Hover Rest (rest/recover button) -> press R",
            6,  "Hover Attack 2 (your 2nd attack move) -> press R",
            7,  "Hover Attack 3 (your 3rd attack move) -> press R",
            8,  "Hover Go to Story TAB (opens the story menu) -> press R",
            9,  "Hover Flee (escape button to leave battle) -> press R",
            10, "Hover Attack 4 (your 4th attack move) -> press R"
        )
    })
    ModeProfiles[2] := ModeProfile({
        btnNames:         ["Enter Fight", "Attack", "Rest", "Attack2", "Attack3", "Heal", "Go to WB", "Attack4"],
        imgDir:           A_ScriptDir "\images_raid",
        atkSlots:         [8, 4, 5, 2],
        restIdx:          3,
        presIdx:          0,
        healIdx:          6,
        fleeIdx:          0,
        navIdx:           7,
        hasCNF:           true,
        seqAttack:        false,
        needsScroll:      false,
        description:      "World Boss - CNF - Heal",
        statsType:        2,
        entryWait:          600,
        entryWaitLabel:     "Fight Wait",
        legacyBtnSection:   "Raid_Buttons",
        legacyCnfSection:   "Raid_CNF",
        hasPrestigeCooldown: false,
        hasRestSettings:     false,
        hasWBSchedule:       false,
        hints: Map(
            1, "Hover Enter Fight (starts a world boss fight) -> press R",
            2, "Hover Attack (your main attack move) -> press R",
            3, "Hover Rest (rest/recover button) -> press R",
            4, "Hover Attack 2 (your 2nd attack move) -> press R",
            5, "Hover Attack 3 (your 3rd attack move) -> press R",
            6, "Hover Heal (healing button in battle) -> press R",
            7, "Hover Go to WB TAB (opens the world boss menu) -> press R",
            8, "Hover Attack 4 (your 4th attack move) -> press R"
        )
    })
    ModeProfiles[3] := ModeProfile({
        btnNames:         ["Start Dungeon", "Attack", "Heal", "Flee", "Go to Dungeon", "Rest"],
        imgDir:           A_ScriptDir "\images_dungeon",
        atkSlots:         [2],
        restIdx:          6,
        presIdx:          0,
        healIdx:          3,
        fleeIdx:          4,
        navIdx:           5,
        hasCNF:           false,
        seqAttack:        true,
        needsScroll:      true,
        description:      "Dungeon - Flee - Scroll",
        statsType:        3,
        entryWait:          600,
        entryWaitLabel:     "Dungeon Wait",
        legacyBtnSection:   "",
        legacyCnfSection:   "",
        hasPrestigeCooldown: false,
        hasRestSettings:     true,
        hasWBSchedule:       false,
        hints: Map(
            1, "Hover the START button (inside dungeon menu, after scrolling) -> press R",
            2, "Hover Attack (your attack move in battle) -> press R",
            3, "Hover Heal (healing button in battle) -> press R",
            4, "Hover Flee (escape button to leave dungeon) -> press R",
            5, "Hover Inf Dungeons TAB (the tab that opens dungeon menu) -> press R",
            6, "Hover Rest (rest/recover button in battle) -> press R"
        )
    })
}

; =======================================================================
;                    M O D E   S Y S T E M
; =======================================================================

SwitchMode(mode) {
    global
    local prof
    GameMode := mode
    prof     := ModeProfiles[mode]

    BtnNames    := prof.btnNames
    AtkSlots    := prof.atkSlots
    RestIdx     := prof.restIdx
    PresIdx     := prof.presIdx
    HealIdx     := prof.healIdx
    FleeIdx     := prof.fleeIdx
    NavIdx      := prof.navIdx
    HasCNF      := prof.hasCNF
    SeqAttack   := prof.seqAttack
    NeedsScroll := prof.needsScroll
    ImgDir      := prof.imgDir

    if mode = 3
        AtkEnabled1 := 1    ; single slot — always enabled

    ; Initialize button data arrays
    BtnX  := []
    BtnY  := []
    BtnOK := []
    Loop BtnNames.Length {
        BtnX.Push(0)
        BtnY.Push(0)
        BtnOK.Push(0)
    }

    ; Reset CNF
    CnfImgOK := 0
    CnfY     := 0
    CnfLastX := 0

    ; Reset runtime counters (prevent cross-mode contamination)
    ; item 23: gMacroState is always initialized before SwitchMode is called
    ; (StartGdiplus runs at script start before LoadConfig/SwitchMode)
    if IsObject(gMacroState)
        gMacroState.ResetForMode()

    ; Load saved button data for this mode
    LoadModeButtons()
}

; item 22: array lookup replaces 4-case switch
IsAtkEnabled(slotNum) {
    global AtkEnabled1, AtkEnabled2, AtkEnabled3, AtkEnabled4
    local _atk := [AtkEnabled1, AtkEnabled2, AtkEnabled3, AtkEnabled4]
    return (slotNum >= 1 && slotNum <= _atk.Length) ? _atk[slotNum] : true
}

OnModeChange(*) {
    global
    if Running {
        GModeDD.Value := GameMode
        MsgBox("Stop the macro first.", "Busy", "Icon!")
        return
    }
    if SetupActive {
        GModeDD.Value := GameMode
        MsgBox("Finish or cancel Setup first.", "Busy", "Icon!")
        return
    }
    ; Close Settings GUI to prevent stale control access
    try settingsGui.Destroy()
    SaveModeButtons()
    SwitchMode(GModeDD.Value)
    SaveConfig()
    RefreshReadyGrid()
    ; Reset timer on mode change
    AccumulatedTime := 0
    MacroStartTime  := 0
    GElapsed.Value  := "00:00:00"
    GModeDesc.Value := ModeDescription()
    GStats.Value    := ModeStatsText()
    GDetail.Value   := "Switched to " ModeNames[GameMode] " mode"
}

; item 14: profile-driven entry-wait — no if/else GameMode
GetEntryWait() {
    global GameMode, ModeProfiles
    return ModeProfiles[GameMode].entryWait
}

; item 14: profile-driven label — no if/else GameMode
GetEntryWaitLabel() {
    global GameMode, ModeProfiles
    return ModeProfiles[GameMode].entryWaitLabel
}

; Total setup steps for current mode
GetTotalSetupSteps() {
    global BtnNames, HasCNF
    return BtnNames.Length + (HasCNF ? 1 : 0) + 1   ; +1 for universal Reconnect
}

; What step index is the CNF step? (0 if no CNF)
GetCnfStepIdx() {
    global BtnNames, HasCNF
    return HasCNF ? BtnNames.Length + 1 : 0
}

; The Reconnect step is always the last step
GetReconStepIdx() {
    return GetTotalSetupSteps()
}

; Return human-readable name of a setup step
GetStepName(idx) {
    global BtnNames, HasCNF
    local btnCount
    btnCount := BtnNames.Length
    if idx <= btnCount
        return BtnNames[idx]
    if HasCNF && idx = btnCount + 1
        return "CNF Icon"
    return "Reconnect"
}

; Return descriptive instruction text for a setup step
GetStepInstr(idx) {
    global BtnNames, HasCNF, GameMode, ModeProfiles
    local btnCount, reconStep, prof
    btnCount  := BtnNames.Length
    reconStep := GetReconStepIdx()

    if idx = reconStep
        return "Hover the Reconnect button (appears when disconnected) -> press R"
    if HasCNF && idx = btnCount + 1
        return "Hover the CNF status icon (confusion debuff) -> press R"

    prof := ModeProfiles[GameMode]
    if prof.hints.Has(idx)
        return prof.hints[idx]
    return "Hover " BtnNames[idx] " button -> press R"
}

; Return a named descriptor object for a setup step (item 10: explicit step descriptors).
; Replaces raw SLines[idx] integer coupling — callers reference .ctrl and .name instead.
GetSetupStepDescriptor(idx) {
    global BtnNames, HasCNF, SLines, CnfY, ReconX, ReconY, BtnX, BtnY, BtnOK
    global ImgDir, ReconImgPath, CnfImgOK, ReconOK
    local btnCount, reconStep, cnfStep
    btnCount  := BtnNames.Length
    reconStep := GetReconStepIdx()
    cnfStep   := GetCnfStepIdx()

    local d := {idx: idx, name: "", ctrl: "", isBtn: false, isCNF: false, isRecon: false}
    if idx <= SLines.Length
        d.ctrl := SLines[idx]
    if idx <= btnCount {
        d.name  := BtnNames[idx]
        d.isBtn := true
    } else if HasCNF && idx = cnfStep {
        d.name  := "CNF Icon"
        d.isCNF := true
    } else if idx = reconStep {
        d.name    := "Reconnect"
        d.isRecon := true
    }
    return d
}

; Update the status line in the setup wizard for a step (item 10: named update, not raw SLines[x]).
; icon = "[+]", "[-]", "[~]"  detail = coordinate or status string.
UpdateSetupLine(idx, icon, detail) {
    global SLines
    if idx < 1 || idx > SLines.Length
        return
    local d := GetSetupStepDescriptor(idx)
    SLines[idx].Value := icon "  " d.name "   " detail
}


; =======================================================================
;                         G U I
; =======================================================================

BuildGui() {
    global
    local w, h, cardX, cardW, panelY, statsY, startBtnY, readyY, actY, bW
    local bSetup, bSettings, bCredits, bQuit, bHelp

    W := 600
    H := 760

    mainGui := Gui("+AlwaysOnTop -MaximizeBox", "B.A.P - Best Auto Prestiger  v" ScriptVersion)
    mainGui.BackColor := C_BG
    mainGui.MarginX := 0
    mainGui.MarginY := 0
    mainGui.OnEvent("Close", (*) => Quit())

    ; ==================================
    ;  TOP ACCENT BAR (gradient feel)
    ; ==================================
    mainGui.AddText("x0 y0 w" W " h2 Background" C_GOLD, "")
    mainGui.AddText("x0 y2 w" W " h1 Background" C_VIVID_OR, "")

    ; ==================================
    ;  HEADER
    ; ==================================
    mainGui.SetFont("s28 c" C_GOLD " Bold", "Segoe UI")
    mainGui.AddText("x0 y8 w" W " h44 Center +0x200", "B . A . P")

    mainGui.SetFont("s9 c" C_TEXT2 " Norm", "Segoe UI")
    mainGui.AddText("x0 y52 w" W " Center", "Best Auto Prestiger")

    ; -- Divider --
    mainGui.AddText("x30 y76 w" (W - 60) " h1 Background" C_BORDER, "")

    ; ==================================
    ;  MODE SELECTOR CARD
    ; ==================================
    cardX := 30
    cardW := W - 60

    mainGui.AddText("x" cardX " y86 w" cardW " h52 Background" C_CARD, "")
    mainGui.AddText("x" cardX " y86 w" cardW " h1 Background" C_BORDER, "")
    mainGui.AddText("x" cardX " y137 w" cardW " h1 Background" C_BORDER, "")

    mainGui.SetFont("s10 c" C_TEXT2 " Bold", "Segoe UI")
    mainGui.AddText("x" (cardX + 16) " y96 w80 h32 +0x200 BackgroundTrans", "MODE")

    mainGui.SetFont("s10 c" C_TEXT " Norm", "Segoe UI")
    GModeDD := mainGui.AddDropDownList("x" (cardX + 100) " y98 w200 Choose" GameMode, ModeNames)
    GModeDD.OnEvent("Change", (*) => OnModeChange())

    mainGui.SetFont("s8 c" C_TEXT3 " Norm", "Segoe UI")
    GModeDesc := mainGui.AddText("x" (cardX + 316) " y96 w200 h32 +0x200 BackgroundTrans", ModeDescription())

    ; ==================================
    ;  STATUS PANEL
    ; ==================================
    panelY := 150

    mainGui.AddText("x" cardX " y" panelY " w" cardW " h110 Background" C_PANEL, "")
    mainGui.AddText("x" cardX " y" panelY " w" cardW " h1 Background" C_BORDER, "")
    mainGui.AddText("x" cardX " y" (panelY + 110) " w" cardW " h1 Background" C_BORDER, "")

    ; Section label
    mainGui.SetFont("s8 c" C_GOLD " Bold", "Segoe UI")
    mainGui.AddText("x" (cardX + 16) " y" (panelY + 8) " w60 BackgroundTrans", "STATUS")

    ; Elapsed timer (top right of panel)
    mainGui.SetFont("s8 c" C_TEXT3 " Norm", "Consolas")
    GElapsed := mainGui.AddText("x" (cardX + cardW - 120) " y" (panelY + 8) " w104 Right BackgroundTrans", "00:00:00")

    ; Phase icon + status text
    mainGui.SetFont("s9 c" C_TEXT3 " Norm", "Segoe UI")
    GPhaseIcon := mainGui.AddText("x" (cardX + 16) " y" (panelY + 32) " w24 h24 Center BackgroundTrans", "o")

    mainGui.SetFont("s16 c" C_TEXT " Bold", "Consolas")
    GStatus := mainGui.AddText("x" (cardX + 44) " y" (panelY + 30) " w" (cardW - 76) " BackgroundTrans", "IDLE")

    ; Detail line
    mainGui.SetFont("s9 c" C_TEXT2 " Norm", "Segoe UI")
    GDetail := mainGui.AddText("x" (cardX + 44) " y" (panelY + 62) " w" (cardW - 76) " h36 BackgroundTrans", "Run Setup to capture buttons, then press F6")

    ; ==================================
    ;  STATS PANEL
    ; ==================================
    statsY := 274

    mainGui.AddText("x" cardX " y" statsY " w" cardW " h68 Background" C_CARD, "")
    mainGui.AddText("x" cardX " y" statsY " w" cardW " h1 Background" C_BORDER, "")
    mainGui.AddText("x" cardX " y" (statsY + 68) " w" cardW " h1 Background" C_BORDER, "")

    mainGui.SetFont("s8 c" C_PURPLE " Bold", "Segoe UI")
    mainGui.AddText("x" (cardX + 16) " y" (statsY + 8) " w60 BackgroundTrans", "STATS")

    mainGui.SetFont("s22 c" C_TEXT " Bold", "Segoe UI")
    GStats := mainGui.AddText("x" (cardX + 16) " y" (statsY + 28) " w" (cardW - 32) " Center BackgroundTrans", ModeStatsText())

    ; ==================================
    ;  START / STOP BUTTON
    ; ==================================
    startBtnY := 356

    BtnRun := ColorBtn(mainGui, cardX, startBtnY, cardW, 56, ">   S T A R T", C_VIOLET, (*) => ToggleMacro(), 16)

    ; ==================================
    ;  ACTION BUTTONS ROW
    ; ==================================
    actY := 424
    bW := (cardW - 18) // 4  ; 4 buttons, 3 gaps of 6px

    bSetup := ColorBtn(mainGui, cardX, actY, bW, 40, "Setup", C_VIOLET, (*) => OpenSetup())

    bSettings := ColorBtn(mainGui, cardX + bW + 6, actY, bW, 40, "Settings", C_SLATE, (*) => OpenSettings())

    bCredits := ColorBtn(mainGui, cardX + (bW + 6) * 2, actY, bW, 40, "Credits", C_ACCENT, (*) => OpenCredits())

    bQuit := ColorBtn(mainGui, cardX + (bW + 6) * 3, actY, bW, 40, "Exit", C_CRIMSON, (*) => Quit())

    ; Small help button (top-right corner)
    bHelp := ColorBtn(mainGui, W - 44, 10, 32, 32, "?", C_VIOLET, (*) => OpenHelp(), 12)

    ; ==================================
    ;  READINESS GRID
    ; ==================================
    readyY := 478

    mainGui.AddText("x30 y" readyY " w" (W - 60) " h1 Background" C_BORDER, "")
    readyY += 8

    mainGui.SetFont("s8 c" C_TEXT3 " Bold", "Segoe UI")
    mainGui.AddText("x" cardX " y" readyY " w200", "BUTTON READINESS")
    readyY += 22

    ; Build a grid of readiness indicators
    GReadyGrid := []
    BuildReadyGrid(readyY)

    ; ==================================
    ;  DEBUG LOG OVERLAY
    ; ==================================
    mainGui.AddText("x30 y634 w" (W - 60) " h1 Background" C_BORDER, "")

    mainGui.SetFont("s7 c" C_PURPLE " Bold", "Segoe UI")
    mainGui.AddText("x" (cardX + 16) " y642 w100 BackgroundTrans", "DEBUG LOG")

    mainGui.SetFont("s7 c" C_TEXT3 " Norm", "Consolas")
    GDebugLines := []
    Loop 4 {
        local dy := 660 + (A_Index - 1) * 14
        GDebugLines.Push(mainGui.AddText("x" (cardX + 16) " y" dy " w" (cardW - 32) " BackgroundTrans", ""))
    }

    ; ==================================
    ;  FOOTER
    ; ==================================
    mainGui.SetFont("s7 c" C_TEXT3 " Norm", "Segoe UI")
    mainGui.AddText("x0 y" (H - 24) " w" W " Center", "B.A.P  v" ScriptVersion "  -  by TrueMust")

    mainGui.AddText("x0 y" (H - 4) " w" W " h2 Background" C_VIVID_OR, "")
    mainGui.AddText("x0 y" (H - 2) " w" W " h2 Background" C_GOLD, "")

    ApplyDarkMode(mainGui)
    mainGui.Show("w" W " h" H)
}

; -- Build readiness grid (always 9 max slots for mode switching) --
BuildReadyGrid(startY) {
    global
    local max_grid, cardX, colW, rowH, cols, x0, col, row, bx, by, ctrl
    MAX_GRID := 13  ; max across all modes: 10 btns (Story) + CNF + Recon + spare
    cardX := 30
    colW  := 170
    rowH  := 24
    cols  := 3
    x0    := cardX + 8

    GReadyGrid := []
    mainGui.SetFont("s8 c" C_TEXT3 " Norm", "Consolas")

    Loop MAX_GRID {
        col := Mod(A_Index - 1, cols)
        row := (A_Index - 1) // cols
        bx := x0 + col * colW
        by := startY + row * rowH
        ctrl := mainGui.AddText("x" bx " y" by " w" colW, "")
        GReadyGrid.Push(ctrl)
    }

    RefreshReadyGrid()
}

; -- Mode one-liner description --
ModeDescription() {
    global GameMode, ModeProfiles
    return ModeProfiles[GameMode].description
}

ModeStatsText() {
    global GameMode, ModeProfiles, PrestigeCount, BattleCount, RunCount
    global AccumulatedTime, MacroStartTime, Running
    local prof, elapsed, pph
    prof := ModeProfiles[GameMode]
    switch prof.statsType {
        case 1:
            elapsed := AccumulatedTime
            if Running && MacroStartTime > 0
                elapsed += (A_TickCount - MacroStartTime) // 1000
            pph := elapsed >= 60 ? Round(PrestigeCount / (elapsed / 3600), 1) : 0
            return "*  " PrestigeCount "  Prestiges   (" pph "/hr)"
        case 2:
            return "+  " BattleCount "  Battles"
        case 3:
            return "#  " RunCount "  Runs"
    }
    return ""
}

; -- Phase icon helper --
GetPhaseIcon() {
    global Phase, Running
    if !Running
        return "o"
    switch Phase {
        case 0: return ">"    ; idle / scanning
        case 1: return "!"    ; battle
        case 2: return "*"    ; prestige
        case 3: return "?"    ; confused
        case 4: return "<"    ; fleeing
        case 5: return "~"    ; recovery
        case 6: return "#"    ; scheduled world boss
    }
    return "."
}

; -- Elapsed timer tick --
ElapsedTick(*) {
    global
    local elapsed, h, m, s
    if !Running
        return
    elapsed := AccumulatedTime + ((A_TickCount - MacroStartTime) // 1000)
    h := elapsed // 3600
    m := Mod(elapsed, 3600) // 60
    s := Mod(elapsed, 60)
    GElapsed.Value := Format("{:02d}:{:02d}:{:02d}", h, m, s)
}


; =======================================================================
;                     C R E D I T S
; =======================================================================

OpenCredits(*) {
    global
    local W, yy, bClose

    try GCreditsGui.Destroy()

    W := 380
    GCreditsGui := Gui("+AlwaysOnTop +ToolWindow", "B.A.P - Credits")
    GCreditsGui.BackColor := C_BG
    GCreditsGui.MarginX := 0
    GCreditsGui.MarginY := 0
    GCreditsGui.OnEvent("Close", (*) => CloseCredits())

    ; Accent bar
    GCreditsGui.AddText("x0 y0 w" W " h2 Background" C_GOLD, "")

    ; Title
    GCreditsGui.SetFont("s22 c" C_GOLD " Bold", "Segoe UI")
    GCreditsGui.AddText("x0 y6 w" W " h40 Center +0x200", "B . A . P")

    GCreditsGui.SetFont("s9 c" C_TEXT2 " Norm", "Segoe UI")
    GCreditsGui.AddText("x0 y44 w" W " Center", "Best Auto Prestiger  v" ScriptVersion)

    ; Divider
    GCreditsGui.AddText("x30 y70 w" (W - 60) " h1 Background" C_BORDER, "")

    ; Developer section
    yy := 84

    GCreditsGui.SetFont("s8 c" C_GOLD " Bold", "Segoe UI")
    GCreditsGui.AddText("x30 y" yy " w200", "DEVELOPER")
    yy += 24

    GCreditsGui.SetFont("s12 c" C_TEXT " Bold", "Segoe UI")
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " Center", "TrueMust")
    yy += 30

    ; Divider
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " h1 Background" C_BORDER, "")
    yy += 16

    ; Discord section
    GCreditsGui.SetFont("s8 c7289DA Bold", "Segoe UI")
    GCreditsGui.AddText("x30 y" yy " w200", "DISCORD")
    yy += 24

    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " h40 Background" C_CARD, "")
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " h1 Background" C_BORDER, "")
    GCreditsGui.AddText("x30 y" (yy + 40) " w" (W - 60) " h1 Background" C_BORDER, "")

    GCreditsGui.SetFont("s14 cFFFFFF Bold", "Consolas")
    GCreditsGui.AddText("x30 y" (yy + 8) " w" (W - 60) " h24 Center BackgroundTrans", "pipster_pastor")
    yy += 56

    ; Divider
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " h1 Background" C_BORDER, "")
    yy += 16

    ; Donation section
    GCreditsGui.SetFont("s8 c" C_GREEN " Bold", "Segoe UI")
    GCreditsGui.AddText("x30 y" yy " w200", "DONATE")
    yy += 24

    GCreditsGui.SetFont("s9 c" C_TEXT2 " Norm", "Segoe UI")
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " Center", "Support development - every bit helps!")
    yy += 28

    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " h46 Background" C_CARD, "")
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " h1 Background" C_BORDER, "")
    GCreditsGui.AddText("x30 y" (yy + 46) " w" (W - 60) " h1 Background" C_BORDER, "")

    GCreditsGui.SetFont("s18 c" C_GREEN " Bold", "Consolas")
    GCreditsGui.AddText("x30 y" (yy + 10) " w" (W - 60) " h28 Center BackgroundTrans", "$TrueMust")
    yy += 62

    ; Divider
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " h1 Background" C_BORDER, "")
    yy += 16

    ; Thank you
    GCreditsGui.SetFont("s9 c" C_TEXT3 " Italic", "Segoe UI")
    GCreditsGui.AddText("x30 y" yy " w" (W - 60) " Center", "Thank you for using B.A.P!")
    yy += 30

    ; Close button
    bClose := ColorBtn(GCreditsGui, 30, yy, W - 60, 36, "Close", C_SLATE, (*) => CloseCredits())
    yy += 48

    ; Bottom accent
    GCreditsGui.AddText("x0 y" (yy - 2) " w" W " h2 Background" C_GOLD, "")

    ApplyDarkMode(GCreditsGui)
    GCreditsGui.Show("w" W " h" yy)
}

CloseCredits(*) {
    global
    try GCreditsGui.Destroy()
}


; =======================================================================
;                         H E L P
; =======================================================================

OpenHelp(*) {
    global
    local W, lx, tw, yy, bClose

    try GHelpGui.Destroy()

    W := 340
    GHelpGui := Gui("+AlwaysOnTop +ToolWindow", "B.A.P - Help")
    GHelpGui.BackColor := C_BG
    GHelpGui.MarginX := 0
    GHelpGui.MarginY := 0
    GHelpGui.OnEvent("Close", (*) => CloseHelp())

    ; Accent bar
    GHelpGui.AddText("x0 y0 w" W " h2 Background" C_GOLD, "")

    ; Title
    GHelpGui.SetFont("s14 c" C_GOLD " Bold", "Segoe UI")
    GHelpGui.AddText("x0 y14 w" W " Center", "How to Use")

    ; Divider
    GHelpGui.AddText("x24 y42 w" (W - 48) " h1 Background" C_BORDER, "")

    yy := 54
    lx := 28
    tW := W - 56

    GHelpGui.SetFont("s8 c" C_GOLD " Bold", "Segoe UI")
    GHelpGui.AddText("x" lx " y" yy " w" tW, "QUICK START")
    yy += 22

    GHelpGui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")
    GHelpGui.AddText("x" lx " y" yy " w" tW, "1.  Pick your mode (Story / World Boss / Dungeon)")
    yy += 22
    GHelpGui.AddText("x" lx " y" yy " w" tW, "2.  Click Setup to capture button positions")
    yy += 22
    GHelpGui.AddText("x" lx " y" yy " w" tW, "3.  Press F6 to start / stop the macro")
    yy += 30

    ; Divider
    GHelpGui.AddText("x24 y" yy " w" (W - 48) " h1 Background" C_BORDER, "")
    yy += 14

    GHelpGui.SetFont("s8 c" C_GOLD " Bold", "Segoe UI")
    GHelpGui.AddText("x" lx " y" yy " w" tW, "SETUP")
    yy += 22

    GHelpGui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")
    GHelpGui.AddText("x" lx " y" yy " w" tW, "- Hover over a button and press R to save its position")
    yy += 22
    GHelpGui.AddText("x" lx " y" yy " w" tW, "- Press R again to capture its image")
    yy += 22
    GHelpGui.AddText("x" lx " y" yy " w" tW, "- Green [+] = ready, Orange [~] = partial, [-] = missing")
    yy += 30

    ; Divider
    GHelpGui.AddText("x24 y" yy " w" (W - 48) " h1 Background" C_BORDER, "")
    yy += 14

    GHelpGui.SetFont("s8 c" C_GOLD " Bold", "Segoe UI")
    GHelpGui.AddText("x" lx " y" yy " w" tW, "HOTKEY")
    yy += 22

    GHelpGui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")
    GHelpGui.AddText("x" lx " y" yy " w" tW, "F6  -  Toggle macro on / off")
    yy += 30

    ; Close button
    bClose := ColorBtn(GHelpGui, 24, yy, W - 48, 34, "Close", C_SLATE, (*) => CloseHelp())
    yy += 44

    ; Bottom accent
    GHelpGui.AddText("x0 y" (yy - 2) " w" W " h2 Background" C_GOLD, "")

    ApplyDarkMode(GHelpGui)
    GHelpGui.Show("w" W " h" yy)
}

CloseHelp(*) {
    global
    try GHelpGui.Destroy()
}


; =======================================================================
;                  S E T T I N G S   W I N D O W
; =======================================================================

; --- Section builder: Timing (item 12) ---
BuildTimingsSection(gui, lx, ex, eW, &yy) {
    global ClickCD, ClickHold, ClickMethod, LoopMS, AttackGap, PrestigeCooldown
    global PostBattleDelay, GameMode
    global EClickCD, EClickHold, DDClickMethod, ELoopMS, EEntryWait, EAttackGap, EPrestigeCD, EPostBattle

    gui.SetFont("s8 c" C_GOLD " Bold", "Segoe UI")
    gui.AddText("x" lx " y" yy " w200", "TIMING")
    yy += 22

    gui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Click Cooldown")
    EClickCD := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", ClickCD)
    yy += 30

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Click Hold (ms)")
    EClickHold := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", ClickHold)
    yy += 30

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Click Method")
    DDClickMethod := gui.AddDropDownList("x" ex " y" yy " w" eW " Choose" ClickMethod, ["Held", "Instant", "Simple"])
    yy += 30

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Loop Interval")
    ELoopMS := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", LoopMS)
    yy += 30

    ; item 11: use GetEntryWaitLabel() — no local if/else chain
    gui.AddText("x" lx " y" yy " w250 h24 +0x200", GetEntryWaitLabel())
    EEntryWait := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", GetEntryWait())
    yy += 30

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Attack Gap")
    EAttackGap := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", AttackGap)
    yy += 30

    if ModeProfiles[GameMode].hasPrestigeCooldown {
        gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Prestige Cooldown")
        EPrestigeCD := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", PrestigeCooldown)
        yy += 30
    }

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Post-Battle Delay")
    EPostBattle := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", PostBattleDelay)
    yy += 30
}

; --- Section builder: Detection (item 12) ---
BuildDetectionSection(gui, lx, ex, eW, &yy) {
    global MissThreshold, SearchRadius, SavedImgTolerance
    global EMissThresh, ESearchR, EImgTol

    gui.SetFont("s8 c" C_PURPLE " Bold", "Segoe UI")
    gui.AddText("x" lx " y" yy " w200", "DETECTION")
    yy += 22

    gui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Miss Threshold")
    EMissThresh := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", MissThreshold)
    yy += 30

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Search Radius (px)")
    ESearchR := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", SearchRadius)
    yy += 30

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Image Tolerance (5-100)")
    EImgTol := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", SavedImgTolerance)
    yy += 30
}

; --- Section builder: Mode options (item 12) ---
BuildModeSection(gui, lx, ex, eW, &yy) {
    global GameMode, HealEvery, HealEnabled, RestEvery, RestEnabled, ScrollTicks
    global AtkSlots, BtnNames, AtkEnabled1, AtkEnabled2, AtkEnabled3, AtkEnabled4
    global WBScheduleEnabled
    global EDungHealEvery, CDungHeal, ERestEvery, CRestEnabled, EScrollT
    global CAtk1, CAtk2, CAtk3, CAtk4, CWBSchedule

    gui.SetFont("s8 c" C_GREEN " Bold", "Segoe UI")
    gui.AddText("x" lx " y" yy " w200", "MODE OPTIONS")
    yy += 22

    gui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")

    ; Heal settings — all combat modes
    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Heal Every N Attacks")
    EDungHealEvery := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", HealEvery)
    yy += 30

    CDungHeal := gui.AddCheckbox("x" lx " y" yy " w280 Checked" HealEnabled, "Enable Healing")
    yy += 30

    ; Rest + Scroll settings — profile flag
    if ModeProfiles[GameMode].hasRestSettings {
        gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Rest Every N Attacks")
        ERestEvery := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", RestEvery)
        yy += 30

        CRestEnabled := gui.AddCheckbox("x" lx " y" yy " w280 Checked" RestEnabled, "Enable Resting")
        yy += 30

        ; Scroll Ticks — Inf Dungeon only
        gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Scroll Ticks (dungeon)")
        EScrollT := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", ScrollTicks)
        yy += 30
    }

    ; Attack toggles — label by slot name
    local atkLabels := [], atkCount := AtkSlots.Length
    for i, slot in AtkSlots
        atkLabels.Push(BtnNames[slot])
    CAtk1 := gui.AddCheckbox("x" lx " y" yy " w120 Checked" AtkEnabled1, atkCount >= 1 ? atkLabels[1] : "Attack 1")
    CAtk2 := gui.AddCheckbox("x" (lx + 130) " y" yy " w120 Checked" AtkEnabled2, atkCount >= 2 ? atkLabels[2] : "Attack 2")
    CAtk3 := gui.AddCheckbox("x" (lx + 260) " y" yy " w120 Checked" AtkEnabled3, atkCount >= 3 ? atkLabels[3] : "Attack 3")
    if atkCount < 3
        CAtk3.Visible := false
    if atkCount < 2 {
        CAtk2.Visible := false
        CAtk1.Visible := false
    }
    yy += 28

    CAtk4 := gui.AddCheckbox("x" lx " y" yy " w120 Checked" AtkEnabled4, atkCount >= 4 ? atkLabels[4] : "Attack 4")
    if atkCount < 4
        CAtk4.Visible := false
    yy += 34

    ; WB Schedule — profile flag
    if ModeProfiles[GameMode].hasWBSchedule {
        CWBSchedule := gui.AddCheckbox("x" lx " y" yy " w300 Checked" WBScheduleEnabled, "World Boss every hour (at :00)")
        yy += 30
    }
}

; --- Section builder: Discord Webhook (item 12) ---
BuildWebhookSection(gui, lx, eW, W, &yy) {
    global WebhookURL, EWebhook

    gui.SetFont("s8 c7289DA Bold", "Segoe UI")
    gui.AddText("x" lx " y" yy " w200", "DISCORD WEBHOOK (optional)")
    yy += 22

    gui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")
    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Webhook URL")
    yy += 26
    EWebhook := gui.AddEdit("x" lx " y" yy " w" (W - 56) " h24", WebhookURL)
    yy += 30

    gui.SetFont("s8 c" C_TEXT3 " Norm", "Segoe UI")
    gui.AddText("x" lx " y" yy " w" (W - 56), "Sends alerts on disconnect and recovery. Leave blank to disable.")
    yy += 24
}

; --- Section builder: Rejoin Failsafe (item 12) ---
BuildRejoinSection(gui, lx, ex, eW, W, &yy) {
    global InactivityThreshold, PrivateServerURL
    global EInactivityThresh, EPrivateSvrURL

    gui.SetFont("s8 c" C_RED " Bold", "Segoe UI")
    gui.AddText("x" lx " y" yy " w200", "REJOIN FAILSAFE")
    yy += 22

    gui.SetFont("s9 c" C_TEXT " Norm", "Segoe UI")
    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Inactivity Timeout (seconds)")
    EInactivityThresh := gui.AddEdit("x" ex " y" yy " w" eW " h24 Number", InactivityThreshold // 1000)
    yy += 30

    gui.AddText("x" lx " y" yy " w250 h24 +0x200", "Private Server URL")
    yy += 26
    EPrivateSvrURL := gui.AddEdit("x" lx " y" yy " w" (W - 56) " h24", PrivateServerURL)
    yy += 30

    gui.SetFont("s8 c" C_TEXT3 " Norm", "Segoe UI")
    gui.AddText("x" lx " y" yy " w" (W - 56), "Paste roblox.com private server URL. Macro will auto-rejoin when stuck 60s+.")
    yy += 24
}

OpenSettings() {
    global
    local W, lx, ex, yy, eW, bW, bSave, bDefaults

    try settingsGui.Destroy()

    W := 460

    settingsGui := Gui("+AlwaysOnTop +ToolWindow", "B.A.P - Settings")
    settingsGui.BackColor := C_BG
    settingsGui.MarginX := 0
    settingsGui.MarginY := 0
    settingsGui.OnEvent("Close", (*) => CloseSettings())

    ; Accent bar
    settingsGui.AddText("x0 y0 w" W " h2 Background" C_GOLD, "")

    ; Title
    settingsGui.SetFont("s16 c" C_GOLD " Bold", "Segoe UI")
    settingsGui.AddText("x0 y14 w" W " Center", "Settings")

    settingsGui.SetFont("s9 c" C_TEXT2 " Norm", "Segoe UI")
    settingsGui.AddText("x0 y42 w" W " Center", ModeNames[GameMode] " Mode  -  Values in milliseconds")

    ; Divider
    settingsGui.AddText("x24 y64 w" (W - 48) " h1 Background" C_BORDER, "")

    yy := 78
    lx := 28
    ex := 296
    eW := 130

    BuildTimingsSection(settingsGui, lx, ex, eW, &yy)

    settingsGui.AddText("x24 y" yy " w" (W - 48) " h1 Background" C_BORDER, "")
    yy += 14

    BuildDetectionSection(settingsGui, lx, ex, eW, &yy)

    settingsGui.AddText("x24 y" yy " w" (W - 48) " h1 Background" C_BORDER, "")
    yy += 14

    BuildModeSection(settingsGui, lx, ex, eW, &yy)

    settingsGui.AddText("x24 y" yy " w" (W - 48) " h1 Background" C_BORDER, "")
    yy += 14

    BuildWebhookSection(settingsGui, lx, eW, W, &yy)

    settingsGui.AddText("x24 y" yy " w" (W - 48) " h1 Background" C_BORDER, "")
    yy += 14

    BuildRejoinSection(settingsGui, lx, ex, eW, W, &yy)

    settingsGui.AddText("x24 y" yy " w" (W - 48) " h1 Background" C_BORDER, "")
    yy += 14

    ; Buttons
    bW := (W - 48 - 12) // 2
    bSave     := ColorBtn(settingsGui, 24, yy, bW, 38, "Save",     C_CARD,  (*) => SaveSettings())
    bDefaults := ColorBtn(settingsGui, 24 + bW + 12, yy, bW, 38, "Defaults", C_SLATE, (*) => ResetDefaults())
    yy += 50

    ; Bottom accent
    settingsGui.AddText("x0 y" (yy - 2) " w" W " h2 Background" C_GOLD, "")

    ApplyDarkMode(settingsGui)
    settingsGui.Show("w" W " h" yy)
}

CloseSettings(*) {
    global
    try settingsGui.Destroy()
}


; =======================================================================
;                     S E T U P   W I Z A R D
; =======================================================================

OpenSetup() {
    global
    local W, pbarTxt, sY, btnCount, totalSteps, hasImg, icon, clr, txt, ctrl
    local cnfFileOK, hasReconImg, bW, bBack, bSkip, bCancel

    if Running {
        MsgBox("Stop the macro first.", "Busy", "Icon!")
        return
    }

    SetupActive := true
    SetupIdx    := 1
    SetupPhase  := 0
    SLines      := []

    btnCount   := BtnNames.Length
    totalSteps := GetTotalSetupSteps()

    W := 440

    setupGui := Gui("+AlwaysOnTop +ToolWindow", "B.A.P - Setup")
    setupGui.BackColor := C_BG
    setupGui.MarginX := 0
    setupGui.MarginY := 0
    setupGui.OnEvent("Close", (*) => CloseSetup())

    ; Accent bar
    setupGui.AddText("x0 y0 w" W " h2 Background" C_GOLD, "")

    ; Title
    setupGui.SetFont("s16 c" C_GOLD " Bold", "Segoe UI")
    setupGui.AddText("x0 y12 w" W " Center", "Setup Wizard")

    setupGui.SetFont("s9 c" C_TEXT2 " Norm", "Segoe UI")
    setupGui.AddText("x0 y40 w" W " Center", ModeNames[GameMode] " Mode  -  R = position  -  R again = capture")

    ; Divider
    setupGui.AddText("x24 y62 w" (W - 48) " h1 Background" C_BORDER, "")

    ; -- Progress bar (text representation) --
    setupGui.SetFont("s7 c" C_GOLD " Norm", "Consolas")
    pbarTxt := BuildProgressBar(1, totalSteps)
    SProgress := setupGui.AddText("x24 y70 w" (W - 48) " Center", pbarTxt)

    ; -- Current step --
    setupGui.SetFont("s13 c" C_TEXT " Bold", "Segoe UI")
    SStep := setupGui.AddText("x24 y90 w" (W - 48) " Center", "Step 1 / " totalSteps "  -  " GetStepName(1))

    ; -- Instruction --
    setupGui.SetFont("s9 c" C_GREEN " Norm", "Segoe UI")
    SInstr := setupGui.AddText("x24 y116 w" (W - 48) " h36 Center", GetStepInstr(1))

    ; -- Coordinates --
    setupGui.SetFont("s10 c" C_TEXT3 " Norm", "Consolas")
    SCoords := setupGui.AddText("x24 y154 w" (W - 48) " Center", "X: ---   Y: ---")

    ; Divider
    setupGui.AddText("x24 y178 w" (W - 48) " h1 Background" C_BORDER, "")

    ; -- Captured items list --
    setupGui.SetFont("s8 c" C_TEXT3 " Bold", "Segoe UI")
    setupGui.AddText("x28 y186 w200", "CAPTURED")

    sY := 206

    ; Mode button lines
    Loop btnCount {
        hasImg := FileExist(ImgDir "\btn_" A_Index ".png")
        if BtnOK[A_Index] && hasImg {
            icon := "[+]"
            clr  := C_GREEN
            txt  := icon "  " BtnNames[A_Index] "   X=" BtnX[A_Index] "  Y=" BtnY[A_Index]
        } else if BtnOK[A_Index] {
            icon := "[~]"
            clr  := C_ORANGE
            txt  := icon "  " BtnNames[A_Index] "   X=" BtnX[A_Index] "  Y=" BtnY[A_Index] "  (no img)"
        } else {
            icon := "[-]"
            clr  := C_TEXT3
            txt  := icon "  " BtnNames[A_Index] "   -"
        }
        setupGui.SetFont("s8 c" clr " Norm", "Consolas")
        ctrl := setupGui.AddText("x28 y" sY " w" (W - 56), txt)
        SLines.Push(ctrl)
        sY += 24
    }

    ; CNF Icon line
    if HasCNF {
        cnfFileOK := FileExist(ImgDir "\cnf.png")
        if CnfImgOK && cnfFileOK {
            txt := "[+]  CNF Icon   Y=" CnfY
            clr := C_GREEN
        } else if CnfImgOK {
            txt := "[~]  CNF Icon   Y=" CnfY "  (no img)"
            clr := C_ORANGE
        } else {
            txt := "[-]  CNF Icon   -"
            clr := C_TEXT3
        }
        setupGui.SetFont("s8 c" clr " Norm", "Consolas")
        ctrl := setupGui.AddText("x28 y" sY " w" (W - 56), txt)
        SLines.Push(ctrl)
        sY += 24
    }

    ; Reconnect line
    hasReconImg := FileExist(ReconImgPath)
    if ReconOK && hasReconImg {
        txt := "[+]  Reconnect   X=" ReconX "  Y=" ReconY
        clr := C_GREEN
    } else if ReconOK {
        txt := "[~]  Reconnect   X=" ReconX "  Y=" ReconY "  (no img)"
        clr := C_ORANGE
    } else {
        txt := "[-]  Reconnect   -"
        clr := C_TEXT3
    }
    setupGui.SetFont("s8 c" clr " Norm", "Consolas")
    ctrl := setupGui.AddText("x28 y" sY " w" (W - 56), txt)
    SLines.Push(ctrl)
    sY += 8

    ; Divider
    setupGui.AddText("x24 y" sY " w" (W - 48) " h1 Background" C_BORDER, "")
    sY += 10

    ; Buttons
    bW := (W - 48 - 24) // 3  ; 3 buttons, 2 gaps of 12px
    bBack := ColorBtn(setupGui, 24, sY, bW, 34, "<<  Back", C_SLATE, (*) => BackSetupStep())
    bSkip := ColorBtn(setupGui, 24 + bW + 12, sY, bW, 34, ">>  Skip", C_VIOLET, (*) => SkipSetupStep())
    bCancel := ColorBtn(setupGui, 24 + (bW + 12) * 2, sY, bW, 34, "X  Cancel", C_CRIMSON, (*) => CloseSetup())
    sY += 44

    ; Bottom accent
    setupGui.AddText("x0 y" (sY - 2) " w" W " h2 Background" C_GOLD, "")

    SetTimer(SetupTick, 50)
    Hotkey("r", OnSetupR, "On")

    ApplyDarkMode(setupGui)
    setupGui.Show("w" W " h" sY)
}

; Skip the current setup step, keep previous values
SkipSetupStep() {
    global
    local btnCount, totalSteps, reconStep, sName
    btnCount   := BtnNames.Length
    totalSteps := GetTotalSetupSteps()
    reconStep  := GetReconStepIdx()

    if !SetupActive || SetupIdx < 1 || SetupIdx > totalSteps
        return

    if SetupIdx <= btnCount {
        if BtnX[SetupIdx] && BtnY[SetupIdx] && FileExist(ImgDir "\btn_" SetupIdx ".png") {
            BtnOK[SetupIdx] := 1
            UpdateSetupLine(SetupIdx, "[+]", "X=" BtnX[SetupIdx] "  Y=" BtnY[SetupIdx] "  (kept)")
        } else {
            BtnOK[SetupIdx] := 0
            UpdateSetupLine(SetupIdx, "[-]", "- (skipped)")
        }
    } else if HasCNF && SetupIdx = btnCount + 1 {
        if CnfY && FileExist(ImgDir "\cnf.png") {
            CnfImgOK := 1
            UpdateSetupLine(SetupIdx, "[+]", "Y=" CnfY "  (kept)")
        } else {
            CnfImgOK := 0
            UpdateSetupLine(SetupIdx, "[-]", "- (skipped)")
        }
    } else if SetupIdx = reconStep {
        if ReconX && ReconY && FileExist(ReconImgPath) {
            ReconOK := 1
            UpdateSetupLine(SetupIdx, "[+]", "X=" ReconX "  Y=" ReconY "  (kept)")
        } else {
            ReconOK := 0
            UpdateSetupLine(SetupIdx, "[-]", "- (skipped)")
        }
    }

    SetupIdx++
    SetupPhase := 0

    if SetupIdx > totalSteps {
        FinishSetup()
        return
    }

    sName := GetStepName(SetupIdx)
    SStep.Value     := "Step " SetupIdx " / " totalSteps "  -  " sName
    SInstr.Value    := GetStepInstr(SetupIdx)
    SProgress.Value := BuildProgressBar(SetupIdx, totalSteps)
}

; Go back one step in setup
BackSetupStep() {
    global
    local totalSteps, sName
    totalSteps := GetTotalSetupSteps()

    if !SetupActive || SetupIdx <= 1
        return

    SetupIdx--
    SetupPhase := 0

    sName := GetStepName(SetupIdx)
    SStep.Value     := "Step " SetupIdx " / " totalSteps "  -  " sName
    SInstr.Value    := GetStepInstr(SetupIdx)
    SProgress.Value := BuildProgressBar(SetupIdx, totalSteps)
    SCoords.Value   := "X: ---   Y: ---"
}

; Build a text progress bar
BuildProgressBar(current, total) {
    local bar
    bar := ""
    Loop total {
        if A_Index < current
            bar .= "= "
        else if A_Index = current
            bar .= "> "
        else
            bar .= "- "
    }
    return bar
}

; Called when all setup steps are done
FinishSetup() {
    global
    local btnCount, doneMsg
    SetTimer(SetupTick, 0)
    Hotkey("r", OnSetupR, "Off")
    SetupActive := false
    SaveConfig()
    RefreshReadyGrid()
    setupGui.Destroy()

    btnCount := BtnNames.Length
    doneMsg := btnCount " buttons"
    if HasCNF
        doneMsg .= " + CNF"
    doneMsg .= " + Reconnect captured!"
    MsgBox(doneMsg "`nMode: " ModeNames[GameMode] "`n`nReady to start - press F6.", "Setup Complete", "Icon!")
}

SetupTick(*) {
    global
    if !SetupActive
        return
    MouseGetPos(&mx, &my)
    SCoords.Value := "X: " mx "   Y: " my
}

OnSetupR(*) {
    global
    local btnCount, totalSteps, reconStep, stepName, half, cnfHalf, outPath, sName
    btnCount   := BtnNames.Length
    totalSteps := GetTotalSetupSteps()
    reconStep  := GetReconStepIdx()

    if !SetupActive || SetupIdx < 1 || SetupIdx > totalSteps
        return

    stepName := GetStepName(SetupIdx)

    ; Phase 0: save position
    if SetupPhase = 0 {
        local mx, my
        MouseGetPos(&mx, &my)
        SetupSavedX := mx
        SetupSavedY := my
        SetupPhase  := 1
        SoundBeep(600, 50)
        SCoords.Value := "Saved: X=" mx "  Y=" my
        SInstr.Value  := "Position locked - move away, press R to capture"
        UpdateSetupLine(SetupIdx, "[~]", "X=" mx "  Y=" my "  ...")
        return
    }

    ; Phase 1: capture reference image
    setupGui.Hide()
    Sleep(350)   ; longer delay ensures GUI fully repaints before capture

    half := CaptureSize // 2

    if SetupIdx <= btnCount {
        if !DirExist(ImgDir)
            DirCreate(ImgDir)
        outPath := ImgDir "\btn_" SetupIdx ".png"
        GrabScreen(SetupSavedX - half, SetupSavedY - half, CaptureSize, CaptureSize, outPath)
        BtnX[SetupIdx]  := SetupSavedX
        BtnY[SetupIdx]  := SetupSavedY
        BtnOK[SetupIdx] := 1
    } else if HasCNF && SetupIdx = btnCount + 1 {
        if !DirExist(ImgDir)
            DirCreate(ImgDir)
        cnfHalf := CnfCaptureSize // 2
        outPath := ImgDir "\cnf.png"
        GrabScreen(SetupSavedX - cnfHalf, SetupSavedY - cnfHalf, CnfCaptureSize, CnfCaptureSize, outPath)
        CnfY     := SetupSavedY
        CnfLastX := SetupSavedX
        CnfBaseX := SetupSavedX
        CnfImgOK := 1
    } else if SetupIdx = reconStep {
        outPath := ReconImgPath
        GrabScreen(SetupSavedX - half, SetupSavedY - half, CaptureSize, CaptureSize, outPath)
        ReconX  := SetupSavedX
        ReconY  := SetupSavedY
        ReconOK := 1
    }

    setupGui.Show()

    UpdateSetupLine(SetupIdx, "[+]", "X=" SetupSavedX "  Y=" SetupSavedY)
    SoundBeep(800, 60)

    SetupIdx++
    SetupPhase := 0

    if SetupIdx > totalSteps {
        FinishSetup()
        return
    }

    sName := GetStepName(SetupIdx)
    SStep.Value     := "Step " SetupIdx " / " totalSteps "  -  " sName
    SInstr.Value    := GetStepInstr(SetupIdx)
    SProgress.Value := BuildProgressBar(SetupIdx, totalSteps)
}

CloseSetup(*) {
    global
    SetTimer(SetupTick, 0)
    try Hotkey("r", OnSetupR, "Off")
    SetupActive := false
    try setupGui.Destroy()
}


; =======================================================================
;                   M A C R O   C O N T R O L
; =======================================================================

ToggleMacro(*) {
    global
    if Running
        StopMacro()
    else
        StartMacro()
}

StartMacro() {
    global

    ; Validate all mode buttons
    Loop BtnNames.Length {
        if !BtnOK[A_Index] || !FileExist(ImgDir "\btn_" A_Index ".png") {
            MsgBox("Run Setup to capture all buttons first.`n(" ModeNames[GameMode] " mode)", "Setup Needed", "Icon!")
            return
        }
    }
    if HasCNF && (!CnfImgOK || !FileExist(ImgDir "\cnf.png")) {
        MsgBox("Run Setup to capture CNF icon first.`n(" ModeNames[GameMode] " mode)", "Setup Needed", "Icon!")
        return
    }

    Running        := true
    ; Use MacroState.ResetForStart for a single canonical reset path
    if IsObject(gMacroState)
        gMacroState.ResetForStart()
    else {
        Phase          := PH_IDLE
        PhaseStartTime := A_TickCount
        BattleCount    := 0
        AttackClicks   := 0
        RunCount       := 0
        AttackMissRun  := 0
        FleeMissRun    := 0
        NextAtk        := 1
        SeqRevisit     := false
        LastAttackTime := 0
        LastBattleEnd  := 0
        LastBtnSeen    := A_TickCount
        HealCounter    := 0
        RestCounter    := 0
        LastReconnectClick := 0
        LastAnyDetection   := A_TickCount
        RejoinRetryDone    := false
        RejoinRetryTime    := 0
        NeedsRecovery  := false
        RecoveryStep   := 0
        DungeonInitDone     := false
        DungeonInitStep     := 0
        DungeonInitStepTime := 0
        DungeonInitRetries  := 0
    }
    ClampSettings()
    ForceWindowed()

    MacroStartTime := A_TickCount
    SetTimer(ElapsedTick, 1000)
    ; Show accumulated time immediately
    ElapsedTick()

    BtnRun.Value   := "#   S T O P"
    GStatus.Value := "RUNNING"
    GPhaseIcon.Value := GetPhaseIcon()
    GDetail.Value := "Scanning... (" ModeNames[GameMode] ")"

    if IsObject(gLog)
        gLog.Info("MACRO", "Started  mode=" ModeNames[GameMode])
    SetTimer(Tick, LoopMS)
    SetTimer(WebhookTick, 1000)   ; item 16: start webhook drain timer
}

StopMacro() {
    global
    ; Accumulate elapsed time from this run
    if MacroStartTime > 0
        AccumulatedTime += (A_TickCount - MacroStartTime) // 1000
    MacroStartTime := 0
    Running := false
    if IsObject(gLog) {
        gLog.Info("MACRO", "Stopped")
        gLog.Flush()   ; persist buffered entries now — no more ticks will trigger a flush
    }
    SetTimer(Tick, 0)
    SetTimer(WebhookTick, 0)   ; item 16: stop webhook drain
    SetTimer(ElapsedTick, 0)
    BtnRun.Value      := ">   S T A R T"
    GStatus.Value    := "STOPPED"
    GPhaseIcon.Value := GetPhaseIcon()
    GDetail.Value    := "Macro paused"
}


; =======================================================================
;              M A I N   T I C K   ( P R I O R I T Y   L O O P )
; =======================================================================

Tick(*) {
    global
    local now, presConf

    Critical "On"   ; prevent timer re-entry while this tick is running

    if !Running {
        Critical "Off"
        return
    }

    now := A_TickCount

    ; === Guard: skip tick if Roblox window not found or not visible ===
    local robloxHwnd := 0
    try {
        robloxHwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
        if !robloxHwnd
            robloxHwnd := WinExist("Roblox")
    }
    if !robloxHwnd {
        GDetail.Value := "Roblox not found - waiting..."
        ; === Crash recovery: inactivity failsafe MUST run even when the window is gone ===
        ; The normal failsafe block at the bottom of Tick is never reached from this early return.
        if PrivateServerURL != "" && !InactivityExempt(now) {
            if LastAnyDetection = 0
                LastAnyDetection := now
            else if (now - LastAnyDetection) >= InactivityThreshold {
                if !RejoinRetryDone {
                    ; No window to send Escape/click to — mark retry done, wait 10 s, then launch
                    GStatus.Value   := "STUCK"
                    GDetail.Value   := "Roblox gone for " Round((now - LastAnyDetection) / 1000) "s — rejoining in 10s..."
                    RejoinRetryDone := true
                    RejoinRetryTime := now
                } else if (now - RejoinRetryTime) >= 10000 {
                    Critical "Off"
                    DoRejoin()
                    return
                }
            }
        }
        Critical "Off"
        return
    }
    ; Skip if Roblox is minimized — don't search/click whatever is on screen
    if DllCall("IsIconic", "Ptr", robloxHwnd) {
        GDetail.Value := "Roblox is minimized - waiting..."
        Critical "Off"
        return
    }

    GPhaseIcon.Value := GetPhaseIcon()

    ; === Reconnect check — runs even during WB ===
    if ReconOK && Phase != PH_RECOVERY && (now - LastReconnectClick) >= ReconnectCooldown && FindRecon() {
        ; Retry up to 3 times to confirm the click was delivered and accepted
        Loop 3 {
            DoClick(ReconX, ReconY)   ; ends with Critical "On"
            Critical "Off"            ; release before sleeping so timers aren't blocked
            Sleep(200)
            Critical "On"
            if !FindRecon()   ; button gone — click registered
                break
        }
        LastReconnectClick := now
        LastBtnSeen        := now
        NeedsRecovery      := true
        RecoveryStep       := 0
        Phase              := PH_RECOVERY
        PhaseStartTime     := now
        ForceWindowed()
        GStatus.Value      := "RECONNECTING"
        GDetail.Value      := "Disconnect detected - Reconnect clicked, starting recovery"
        SendWebhook("Disconnected! Reconnect clicked - starting recovery. Mode: " ModeNames[GameMode])
        UpdateCounters()
        return
    }

    ; === ABSOLUTE PRIORITY: WB Schedule takeover ===
    ; When active, this blocks ALL other logic until WB is done.
    if Phase = PH_WORLDBOSS {
        TickWorldBoss(now)
        UpdateCounters()
        return
    }

    ; === WB Schedule trigger - profile-driven, every hour at :00/:01 (item 26) ===
    if WBScheduleEnabled && ModeProfiles[GameMode].hasWBSchedule {
        local curMin  := A_Min + 0
        local curHour := FormatTime(, "H") + 0
        if curMin <= 1 && curHour != LastWBHour {
            ; Verify WB buttons AND images are actually set up
            local wbOK := SafeInt(IniRead(CfgFile, "World Boss_Buttons", "Enter Fight_OK", 0), 0)
            if wbOK && !FileExist(A_ScriptDir "\images_raid\btn_1.png")
                wbOK := 0
            if !wbOK {
                LastWBHour := curHour   ; don't retry every tick
                GDetail.Value := "WB skipped - World Boss not set up"
            } else {
                LastWBHour     := curHour
                Phase          := PH_WORLDBOSS
                PhaseStartTime := now
                WBStep         := -1
                WBStepTime     := now
                GStatus.Value  := "WB SCHEDULED"
                GDetail.Value  := "WB hour - pausing everything, fleeing battle..."
                UpdateCounters()
                return
            }
        }
    }

    ; --- PRIORITY 0: CNF - enter confused phase (modes with CNF only) ---
    if HasCNF && Phase != PH_CONFUSED && Phase != PH_RECOVERY && Phase != PH_WORLDBOSS && FindCNF() {
        CnfClearCount  := 0
        PreCnfPhase    := Phase
        Phase          := PH_CONFUSED
        PhaseStartTime := now
        GStatus.Value  := "CONFUSED"
        GDetail.Value  := "CNF detected - entering REST mode"
        UpdateCounters()
        return
    }

    ; --- PRIORITY 1: Prestige - Story only, idle phase only ---
    ; Grace window after a completed prestige: let the post-prestige screen settle and
    ; start grinding before we'll fire another prestige. Stops a lingering/fading
    ; prestige button from re-triggering an immediate second prestige (sticking).
    if PresIdx > 0 && Phase = PH_IDLE && (now - LastPrestigeDone) >= PrestigeReentryGuard {
        if FindBtn(PresIdx, SavedImgTolerance) {
            LastBtnSeen    := now
            GDetail.Value  := "Prestige detected - verifying..."
            presConf       := ClickAndVerify(PresIdx, SavedImgTolerance)
            Phase          := PH_PRESTIGE
            PhaseStartTime := now
            AttackMissRun  := 0
            GStatus.Value  := "PRESTIGE"
            GDetail.Value  := presConf ? "Prestige confirmed" : "Prestige clicked"
            UpdateCounters()
            return
        }
    }

    ; --- Phase dispatch ---
    switch Phase {
        case 0: TickIdle(now)
        case 1: TickBattle(now)
        case 2: TickPrestige(now)
        case 3: TickConfused(now)
        case 4: TickFleeing(now)
        case 5: TickRecovery(now)
    }

    ; --- FALLBACK: no button seen for too long - press 1 ---
    ; Skip during confusion, flee, recovery, prestige, and WB
    if Phase != PH_CONFUSED && Phase != PH_FLEEING && Phase != PH_RECOVERY && Phase != PH_WORLDBOSS && Phase != PH_PRESTIGE && (now - LastBtnSeen) >= FallbackDelay {
        EnsureRobloxFocus()   ; the "1" keypress must land in Roblox, not the B.A.P window
        Send("1")
        LastBtnSeen := now
        GDetail.Value := "Fallback - pressed 1"
    }

    ; --- INACTIVITY FAILSAFE: rejoin private server if completely stuck ---
    ; Only active when PrivateServerURL is configured and we are not in an exempt phase.
    if PrivateServerURL != "" && !InactivityExempt(now) {
        if LastAnyDetection = 0
            LastAnyDetection := now
        else if (now - LastAnyDetection) >= InactivityThreshold {
            if !RejoinRetryDone {
                GDetail.Value   := "Inactivity failsafe: last-chance retry..."
                GStatus.Value   := "STUCK"
                if ReconOK && FindRecon()
                    DoClick(ReconX, ReconY)
                else {
                    EnsureRobloxFocus()   ; Escape must reach Roblox to dismiss a stuck menu
                    Send("{Escape}")
                }
                RejoinRetryDone := true
                RejoinRetryTime := now
            } else if (now - RejoinRetryTime) >= 10000 {
                DoRejoin()
            }
        }
    }

    UpdateCounters()
}


; -- IDLE: look for entry button to start battle ----------

TickIdle(now) {
    global
    local remaining, atkIdx, atkSlotN, entConf

    GStatus.Value := "IDLE"

    ; -- Scroll-based modes: first-time tab open + scroll (item 21: NeedsScroll, not if GameMode=3)
    if NeedsScroll && !DungeonInitDone {
        TickDungeonInit(now)
        return
    }

    ; Wait after a battle ends before looking for entry
    if LastBattleEnd > 0 && (now - LastBattleEnd) < PostBattleDelay {
        remaining := Round((PostBattleDelay - (now - LastBattleEnd)) / 1000, 1)
        GDetail.Value := "Post-battle wait (" remaining "s)"
        return
    }

    ; Check for Attack first - battle may have auto-started or resumed
    atkIdx    := 0
    atkSlotN  := 0
    for i, slot in AtkSlots {
        if IsAtkEnabled(i) && FindBtn(slot, SavedImgTolerance) {
            atkIdx   := slot
            atkSlotN := i
            break
        }
    }
    if atkIdx {
        TryClickBtn(atkIdx, SavedImgTolerance)
        LastBtnSeen    := now
        RecordDetection()
        AttackClicks++
        if HealIdx > 0
            HealCounter := 1
        if RestIdx > 0
            RestCounter := 1
        LastAttackTime := now
        AttackMissRun  := 0
        NextAtk        := SeqAttack ? atkSlotN : Mod(atkSlotN, AtkSlots.Length) + 1
        LastBattleEnd  := 0
        Phase          := PH_BATTLE
        PhaseStartTime := now
        GDetail.Value  := "Attack found - jumping into battle"
        return
    }

    ; Then check for entry button (Story / Enter Fight / Start Dungeon - always index 1)
    if FindBtn(1, SavedImgTolerance) {
        entConf        := ClickAndVerify(1, SavedImgTolerance)
        LastBtnSeen    := now
        RecordDetection()
        LastBattleEnd  := 0
        Phase          := PH_BATTLE
        PhaseStartTime := now
        AttackMissRun  := 0
        NextAtk        := 1
        HealCounter    := 0
        RestCounter    := 0
        BattleCount++
        GDetail.Value  := entConf ? BtnNames[1] " confirmed - entering battle" : BtnNames[1] " clicked - entering battle"
        return
    }

    ; Nav fallback: try clicking nav tab to return to the right screen
    ; item 27: !NeedsScroll replaces GameMode != 3 (scroll-based modes use TickDungeonInit nav)
    if NavIdx > 0 && !NeedsScroll && FindBtn(NavIdx, SavedImgTolerance) {
        TryClickBtn(NavIdx, SavedImgTolerance)
        LastBtnSeen := now
        GDetail.Value := "Clicked " BtnNames[NavIdx] " tab"
        return
    }

    GDetail.Value := "Scanning for " BtnNames[1] "/Attack... (tol:" SavedImgTolerance ")"
}


; -- DUNGEON INIT: sequential entry for Inf Dungeon only --
; Step 0: Click nav tab  →  Step 1: Wait + scroll  →  Step 2: Scan for Start/Attack
; Buttons are ONLY scanned AFTER scrolling to prevent false matches.

TickDungeonInit(now) {
    global

    GStatus.Value := "DUNGEON INIT"

    ; Throttle scans
    if (now - DungeonInitStepTime) < 500
        return

    switch DungeonInitStep {
        case 0:
            ; Step 0: Click nav tab (Go to Dungeon)
            if NavIdx > 0 && FindBtn(NavIdx, SavedImgTolerance) {
                DoClick(BtnX[NavIdx], BtnY[NavIdx])
                DungeonInitStepTime := now
                LastBtnSeen         := now
                DungeonInitStep     := 1
                GDetail.Value := "Clicked " BtnNames[NavIdx] " tab"
            } else {
                ; Nav tab not found — maybe already in menu, skip to scroll
                DungeonInitStepTime := now
                DungeonInitStep     := 1
                GDetail.Value       := "Nav not found - trying scroll..."
            }

        case 1:
            ; Step 1: Wait for tab to load, then scroll down
            if (now - DungeonInitStepTime) < 600
                return
            EnsureRobloxFocus()   ; wheel events go to the focused window — guarantee it's Roblox
            local gw := GetGameWindow()
            MouseMove(gw.cx, gw.cy)
            Loop ScrollTicks
                Send("{WheelDown}")
            DungeonInitStepTime := now
            DungeonInitStep     := 2
            GDetail.Value       := "Scrolled down (" ScrollTicks " ticks)"

        case 2:
            ; Step 2: Wait after scroll, THEN scan for Start Dungeon / Attack
            if (now - DungeonInitStepTime) < 600
                return

            ; Check for Start Dungeon button
            if FindBtn(1, SavedImgTolerance) {
                DoClick(BtnX[1], BtnY[1])
                LastBtnSeen     := now
                RecordDetection()
                DungeonInitDone := true
                Phase           := PH_BATTLE
                PhaseStartTime  := now
                AttackMissRun   := 0
                NextAtk         := 1
                HealCounter     := 0
                RestCounter     := 0
                BattleCount++
                GDetail.Value   := BtnNames[1] " found - entering battle"
                return
            }

            ; Check for Attack buttons (already in battle?)
            local atkIdx := 0, atkSlotN := 0
            for i, slot in AtkSlots {
                if IsAtkEnabled(i) && FindBtn(slot, SavedImgTolerance) {
                    atkIdx   := slot
                    atkSlotN := i
                    break
                }
            }
            if atkIdx {
                DoClick(BtnX[atkIdx], BtnY[atkIdx])
                LastBtnSeen     := now
                RecordDetection()
                AttackClicks++
                HealCounter     := 1
                RestCounter     := 1
                LastAttackTime  := now
                AttackMissRun   := 0
                NextAtk         := atkSlotN
                DungeonInitDone := true
                Phase           := PH_BATTLE
                PhaseStartTime  := now
                GDetail.Value   := "Already in battle - " BtnNames[atkIdx]
                return
            }

            ; Nothing found — retry
            DungeonInitRetries++
            if DungeonInitRetries >= 3 {
                ; Stuck — press 1 to dismiss any blocking dialog, restart from nav
                Send("1")
                Sleep(200)
                DungeonInitRetries  := 0
                DungeonInitStep     := 0
                DungeonInitStepTime := now
                GDetail.Value       := "Stuck - dismissing dialog..."
            } else {
                ; Scroll again
                DungeonInitStep     := 1
                DungeonInitStepTime := now
                GDetail.Value       := "Not found - scrolling again..."
            }
    }
}


; -- BATTLE: spam Attack until it vanishes ----------------

TickBattle(now) {
    global
    local visMap, anyAttackVisible, vis, chosenIdx, chosenSlot, s

    GStatus.Value := "BATTLE"

    ; Brief grace period after entering battle for UI to load
    if (now - PhaseStartTime) < GetEntryWait() {
        GDetail.Value := "Battle loading..."
        return
    }

    ; -- Sequential attack mode (Inf Dungeon) --
    if SeqAttack {
        TickBattleSequential(now)
        return
    }

    ; -- Round-robin attack mode (Story / World Boss) --
    ; Check all attack buttons
    visMap := []
    anyAttackVisible := false
    for i, slot in AtkSlots {
        vis := IsAtkEnabled(i) && FindBtn(slot, SavedImgTolerance)
        visMap.Push(vis)
        if vis
            anyAttackVisible := true
    }

    if anyAttackVisible {
        AttackMissRun := 0
        LastBtnSeen   := now
        RecordDetection()

        ; Heal check (every HealEvery attacks)
        if HealEnabled && HealIdx > 0 && HealCounter >= HealEvery {
            if FindBtn(HealIdx, SavedImgTolerance) {
                TryClickBtn(HealIdx, SavedImgTolerance)
                GDetail.Value := "Healed! (after " HealCounter " attacks)"
                HealCounter    := 0
                LastAttackTime := now
                return
            }
            GDetail.Value := "Heal ready (" HealCounter "/" HealEvery ") - btn not found"
        }

        ; CNF guard (modes with CNF)
        if HasCNF && FindCNF() {
            GDetail.Value := "CNF detected - aborting attack!"
            CnfClearCount  := 0
            PreCnfPhase    := PH_BATTLE
            Phase          := PH_CONFUSED
            PhaseStartTime := now
            return
        }

        ; Enforce gap between clicks
        if (now - LastAttackTime) < AttackGap {
            GDetail.Value := "Attack visible - cooldown..."
            return
        }

        ; Round-robin: pick next visible attack
        chosenIdx  := 0
        chosenSlot := 0
        Loop AtkSlots.Length {
            s := Mod(NextAtk - 1 + A_Index - 1, AtkSlots.Length) + 1
            if visMap[s] {
                chosenIdx  := AtkSlots[s]
                chosenSlot := s
                break
            }
        }

        if chosenIdx > 0 {
            TryClickBtn(chosenIdx, SavedImgTolerance)
            AttackClicks++
            LastAttackTime := now
            if HealIdx > 0
                HealCounter++
            NextAtk := Mod(chosenSlot, AtkSlots.Length) + 1
            GDetail.Value := BtnNames[chosenIdx] "! (" AttackClicks " hits)"
        }
        return
    }

    ; No attack button visible - count as a real miss
    AttackMissRun++

    if AttackMissRun >= MissThreshold {
        Phase          := PH_IDLE
        PhaseStartTime := now
        AttackMissRun  := 0
        NextAtk        := 1
        LastBattleEnd  := now
        HealCounter    := 0
        if NeedsScroll {   ; item 20: profile-driven, not if GameMode = 3
            DungeonInitDone := false
            DungeonInitStep := 0
            DungeonInitRetries := 0
        }
        GDetail.Value  := "Battle ended - waiting before next"
        return
    }

    GDetail.Value := "Attack not found (" AttackMissRun "/" MissThreshold ")"
}


; -- BATTLE (Sequential): Atk1 exhaust -> Atk2 exhaust -> Flee --

TickBattleSequential(now) {
    global
    local curSlot, curBtn

    ; Enforce gap between clicks
    if (now - LastAttackTime) < AttackGap {
        GDetail.Value := "Attack cooldown..."
        return
    }

    ; Heal check first (independent of attack visibility)
    if HealEnabled && HealIdx > 0 && HealCounter >= HealEvery {
        if FindBtn(HealIdx, SavedImgTolerance) {
            TryClickBtn(HealIdx, SavedImgTolerance)
            GDetail.Value  := "Healed! (after " HealCounter " attacks)"
            HealCounter    := 0
            AttackMissRun  := 0   ; heal proves we're still in battle - reset miss counter
            LastAttackTime := now
            LastBtnSeen    := now
            return
        }
        GDetail.Value := "Heal ready (" HealCounter "/" HealEvery ") - btn not found"
    }

    ; Try current attack slot
    curSlot := NextAtk
    if curSlot >= 1 && curSlot <= AtkSlots.Length {
        curBtn := AtkSlots[curSlot]

        ; Skip disabled slots
        if !IsAtkEnabled(curSlot) {
            NextAtk++
            if NextAtk > AtkSlots.Length {
                Phase          := PH_FLEEING
                PhaseStartTime := now
                FleeMissRun    := 0
                GDetail.Value  := "All slots disabled/exhausted - fleeing!"
                return
            }
            GDetail.Value := BtnNames[curBtn] " disabled - skipping"
            return
        }

        if FindBtn(curBtn, SavedImgTolerance) {
            TryClickBtn(curBtn, SavedImgTolerance)
            AttackClicks++
            HealCounter++
            RestCounter++
            LastAttackTime := now
            AttackMissRun  := 0
            LastBtnSeen    := now
            RecordDetection()
            GDetail.Value := BtnNames[curBtn] "! (" AttackClicks " hits)"
            return
        }

        ; Current slot not visible — before counting miss, check if an earlier slot came back
        if curSlot > 1 {
            local prevSlot, prevBtn
            Loop curSlot - 1 {
                prevSlot := A_Index
                if !IsAtkEnabled(prevSlot)
                    continue
                prevBtn := AtkSlots[prevSlot]
                if FindBtn(prevBtn, SavedImgTolerance) {
                    ; Earlier slot is available again — switch back with fast re-exhaust
                    NextAtk       := prevSlot
                    AttackMissRun := 0
                    SeqRevisit    := true
                    TryClickBtn(prevBtn, SavedImgTolerance)
                    AttackClicks++
                    HealCounter++
                    RestCounter++
                    LastAttackTime := now
                    LastBtnSeen    := now
                    RecordDetection()
                    GDetail.Value := BtnNames[prevBtn] " back! (" AttackClicks " hits)"
                    return
                }
            }
        }

        ; Grace period: if we clicked this attack recently, the button is just
        ; on cooldown (grayed out / animation) — don't count toward exhaustion.
        ; Only start counting misses after the grace window expires.
        if (now - LastAttackTime) < 2000 {
            ; Rest check during attack cooldown (lowest priority)
            if RestEnabled && RestIdx > 0 && RestCounter >= RestEvery {
                if FindBtn(RestIdx, SavedImgTolerance) {
                    TryClickBtn(RestIdx, SavedImgTolerance)
                    GDetail.Value  := "Rested! (after " RestCounter " attacks)"
                    RestCounter    := 0
                    LastAttackTime := now
                    LastBtnSeen    := now
                    return
                }
            }
            GDetail.Value := BtnNames[curBtn] " on cooldown..."
            return
        }

        ; Genuine miss on current slot (past cooldown grace period)
        AttackMissRun++

        ; If revisiting an earlier slot, use tiny threshold (3) so we snap back fast
        ; Normal forward exhaustion uses full 3x threshold
        local exhaustThresh := SeqRevisit ? 3 : (MissThreshold * 3)

        if AttackMissRun >= exhaustThresh {
            ; Before switching: retry once at generous tolerance to confirm truly exhausted
            if FindBtn(curBtn, SavedImgTolerance) {
                ; Still there! Tolerance was just too tight — reset and keep going
                AttackMissRun := 0
                TryClickBtn(curBtn, SavedImgTolerance)
                AttackClicks++
                HealCounter++
                RestCounter++
                LastAttackTime := now
                LastBtnSeen    := now
                GDetail.Value  := BtnNames[curBtn] "! (still there)"
                return
            }

            ; Single attack slot: don't exhaust, just keep trying
            if AtkSlots.Length <= 1 {
                ; Battle may be over — fall back to idle to re-detect
                Phase          := PH_IDLE
                PhaseStartTime := now
                AttackMissRun  := 0
                LastBattleEnd  := now
                HealCounter    := 0
                RestCounter    := 0
                DungeonInitDone := false
                DungeonInitStep := 0
                DungeonInitRetries := 0
                GDetail.Value  := "Attack gone - restarting dungeon nav"
                return
            }

            ; Truly exhausted — move to next attack slot
            AttackMissRun := 0
            SeqRevisit    := false
            NextAtk++

            if NextAtk > AtkSlots.Length {
                ; All attacks exhausted - transition to Flee phase
                Phase          := PH_FLEEING
                PhaseStartTime := now
                FleeMissRun    := 0
                GDetail.Value  := "Attacks exhausted - fleeing!"
                return
            }

            GDetail.Value := "Slot exhausted - switching to " BtnNames[AtkSlots[NextAtk]]
            return
        }

        GDetail.Value := BtnNames[curBtn] " not found (" AttackMissRun "/" exhaustThresh ")"
        return
    }

    ; Shouldn't reach here - failsafe to Flee
    Phase          := PH_FLEEING
    PhaseStartTime := now
    FleeMissRun    := 0
}


; -- FLEEING: spam Flee until out of dungeon (Inf Dungeon) --

TickFleeing(now) {
    global
    local burstClicks, fx, fy

    GStatus.Value := "FLEEING"

    if FleeIdx <= 0
        return

    if FindBtn(FleeIdx, SavedImgTolerance) {
        ; Burst-click the flee button 5 times
        fx := BtnX[FleeIdx]
        fy := BtnY[FleeIdx]
        burstClicks := 5
        Loop burstClicks {
            RawClick(fx, fy)
            Sleep(50)
        }
        ; Park mouse at top of game window and jiggle to shake off attached UI
        local gw := GetGameWindow()
        MouseMove(gw.cx, gw.y + 30)
        Sleep(15)
        MouseMove(gw.cx + 10, gw.y + 30)
        Sleep(15)
        MouseMove(gw.cx, gw.y + 30)
        FleeMissRun    := 0
        LastBtnSeen    := now
        RecordDetection()
        LastAttackTime := now
        GDetail.Value  := "Flee! - burst x" burstClicks
        return
    }

    ; Flee not visible - maybe we're out
    FleeMissRun++

    if FleeMissRun >= MissThreshold {
        ; Successfully fled - return to idle with fresh dungeon init
        RunCount++
        Phase          := PH_IDLE
        PhaseStartTime := now
        AttackMissRun  := 0
        FleeMissRun    := 0
        NextAtk        := 1
        HealCounter    := 0
        RestCounter    := 0
        LastBattleEnd  := now
        DungeonInitDone := false  ; re-run smart init for next dungeon
        DungeonInitStep := 0
        DungeonInitRetries := 0
        GDetail.Value  := "Fled dungeon - waiting before next"
        return
    }

    ; Flee not found yet - spam-click last known position while waiting
    fx := BtnX[FleeIdx]
    fy := BtnY[FleeIdx]
    if fx > 0 && fy > 0 {
        Loop 3 {
            RawClick(fx, fy)
            Sleep(50)
        }
        GDetail.Value := "Flee not found - blind clicking (" FleeMissRun "/" MissThreshold ")"
    } else {
        GDetail.Value := "Flee not found (" FleeMissRun "/" MissThreshold ")"
    }
}


; -- RECOVERY: post-reconnect navigation back to mode screen --
; Runs ONCE after Reconnect. Steps:
;   0 -> Press 1 (dismiss menus)
;   1 -> Wait, then check if nav needed
;   2 -> Find & click Nav button (Go to WB / Go to Dungeon)
;   3 -> Wait after nav, scroll if needed
;   4 -> Wait after scroll
;   5 -> Find & click entry button -> PH_BATTLE

TickRecovery(now) {
    global

    GStatus.Value := "RECOVERY"

    ; Global timeout: if recovery takes longer than 30s, give up and go idle
    if (now - PhaseStartTime) > 30000 {
        NeedsRecovery  := false
        Phase          := PH_IDLE
        PhaseStartTime := now
        LastBtnSeen    := now
        LastReconnectClick := now   ; prevent immediate re-entry into recovery
        GDetail.Value  := "Recovery timed out - returning to idle"
        SendWebhook("Recovery timed out after 30s. Mode: " ModeNames[GameMode])
        return
    }

    switch RecoveryStep {
        case 0:
            ; item 5 (Phase 2.3): validate required images are still present before navigating
            gServices.ValidateMode(ImgDir, BtnNames, HasCNF)
            ; Press 1 multiple times to dismiss any stacked dialogs/menus
            Send("1")
            Sleep(100)
            Send("1")
            Sleep(100)
            Send("1")
            RecoveryStepTime := now
            RecoveryStep     := 1
            GDetail.Value    := "Recovery: pressed 1..."

        case 1:
            ; Wait for UI to settle
            if (now - RecoveryStepTime) < RecoveryWait
                return
            if NavIdx > 0 {
                RecoveryStep  := 2
                GDetail.Value := "Recovery: looking for " BtnNames[NavIdx] "..."
            } else {
                ; No nav needed (Story) - just go back to idle
                NeedsRecovery  := false
                Phase          := PH_IDLE
                PhaseStartTime := now
                LastBtnSeen    := now
                GDetail.Value  := "Recovery done - scanning for " BtnNames[1]
                SendWebhook("Recovery complete - back online. Mode: " ModeNames[GameMode])
            }

        case 2:
            ; Find and click the navigation button (Go to WB / Go to Dungeon)
            if (now - RecoveryStepTime) < 500
                return
            if FindBtn(NavIdx, SavedImgTolerance) || FindBtnWide(NavIdx, SavedImgTolerance) {
                DoClick(BtnX[NavIdx], BtnY[NavIdx])
                RecoveryStepTime := now
                LastBtnSeen      := now
                RecoveryStep     := 3
                GDetail.Value    := "Recovery: clicked " BtnNames[NavIdx]
            } else {
                RecoveryStepTime := now
                GDetail.Value := "Recovery: searching for " BtnNames[NavIdx] "..."
            }

        case 3:
            ; Wait after clicking nav, then scroll if needed
            if (now - RecoveryStepTime) < RecoveryWait
                return
            if NeedsScroll {
                ; Scroll down at center of screen
                EnsureRobloxFocus()   ; wheel events go to the focused window — guarantee it's Roblox
                local gw := GetGameWindow()
                MouseMove(gw.cx, gw.cy)
                Loop ScrollTicks
                    Send("{WheelDown}")
                RecoveryStepTime := now
                RecoveryStep     := 4
                GDetail.Value    := "Recovery: scrolled down (" ScrollTicks " ticks)"
            } else {
                ; No scroll needed - go find entry button
                RecoveryStep  := 5
                GDetail.Value := "Recovery: looking for " BtnNames[1] "..."
            }

        case 4:
            ; Wait after scroll before scanning for start button
            if (now - RecoveryStepTime) < RecoveryWait
                return
            RecoveryStep  := 5
            GDetail.Value := "Recovery: looking for " BtnNames[1] "..."

        case 5:
            ; Find and click the entry/start button (throttled scan)
            if (now - RecoveryStepTime) < 500
                return
            if FindBtn(1, SavedImgTolerance) || FindBtnWide(1, SavedImgTolerance) {
                DoClick(BtnX[1], BtnY[1])
                LastBtnSeen    := now
                NeedsRecovery  := false
                DungeonInitDone := true
                Phase          := PH_BATTLE
                PhaseStartTime := now
                AttackMissRun  := 0
                NextAtk        := 1
                HealCounter    := 0
                RestCounter    := 0
                BattleCount++
                GDetail.Value  := "Recovery complete - entering battle"
                SendWebhook("Recovery complete - entering battle. Mode: " ModeNames[GameMode])
            } else {
                RecoveryStepTime := now
                GDetail.Value := "Recovery: searching for " BtnNames[1] "..."
            }
    }
}


; -- WORLD BOSS SCHEDULE: hourly WB side-trip during Story --
; Steps: -1=flee Story battle  0=click Go to WB  1=wait+click Enter Fight  2=attack until miss  3=restore Story

TickWorldBoss(now) {
    global

    GStatus.Value := "WB SCHEDULED"

    ; Global timeout: 60s for nav/entry (steps < 2), 120s including fight/return
    local wbTimeout := WBStep < 2 ? 60000 : 120000
    if (now - PhaseStartTime) > wbTimeout {
        ; Stuck or fight dragging — bail
        ; item 28: profile flag replaces GameMode != 1 (WB is only triggered from hasWBSchedule modes)
        if !ModeProfiles[GameMode].hasWBSchedule {
            SaveModeButtons()
            SwitchMode(1)
        }
        LastWBHour     := FormatTime(, "H") + 0
        Phase          := PH_IDLE
        PhaseStartTime := now
        AttackMissRun  := 0
        NextAtk        := 1
        SeqRevisit     := false
        CnfClearCount  := 0
        HealCounter    := 0
        RestCounter    := 0
        LastBattleEnd  := now
        LastBtnSeen    := now
        GDetail.Value  := "WB timed out - returning to Story"
        return
    }

    ; Throttle between steps
    if (now - WBStepTime) < 500
        return

    switch WBStep {
        case -1:
            ; Flee current Story battle before switching to WB
            ; Spam-click Flee 3-5 times at the known position to ensure it registers
            if FleeIdx > 0 && BtnX[FleeIdx] > 0 && BtnY[FleeIdx] > 0 {
                local fx := BtnX[FleeIdx], fy := BtnY[FleeIdx]
                Loop 4 {
                    RawClick(fx, fy)
                    Sleep(80)
                }
                LastBtnSeen := now
                GDetail.Value := "WB: Spam-clicked Flee x4"
            }
            ; Wait for the game to close the battle UI
            WBStep     := -2
            WBStepTime := now

        case -2:
            ; Wait after flee clicks, then switch to WB
            if (now - WBStepTime) < 1500
                return
            SaveModeButtons()
            SwitchMode(2)
            WBStep     := 0
            WBStepTime := now
            GDetail.Value := "WB: Battle exited - switching to World Boss"

        case 0:
            ; Click Go to WB tab
            if NavIdx > 0 && FindBtn(NavIdx, SavedImgTolerance) {
                DoClick(BtnX[NavIdx], BtnY[NavIdx])
                LastBtnSeen := now
                WBStep      := 1
                WBStepTime  := now
                GDetail.Value := "WB: Clicked " BtnNames[NavIdx]
            } else if NavIdx > 0 && FindBtnWide(NavIdx, SavedImgTolerance) {
                DoClick(BtnX[NavIdx], BtnY[NavIdx])
                LastBtnSeen := now
                WBStep      := 1
                WBStepTime  := now
                GDetail.Value := "WB: Clicked " BtnNames[NavIdx] " (wide)"
            } else {
                ; Tab not found - maybe already in WB menu
                WBStep     := 1
                WBStepTime := now
                GDetail.Value := "WB: Nav not found - looking for Enter Fight..."
            }

        case 1:
            ; Wait for menu to load, then click Enter Fight
            if (now - WBStepTime) < RecoveryWait
                return
            if FindBtn(1, SavedImgTolerance) {
                ClickAndVerify(1, SavedImgTolerance)
                LastBtnSeen    := now
                AttackMissRun  := 0
                NextAtk        := 1
                HealCounter    := 0
                LastAttackTime := now
                WBStep         := 2
                WBStepTime     := now
                BattleCount++
                GDetail.Value  := "WB: Entered fight"
            } else {
                ; Retry - go back to step 0
                WBStep     := 0
                WBStepTime := now
                GDetail.Value := "WB: Enter Fight not found - retrying nav..."
            }

        case 2:
            ; Attack round-robin (reuses WB AtkSlots/BtnNames already loaded)
            local visMap := [], anyVis := false, chosenIdx := 0, chosenSlot := 0
            for i, slot in AtkSlots {
                local vis := IsAtkEnabled(i) && FindBtn(slot, SavedImgTolerance)
                visMap.Push(vis)
                if vis
                    anyVis := true
            }

            if anyVis {
                AttackMissRun := 0
                LastBtnSeen   := now
                RecordDetection()

                ; Heal check
                if HealEnabled && HealIdx > 0 && HealCounter >= HealEvery {
                    if FindBtn(HealIdx, SavedImgTolerance) {
                        TryClickBtn(HealIdx, SavedImgTolerance)
                        HealCounter    := 0
                        LastAttackTime := now
                        GDetail.Value  := "WB: Healed"
                        return
                    }
                    GDetail.Value := "WB: Heal ready - btn not found"
                }

                ; Attack gap
                if (now - LastAttackTime) < AttackGap
                    return

                ; Pick next visible attack
                Loop AtkSlots.Length {
                    local s := Mod(NextAtk - 1 + A_Index - 1, AtkSlots.Length) + 1
                    if visMap[s] {
                        chosenIdx  := AtkSlots[s]
                        chosenSlot := s
                        break
                    }
                }
                if chosenIdx > 0 {
                    TryClickBtn(chosenIdx, SavedImgTolerance)
                    AttackClicks++
                    LastAttackTime := now
                    if HealIdx > 0
                        HealCounter++
                    NextAtk := Mod(chosenSlot, AtkSlots.Length) + 1
                    GDetail.Value := "WB: " BtnNames[chosenIdx] " (" AttackClicks " hits)"
                }
                return
            }

            ; No attack visible — grace period before counting misses
            ; (fight UI takes time to load after Enter Fight click)
            if (now - WBStepTime) < 3000 {
                GDetail.Value := "WB: Fight loading..."
                return
            }

            ; No attack visible
            AttackMissRun++
            ; WB fights are long - use 3x the normal miss threshold before concluding boss is dead
            local wbMissLimit := MissThreshold * 3
            if AttackMissRun >= wbMissLimit {
                ; Fight over - restore Story mode
                WBStep     := 3
                WBStepTime := now
            } else {
                GDetail.Value := "WB: Attack not found (" AttackMissRun "/" wbMissLimit ")"
            }

        case 3:
            ; Restore Story mode
            SaveModeButtons()
            SwitchMode(1)
            ; Click "Go to Story" tab to navigate back to the story screen
            if NavIdx > 0 && FindBtn(NavIdx, SavedImgTolerance) {
                DoClick(BtnX[NavIdx], BtnY[NavIdx])
                LastBtnSeen := now
            } else if NavIdx > 0 {
                ; Retry with wide scan
                if FindBtnWide(NavIdx, SavedImgTolerance) {
                    DoClick(BtnX[NavIdx], BtnY[NavIdx])
                    LastBtnSeen := now
                }
            }
            ; Update LastWBHour so we don't re-trigger if fight crossed hour boundary
            LastWBHour     := FormatTime(, "H") + 0
            Phase          := PH_IDLE
            PhaseStartTime := now
            AttackMissRun  := 0
            NextAtk        := 1
            SeqRevisit     := false
            CnfClearCount  := 0
            HealCounter    := 0
            LastBattleEnd  := now + 2000  ; extra 2s buffer for WB screen to fully transition
            LastBtnSeen    := now
            GDetail.Value  := "WB done - returning to Story/Prestige"
    }
}


; -- PRESTIGE: cooldown then reset (Story only) -----------

TickPrestige(now) {
    global

    GStatus.Value := "PRESTIGE WAIT"

    if (now - PhaseStartTime) >= PrestigeCooldown {
        PrestigeCount++
        if IsObject(gLog)
            gLog.Info("PRESTIGE", "#" PrestigeCount " completed")
        AttackMissRun  := 0
        NextAtk        := 1
        AttackClicks   := 0
        LastBattleEnd  := 0
        LastBtnSeen    := now
        LastPrestigeDone := now   ; start the re-entry grace window
        Phase          := PH_IDLE
        PhaseStartTime := now
        GDetail.Value  := "Prestige #" PrestigeCount " done - restarting"
        return
    }

    GDetail.Value := "Prestige processing..."
}


; =======================================================================
;             I M A G E   D E T E C T I O N
; =======================================================================

; Find a mode-specific button image near its saved coordinates
FindBtn(idx, tolOverride := 0, &outX := 0, &outY := 0) {
    global BtnX, BtnY, BtnOK, SavedImgTolerance, SearchRadius, ImgDir
    local tol, cx, cy, x1, y1, x2, y2, img, fX, fY
    if !BtnOK[idx]
        return false

    tol := tolOverride > 0 ? tolOverride : SavedImgTolerance
    cx  := BtnX[idx]
    cy  := BtnY[idx]
    x1  := Max(0, cx - SearchRadius)
    y1  := Max(0, cy - SearchRadius)
    x2  := Min(A_ScreenWidth, cx + SearchRadius)
    y2  := Min(A_ScreenHeight, cy + SearchRadius)
    img := ImgDir "\btn_" idx ".png"

    fX := 0
    fY := 0
    try {
        if !ImageSearch(&fX, &fY, x1, y1, x2, y2, "*" tol " " img)
            return false
        outX := fX
        outY := fY
        return true
    }
    catch as e {
        if IsObject(gLog)
            gLog.LogOnce(Logger.Level_WARN, "IMGSEARCH", "FindBtn[" idx "] error: " e.Message, "btn" idx)
        return false
    }
}

; Wide scan: search the entire game window for a button (slower, used for init/recovery)
FindBtnWide(idx, tolOverride := 0, &outX := 0, &outY := 0) {
    global BtnX, BtnY, BtnOK, SavedImgTolerance, ImgDir, CaptureSize
    local tol, gw, img, fX, fY
    if !BtnOK[idx]
        return false

    tol := tolOverride > 0 ? tolOverride : SavedImgTolerance
    gw  := GetGameWindow()
    img := ImgDir "\btn_" idx ".png"

    fX := 0
    fY := 0
    try {
        if !ImageSearch(&fX, &fY, gw.x, gw.y, gw.x + gw.w, gw.y + gw.h, "*" tol " " img)
            return false
        outX := fX
        outY := fY
        return true
    }
    catch as e {
        if IsObject(gLog)
            gLog.LogOnce(Logger.Level_WARN, "IMGSEARCH", "FindBtnWide[" idx "] error: " e.Message, "wide" idx)
        return false
    }
}

; Click a button by using the detected hit coordinates instead of saved X/Y.
; This keeps captured coordinates immutable while avoiding bad clicks if saved Y drifts.
TryClickBtn(idx, tolOverride := 0, useWide := false) {
    global BtnX, BtnY
    local fx := 0, fy := 0, ok := false
    if useWide
        ok := FindBtnWide(idx, tolOverride, &fx, &fy)
    else
        ok := FindBtn(idx, tolOverride, &fx, &fy)
    if ok {
        ; ImageSearch returns top-left corner of match; offset by half capture size to hit center
        local half := CaptureSize // 2
        DoClick(fx + half, fy + half)
        return true
    }
    ; Fallback if button flickered between detection and click attempt
    if idx > 0 && idx <= BtnX.Length && BtnX[idx] > 0 && BtnY[idx] > 0 {
        DoClick(BtnX[idx], BtnY[idx])
        return true
    }
    return false
}

; Find the universal Reconnect button image
FindRecon() {
    global ReconX, ReconY, ReconOK, SearchRadius, ReconImgPath
    local tol, cx, cy, x1, y1, x2, y2, fX, fY
    if !ReconOK
        return false

    tol := 20   ; fixed low tolerance - reconnect button is distinct, don't use adaptive
    cx  := ReconX
    cy  := ReconY
    x1  := Max(0, cx - SearchRadius)
    y1  := Max(0, cy - SearchRadius)
    x2  := Min(A_ScreenWidth, cx + SearchRadius)
    y2  := Min(A_ScreenHeight, cy + SearchRadius)

    fX := 0
    fY := 0
    try {
        if !ImageSearch(&fX, &fY, x1, y1, x2, y2, "*" tol " " ReconImgPath)
            return false
        ; Coordinates are locked at capture time — never update them
        return true
    }
    catch
        return false
}

; -- CNF Detection: horizontal strip scan with moving window --

FindCNF() {
    global CnfImgOK, CnfY, CnfBandH, CnfLastX, CnfBaseX, CnfScanHalfW, CnfTolerance, ImgDir, HasCNF
    local img, tol, fX, fY, y1, y2, x1, x2, gw, halfX
    if !HasCNF || !CnfImgOK
        return false

    img := ImgDir "\cnf.png"
    tol := CnfTolerance
    fX  := 0
    fY  := 0
    gw  := GetGameWindow()

    y1 := Max(0, CnfY - CnfBandH)
    y2 := CnfY + CnfBandH

    ; Restrict scan to the left half of the screen (player side)
    ; Enemy CNF appears on the right half and must be ignored
    halfX := gw.x + gw.w // 2
    local scanLeft  := gw.x
    local scanRight := halfX

    ; Narrow scan around last known X
    if CnfLastX > 0 {
        x1 := Max(scanLeft, CnfLastX - CnfScanHalfW)
        x2 := Min(scanRight, CnfLastX + CnfScanHalfW)
        try {
            if ImageSearch(&fX, &fY, x1, y1, x2, y2, "*" tol " " img) {
                CnfLastX := fX
                return true
            }
        } catch {
        }
    }

    ; Fallback: scan player's half only
    try {
        if ImageSearch(&fX, &fY, scanLeft, y1, scanRight, y2, "*" tol " " img) {
            CnfLastX := fX
            return true
        }
    }
    catch as e {
        if IsObject(gLog)
            gLog.LogOnce(Logger.Level_WARN, "IMGSEARCH", "FindCNF scan error: " e.Message, "cnf")
    }
    return false
}

; -- CONFUSED: REST loop until CNF clears -----------------

TickConfused(now) {
    global

    GStatus.Value := "CONFUSED"

    if FindCNF() {
        CnfClearCount := 0
        RecordDetection()

        if RestIdx > 0 && FindBtn(RestIdx, SavedImgTolerance) {
            DoClick(BtnX[RestIdx], BtnY[RestIdx])
            GDetail.Value := "Confused - clicking REST"
        } else {
            GDetail.Value := "Confused - searching REST..."
        }
        return
    }

    CnfClearCount++
    if CnfClearCount >= CnfClearThreshold {
        CnfClearCount  := 0
        Phase          := PreCnfPhase
        LastBtnSeen    := now
        if Phase != PH_BATTLE
            PhaseStartTime := now
        GStatus.Value  := "CNF CLEARED"
        GDetail.Value  := "Confusion gone - resuming " (Phase = PH_BATTLE ? "battle" : "idle")
        return
    }
    GDetail.Value := "CNF fading... (" CnfClearCount "/" CnfClearThreshold ")"
}


; =======================================================================
;          G D I +   S C R E E N   C A P T U R E
; =======================================================================

StartGdiplus() {
    global GdipToken, gLog, gValidator
    local si

    ; --- Load GDI+ (fail-fast: without it screen capture is impossible) ---
    local libHandle := DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
    if !libHandle
        throw Error("Failed to load gdiplus.dll - GDI+ is unavailable")

    si := Buffer(24, 0)
    NumPut("UInt", 1, si)
    try {
        DllCall("gdiplus\GdiplusStartup", "Ptr*", &GdipToken, "Ptr", si, "Ptr", 0)
    } catch as e {
        MsgBox("GDI+ initialization failed: " e.Message "`n`nScreen capture will not work.", "Fatal Error", "Icon! OK")
        ExitApp()
    }
    if !GdipToken {
        MsgBox("GDI+ returned a null token.  Screen capture unavailable.", "Fatal Error", "Icon! OK")
        ExitApp()
    }

    ; --- Initialize service singletons ---
    gLog        := Logger(A_ScriptDir "\jojo_debug.log")
    gValidator  := RuntimeValidator(gLog)
    gMacroState := MacroState()
    gDetectState := DetectionState()
    gServices   := RuntimeServices(gLog, gValidator, gMacroState, gDetectState)

    gLog.Info("STATE", "B.A.P starting  v" ScriptVersion)
}

GrabScreen(sx, sy, w, h, path) {
    local hDC, memDC, hBmp, oldBmp, pBmp, clsid
    hDC    := DllCall("GetDC", "Ptr", 0, "Ptr")
    memDC  := DllCall("CreateCompatibleDC", "Ptr", hDC, "Ptr")
    hBmp   := DllCall("CreateCompatibleBitmap", "Ptr", hDC, "Int", w, "Int", h, "Ptr")
    oldBmp := DllCall("SelectObject", "Ptr", memDC, "Ptr", hBmp, "Ptr")
    DllCall("BitBlt", "Ptr", memDC, "Int", 0, "Int", 0, "Int", w, "Int", h
        , "Ptr", hDC, "Int", sx, "Int", sy, "UInt", 0x00CC0020)
    DllCall("SelectObject", "Ptr", memDC, "Ptr", oldBmp)

    pBmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBmp, "Ptr", 0, "Ptr*", &pBmp)

    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBmp, "WStr", path, "Ptr", clsid, "Ptr", 0)

    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    DllCall("DeleteObject", "Ptr", hBmp)
    DllCall("DeleteDC", "Ptr", memDC)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hDC)
    if IsObject(gValidator) && !gValidator.ValidateCapture(path)
        if IsObject(gLog)
            gLog.Warn("GRAB", "GrabScreen may not have written: " path)
}

StopGdiplus() {
    global GdipToken
    if GdipToken
        DllCall("gdiplus\GdiplusShutdown", "Ptr", GdipToken)
    GdipToken := 0
}


; =======================================================================
;                      H E L P E R S
; =======================================================================

; Apply Windows dark mode to a GUI window so title bar renders dark
ApplyDarkMode(guiObj) {
    local hwnd := guiObj.Hwnd
    ; DWMWA_USE_IMMERSIVE_DARK_MODE = 20
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", hwnd, "Int", 20, "Int*", 1, "Int", 4)
}

; Create a colored button with a golden ring border (JoJo game style)
; Returns the clickable text control
ColorBtn(guiObj, x, y, w, h, label, bgColor, callback, fontSize := 10) {
    local bd := 2  ; border thickness
    ; Gold border ring (outer rect)
    guiObj.AddText("x" x " y" y " w" w " h" h " Background" C_GOLD, "")
    ; Inner fill (inset by border width)
    guiObj.AddText("x" (x + bd) " y" (y + bd) " w" (w - bd * 2) " h" (h - bd * 2) " Background" bgColor, "")
    ; Centered label in gold
    guiObj.SetFont("s" fontSize " c" C_GOLD " Bold", "Segoe UI")
    local txt := guiObj.AddText("x" x " y" y " w" w " h" h " Center BackgroundTrans +0x200", label)
    txt.OnEvent("Click", callback)
    return txt
}

; Activate Roblox so clicks are delivered to it rather than any overlapping window.
; Called at the start of DoClick while Critical is already Off.
EnsureRobloxFocus() {
    local hwnd
    hwnd := 0
    try hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
    if !hwnd
        try hwnd := WinExist("Roblox")
    if !hwnd
        return false
    try {
        if WinGetID("A") != hwnd {
            WinActivate(hwnd)
            Sleep(80)   ; brief settle after focus grab
        }
    }
    return true
}

; Click a button and confirm it disappeared (click accepted), retrying on failure.
; Designed for critical one-shot buttons: entry, prestige, reconnect.
; Returns true as soon as the button is undetectable after a click (state changed).
; Returns false if all retries are exhausted — callers should still act since
; at least one click was delivered.
ClickAndVerify(idx, tolOverride := 0, maxRetries := 3) {
    global CaptureSize, ClickVerifyWait
    local fX, fY, half
    half := CaptureSize // 2

    Loop maxRetries {
        fX := 0
        fY := 0
        if !FindBtn(idx, tolOverride, &fX, &fY)
            return true          ; button already gone — click was accepted
        DoClick(fX + half, fY + half)   ; ends with Critical "On"
        Critical "Off"                  ; release before sleep so timers aren't blocked
        Sleep(ClickVerifyWait)          ; let the UI respond before re-scanning
        Critical "On"
        if !FindBtn(idx, tolOverride)
            return true          ; button gone — click confirmed
        ; Still visible — pause briefly and retry
    }
    return false   ; button persisted through all attempts
}

DoClick(x, y) {
    global ClickCD, ClickHold, ClickMethod
    ; Release Critical before sleeping so queued ticks don't pile up
    Critical "Off"
    ; NOTE: do NOT activate Roblox here. Mouse clicks are delivered to the window
    ; under the cursor regardless of focus, so forcing WinActivate before every
    ; click only thrashes focus, adds latency, and makes Windows eat the click —
    ; that caused dropped clicks and prestige getting stuck. Keyboard/scroll paths
    ; still call EnsureRobloxFocus() themselves where focus genuinely matters.
    RawClick(x, y)
    if ClickCD > 0
        Sleep(ClickCD)
    ; Park mouse at top of game window and jiggle to shake off attached UI
    local gw := GetGameWindow()
    MouseMove(gw.cx, gw.y + 30)
    Sleep(15)
    MouseMove(gw.cx + 10, gw.y + 30)
    Sleep(15)
    MouseMove(gw.cx, gw.y + 30)
    Critical "On"
}

; Perform a single click using the chosen method, without park/jiggle/cooldown.
; Used by DoClick and burst-click loops (TickFleeing).
RawClick(x, y) {
    global ClickHold, ClickMethod
    if ClickMethod = 2 {
        ; Instant (SendInput) - atomic click, fast and hard to interrupt
        MouseMove(x, y)
        Sleep(40)
        SendInput("{Click " x " " y "}")
    } else if ClickMethod = 3 {
        ; Simple (Event) - lightweight instant click
        MouseMove(x, y)
        Sleep(40)
        Click(x " " y)
    } else {
        ; Held (default) - move, hover, press, hold, release
        MouseMove(x, y)
        Sleep(40)
        Click("Down")
        Sleep(ClickHold)
        Click("Up")
    }
}

; item 16: push-only — never blocks the Tick timer
SendWebhook(msg) {
    global WebhookURL, WebhookQueue
    if WebhookURL != ""
        WebhookQueue.Push(msg)
}

; item 16: dedicated drain timer — runs every 1 s independently of Tick
WebhookTick() {
    global WebhookURL, WebhookQueue
    local msg, payload, whr
    if WebhookURL = "" || WebhookQueue.Length = 0
        return
    msg := WebhookQueue.RemoveAt(1)   ; FIFO
    try {
        payload := '{"content":"' msg '"}'
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", WebhookURL, true)
        whr.SetRequestHeader("Content-Type", "application/json")
        whr.Send(payload)
        whr.WaitForResponse(5)   ; 5 s timeout — safe here since we are NOT inside Tick
    }
}

Bound(v, lo, hi) {
    return Max(lo, Min(v, hi))
}

; Safe integer parse — returns fallback on bad/corrupt INI values
SafeInt(val, fallback := 0) {
    try
        return Integer(val)
    catch
        return fallback
}

; Get the center and bounds of the Roblox game window (windowed mode).
; Returns an object {cx, cy, x, y, w, h} or falls back to screen center.
GetGameWindow() {
    local hwnd, wx, wy, ww, wh
    try {
        hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
        if !hwnd
            hwnd := WinExist("Roblox")
        if hwnd {
            WinGetPos(&wx, &wy, &ww, &wh, hwnd)
            return {cx: wx + ww // 2, cy: wy + wh // 2, x: wx, y: wy, w: ww, h: wh}
        }
    }
    ; Fallback: assume fullscreen
    return {cx: A_ScreenWidth // 2, cy: A_ScreenHeight // 2, x: 0, y: 0, w: A_ScreenWidth, h: A_ScreenHeight}
}

; Force Roblox out of fullscreen into windowed mode.
; If the window covers the entire screen, sends F11 to toggle.
ForceWindowed() {
    local hwnd, wx, wy, ww, wh
    try {
        hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
        if !hwnd
            hwnd := WinExist("Roblox")
        if !hwnd
            return
        WinGetPos(&wx, &wy, &ww, &wh, hwnd)
        ; If window covers entire screen, it's fullscreen
        if wx <= 0 && wy <= 0 && ww >= A_ScreenWidth && wh >= A_ScreenHeight {
            WinActivate(hwnd)
            Sleep(100)
            Send("{F11}")
            Sleep(500)
        }
    }
}

ClampSettings() {
    global
    ClickCD          := Bound(ClickCD, 0, 400)
    ClickHold        := Bound(ClickHold, 20, 500)
    ClickMethod      := Bound(ClickMethod, 1, 3)
    LoopMS           := Bound(LoopMS, 50, 500)
    ; item 32: clamp per-mode entry-wait directly in profiles — no global intermediary
    Loop 3 {
        ModeProfiles[A_Index].entryWait := Bound(ModeProfiles[A_Index].entryWait, 100, 3000)
    }
    AttackGap        := Bound(AttackGap, 50, 2000)
    PrestigeCooldown   := Bound(PrestigeCooldown, 500, 10000)
    MissThreshold      := Bound(MissThreshold, 2, 30)
    PostBattleDelay  := Bound(PostBattleDelay, 500, 5000)
    SearchRadius     := Bound(SearchRadius, 20, 400)
    SavedImgTolerance := Bound(SavedImgTolerance, 5, 100)
    CnfTolerance     := Bound(CnfTolerance, 80, 140)
    CnfBandH         := Bound(CnfBandH, 10, 100)
    CnfScanHalfW     := Bound(CnfScanHalfW, 50, 500)
    CnfClearThreshold := Bound(CnfClearThreshold, 1, 10)
    ScrollTicks      := Bound(ScrollTicks, 1, 30)
    RecoveryWait     := Bound(RecoveryWait, 500, 5000)
    HealEvery           := Bound(HealEvery, 1, 100)
    RestEvery           := Bound(RestEvery, 1, 100)
    InactivityThreshold := Bound(InactivityThreshold, 30000, 300000)
}

ShowFirstRunInvite() {
    global CfgFile
    local shown := IniRead(CfgFile, "General", "InviteShown", "0")
    if shown = "1"
        return
    local result := MsgBox(
        "Welcome to B.A.P!`n`nJoin the Discord server for updates, help, and announcements:`n`nhttps://discord.gg/xRyczQmWYm`n`nCopy the invite link to clipboard?",
        "B.A.P - Join the Discord",
        "YesNo Icon!"
    )
    if result = "Yes"
        A_Clipboard := "https://discord.gg/xRyczQmWYm"
    IniWrite("1", CfgFile, "General", "InviteShown")
}

UpdateCounters() {
    global
    GStats.Value := ModeStatsText()
    GPhaseIcon.Value := GetPhaseIcon()
    ; Log phase transitions
    if Phase != LastPhase && IsObject(gLog) {
        local _pn := ["IDLE","BATTLE","PRESTIGE","CONFUSED","FLEEING","RECOVERY","WORLDBOSS"]
        local _ph := (Phase >= 0 && Phase <= 6) ? _pn[Phase + 1] : "???"
        gLog.Info("PHASE", ModeNames[GameMode] " → " _ph)
        LastPhase := Phase
    }
    UpdateDebugOverlay()
}

UpdateDebugOverlay() {
    global gLog, GDebugLines
    if !GDebugLines.Length || !IsObject(gLog)
        return
    local recent := gLog.GetRecent(GDebugLines.Length)
    Loop GDebugLines.Length {
        local txt := A_Index <= recent.Length ? recent[A_Index] : ""
        if StrLen(txt) > 74
            txt := SubStr(txt, 1, 74) "..."
        GDebugLines[A_Index].Value := txt
    }
}

; Refresh the readiness grid on the main GUI with current button status
; item 25: DRY icon helper for ReadyGrid — resolves [+]/[~]/[-] from ok flag + file check
ReadyIconFor(okFlag, filePath) {
    if okFlag && FileExist(filePath)
        return "[+]"
    if okFlag
        return "[~]"
    return "[-]"
}

RefreshReadyGrid() {
    global
    local idx, icon
    if !GReadyGrid.Length
        return
    idx := 1
    ; Mode buttons
    Loop BtnNames.Length {
        icon := ReadyIconFor(BtnOK[A_Index], ImgDir "\btn_" A_Index ".png")
        if idx <= GReadyGrid.Length
            GReadyGrid[idx].Value := icon "  " BtnNames[A_Index]
        idx++
    }
    ; CNF
    if HasCNF {
        icon := ReadyIconFor(CnfImgOK, ImgDir "\cnf.png")
        if idx <= GReadyGrid.Length
            GReadyGrid[idx].Value := icon "  CNF Icon"
        idx++
    }
    ; Reconnect
    icon := ReadyIconFor(ReconOK, ReconImgPath)
    if idx <= GReadyGrid.Length
        GReadyGrid[idx].Value := icon "  Reconnect"
    idx++
    ; Blank remaining slots (mode switch may leave stale text)
    while idx <= GReadyGrid.Length {
        GReadyGrid[idx].Value := ""
        idx++
    }
}

; Items 13/14/30: centralized entry-wait setter — writes current profile entryWait only.
; SaveConfig now reads from ModeProfiles[n].entryWait directly (item 29), so no global sync needed.
SetEntryWait(v) {
    global GameMode, ModeProfiles
    ModeProfiles[GameMode].entryWait := v
}

; =======================================================================
;               S E T T I N G S   H A N D L E R S
; =======================================================================

SaveSettings(*) {
    global
    if !IsObject(settingsGui) || !settingsGui.Hwnd {
        MsgBox("Settings window is no longer open.", "Error", "Icon!")
        return
    }
    ; SafeInt(..., current) keeps the existing value if a field is left blank
    ; (Number edits allow empty input — raw Integer("") would throw on Save).
    ClickCD         := SafeInt(EClickCD.Value, ClickCD)
    ClickHold       := SafeInt(EClickHold.Value, ClickHold)
    ClickMethod     := DDClickMethod.Value
    LoopMS          := SafeInt(ELoopMS.Value, LoopMS)
    AttackGap       := SafeInt(EAttackGap.Value, AttackGap)
    MissThreshold   := SafeInt(EMissThresh.Value, MissThreshold)
    PostBattleDelay := SafeInt(EPostBattle.Value, PostBattleDelay)
    SearchRadius    := SafeInt(ESearchR.Value, SearchRadius)
    SavedImgTolerance := SafeInt(EImgTol.Value, SavedImgTolerance)

    ; Attack toggles (all modes)
    AtkEnabled1 := CAtk1.Value
    AtkEnabled2 := CAtk2.Value
    AtkEnabled3 := CAtk3.Value
    AtkEnabled4 := CAtk4.Value

    ; item 19: entry-wait + shared heal reads outside branches; profile flags for extras
    local prof19 := ModeProfiles[GameMode]
    SetEntryWait(SafeInt(EEntryWait.Value, GetEntryWait()))
    HealEvery   := SafeInt(EDungHealEvery.Value, HealEvery)
    HealEnabled := CDungHeal.Value
    if prof19.hasPrestigeCooldown {
        PrestigeCooldown  := SafeInt(EPrestigeCD.Value, PrestigeCooldown)
        WBScheduleEnabled := CWBSchedule.Value
    }
    if prof19.hasRestSettings {
        ScrollTicks := SafeInt(EScrollT.Value, ScrollTicks)
        RestEvery   := SafeInt(ERestEvery.Value, RestEvery)
        RestEnabled := CRestEnabled.Value
    }

    WebhookURL          := Trim(EWebhook.Value)
    InactivityThreshold := Bound(SafeInt(EInactivityThresh.Value, InactivityThreshold // 1000) * 1000, 30000, 300000)
    PrivateServerURL    := Trim(EPrivateSvrURL.Value)

    ClampSettings()

    ; Push clamped values back to UI
    EClickCD.Value    := ClickCD
    EClickHold.Value  := ClickHold
    DDClickMethod.Value := ClickMethod
    ELoopMS.Value     := LoopMS
    EEntryWait.Value  := GetEntryWait()
    EAttackGap.Value  := AttackGap
    CAtk1.Value := AtkEnabled1
    CAtk2.Value := AtkEnabled2
    CAtk3.Value := AtkEnabled3
    CAtk4.Value := AtkEnabled4
    if ModeProfiles[GameMode].hasPrestigeCooldown {
        EPrestigeCD.Value := PrestigeCooldown
        CWBSchedule.Value := WBScheduleEnabled
    }
    EMissThresh.Value := MissThreshold
    EPostBattle.Value := PostBattleDelay
    ESearchR.Value    := SearchRadius
    EImgTol.Value           := SavedImgTolerance
    EInactivityThresh.Value := InactivityThreshold // 1000
    EDungHealEvery.Value    := HealEvery
    CDungHeal.Value         := HealEnabled
    if ModeProfiles[GameMode].hasRestSettings {
        EScrollT.Value     := ScrollTicks
        ERestEvery.Value   := RestEvery
        CRestEnabled.Value := RestEnabled
    }

    SaveConfig()
    if Running
        SetTimer(Tick, LoopMS)
    MsgBox("Settings saved.", "OK", "Icon!")
    CloseSettings()
}

ResetDefaults(*) {
    global
    EClickCD.Value    := "120"
    EClickHold.Value  := "60"
    DDClickMethod.Value := 1
    ELoopMS.Value     := "100"
    EEntryWait.Value  := "600"
    EAttackGap.Value  := "150"
    EMissThresh.Value := "8"
    EPostBattle.Value := "2500"
    ESearchR.Value    := "120"
    EImgTol.Value     := "30"
    CAtk1.Value := 1
    CAtk2.Value := 1
    CAtk3.Value := 1
    CAtk4.Value := 1
    if ModeProfiles[GameMode].hasPrestigeCooldown {
        EPrestigeCD.Value := "2500"
        CWBSchedule.Value := 0
    }
    if ModeProfiles[GameMode].hasRestSettings {
        EScrollT.Value      := "5"
        ERestEvery.Value    := "5"
        CRestEnabled.Value  := 1
    }
    EDungHealEvery.Value    := "15"
    CDungHeal.Value         := 1
    EInactivityThresh.Value := "60"
    MsgBox("Defaults restored - click Save to apply.", "Reset", "Icon!")
}


; =======================================================================
;                    C O N F I G   I / O
; =======================================================================

LoadConfig() {
    global
    if !FileExist(CfgFile) {
        SwitchMode(1)
        return
    }

    ; Migration check — log if config was written by an older version
    local savedVer := IniRead(CfgFile, "General", "CfgVersion", "")
    if IsObject(gLog) {
        if savedVer = ""
            gLog.Warn("CONFIG", "No CfgVersion found — loading legacy config")
        else if savedVer != ScriptVersion
            gLog.Info("CONFIG", "Config version " savedVer " loaded by script " ScriptVersion)
    }

    ; General
    GameMode := SafeInt(IniRead(CfgFile, "General", "GameMode", 1), 1)
    if GameMode < 1 || GameMode > ModeNames.Length
        GameMode := 1

    ; Shared timers
    ClickCD          := SafeInt(IniRead(CfgFile, "Timers", "ClickCD",          ClickCD), ClickCD)
    ClickHold        := SafeInt(IniRead(CfgFile, "Timers", "ClickHold",        ClickHold), ClickHold)
    ClickMethod      := SafeInt(IniRead(CfgFile, "Timers", "ClickMethod",      ClickMethod), ClickMethod)
    LoopMS           := SafeInt(IniRead(CfgFile, "Timers", "LoopMS",           LoopMS), LoopMS)
    ; item 31: read per-mode entry-wait directly into profiles (no global intermediary)
    ModeProfiles[1].entryWait := SafeInt(IniRead(CfgFile, "Timers", "StoryWait",   ModeProfiles[1].entryWait), ModeProfiles[1].entryWait)
    ModeProfiles[2].entryWait := SafeInt(IniRead(CfgFile, "Timers", "FightWait",   ModeProfiles[2].entryWait), ModeProfiles[2].entryWait)
    ModeProfiles[3].entryWait := SafeInt(IniRead(CfgFile, "Timers", "DungeonWait", ModeProfiles[3].entryWait), ModeProfiles[3].entryWait)
    AttackGap        := SafeInt(IniRead(CfgFile, "Timers", "AttackGap",        AttackGap), AttackGap)
    PrestigeCooldown   := SafeInt(IniRead(CfgFile, "Timers", "PrestigeCooldown", PrestigeCooldown), PrestigeCooldown)
    MissThreshold      := SafeInt(IniRead(CfgFile, "Timers", "MissThreshold",    MissThreshold), MissThreshold)
    PostBattleDelay  := SafeInt(IniRead(CfgFile, "Timers", "PostBattleDelay",  PostBattleDelay), PostBattleDelay)
    SearchRadius     := SafeInt(IniRead(CfgFile, "Timers", "SearchRadius",     SearchRadius), SearchRadius)
    SavedImgTolerance := SafeInt(IniRead(CfgFile, "Timers", "ImgTolerance",   SavedImgTolerance), SavedImgTolerance)
    ScrollTicks      := SafeInt(IniRead(CfgFile, "Timers", "ScrollTicks",      ScrollTicks), ScrollTicks)
    RecoveryWait   := SafeInt(IniRead(CfgFile, "Timers", "RecoveryWait",   RecoveryWait), RecoveryWait)
    HealEnabled    := SafeInt(IniRead(CfgFile, "Timers", "HealEnabled",    HealEnabled), HealEnabled)
    HealEvery      := SafeInt(IniRead(CfgFile, "Timers", "HealEvery",      HealEvery), HealEvery)
    RestEnabled    := SafeInt(IniRead(CfgFile, "Timers", "RestEnabled",    RestEnabled), RestEnabled)
    RestEvery      := SafeInt(IniRead(CfgFile, "Timers", "RestEvery",      RestEvery), RestEvery)
    WBScheduleEnabled := SafeInt(IniRead(CfgFile, "Timers", "WBScheduleEnabled", WBScheduleEnabled), WBScheduleEnabled)

    ; Attack toggles
    AtkEnabled1 := SafeInt(IniRead(CfgFile, "Attacks", "AtkEnabled1", AtkEnabled1), AtkEnabled1)
    AtkEnabled2 := SafeInt(IniRead(CfgFile, "Attacks", "AtkEnabled2", AtkEnabled2), AtkEnabled2)
    AtkEnabled3 := SafeInt(IniRead(CfgFile, "Attacks", "AtkEnabled3", AtkEnabled3), AtkEnabled3)
    AtkEnabled4 := SafeInt(IniRead(CfgFile, "Attacks", "AtkEnabled4", AtkEnabled4), AtkEnabled4)

    ; Universal Reconnect
    ReconX  := SafeInt(IniRead(CfgFile, "Reconnect", "ReconX",  0), 0)
    ReconY  := SafeInt(IniRead(CfgFile, "Reconnect", "ReconY",  0), 0)
    ReconOK := SafeInt(IniRead(CfgFile, "Reconnect", "ReconOK", 0), 0)

    ; Discord Webhook
    WebhookURL := IniRead(CfgFile, "General", "WebhookURL", "")

    ; Rejoin Failsafe
    InactivityThreshold := SafeInt(IniRead(CfgFile, "General", "InactivityThreshold", 60000), 60000)
    PrivateServerURL    := IniRead(CfgFile, "General", "PrivateServerURL", "")

    ; Switch to loaded mode (this loads mode-specific buttons via LoadModeButtons)
    SwitchMode(GameMode)
    ClampSettings()
    ; item 31/32: entryWait is now read directly into profiles in LoadConfig and clamped in ClampSettings
    ; no post-ClampSettings sync needed
    ; Sync DetectionState from globals now that config + buttons are loaded
    if IsObject(gDetectState)
        gDetectState.SyncFromGlobals()
}

; Load button data for the current mode from config
LoadModeButtons() {
    global
    local modeKey, btnSec, cnfSec, testVal, n, oldCnfOK, prof
    if !FileExist(CfgFile)
        return

    modeKey := ModeNames[GameMode]
    btnSec  := modeKey "_Buttons"
    cnfSec  := modeKey "_CNF"
    prof    := ModeProfiles[GameMode]

    ; item 17: profile-driven legacy section fallback — no hardcoded if GameMode = 1/2
    if prof.legacyBtnSection != "" {
        testVal := IniRead(CfgFile, btnSec, BtnNames[1] "_X", "NONE")
        if testVal = "NONE" {
            btnSec := prof.legacyBtnSection
            cnfSec := prof.legacyCnfSection
        }
        ; Also fall back CNF: if new section has no data but old section does
        if HasCNF && SafeInt(IniRead(CfgFile, cnfSec, "CnfImgOK", 0), 0) = 0 {
            oldCnfOK := SafeInt(IniRead(CfgFile, prof.legacyCnfSection, "CnfImgOK", 0), 0)
            if oldCnfOK
                cnfSec := prof.legacyCnfSection
        }
    }

    Loop BtnNames.Length {
        n := BtnNames[A_Index]
        BtnX[A_Index]  := SafeInt(IniRead(CfgFile, btnSec, n "_X",  0), 0)
        BtnY[A_Index]  := SafeInt(IniRead(CfgFile, btnSec, n "_Y",  0), 0)
        BtnOK[A_Index] := SafeInt(IniRead(CfgFile, btnSec, n "_OK", 0), 0)
    }

    if HasCNF {
        CnfY              := SafeInt(IniRead(CfgFile, cnfSec, "CnfY",              0), 0)
        CnfImgOK          := SafeInt(IniRead(CfgFile, cnfSec, "CnfImgOK",          0), 0)
        CnfBaseX          := SafeInt(IniRead(CfgFile, cnfSec, "CnfBaseX",          0), 0)
        CnfLastX          := CnfBaseX
        CnfTolerance      := SafeInt(IniRead(CfgFile, cnfSec, "CnfTolerance",      CnfTolerance), CnfTolerance)
        CnfBandH          := SafeInt(IniRead(CfgFile, cnfSec, "CnfBandH",          CnfBandH), CnfBandH)
        CnfScanHalfW      := SafeInt(IniRead(CfgFile, cnfSec, "CnfScanHalfW",      CnfScanHalfW), CnfScanHalfW)
        CnfClearThreshold := SafeInt(IniRead(CfgFile, cnfSec, "CnfClearThreshold", CnfClearThreshold), CnfClearThreshold)
    }
}

SaveConfig() {
    global

    ; Version stamp for future migration detection
    IniWrite(ScriptVersion, CfgFile, "General", "CfgVersion")

    ; General
    IniWrite(GameMode, CfgFile, "General", "GameMode")

    ; Shared timers
    IniWrite(ClickCD,          CfgFile, "Timers", "ClickCD")
    IniWrite(ClickHold,        CfgFile, "Timers", "ClickHold")
    IniWrite(ClickMethod,      CfgFile, "Timers", "ClickMethod")
    IniWrite(LoopMS,           CfgFile, "Timers", "LoopMS")
    ; item 29: write from profile entryWait (always clamped, always current — see ClampSettings item 24)
    IniWrite(ModeProfiles[1].entryWait, CfgFile, "Timers", "StoryWait")
    IniWrite(ModeProfiles[2].entryWait, CfgFile, "Timers", "FightWait")
    IniWrite(ModeProfiles[3].entryWait, CfgFile, "Timers", "DungeonWait")
    IniWrite(AttackGap,        CfgFile, "Timers", "AttackGap")
    IniWrite(PrestigeCooldown,   CfgFile, "Timers", "PrestigeCooldown")
    IniWrite(MissThreshold,      CfgFile, "Timers", "MissThreshold")
    IniWrite(PostBattleDelay,  CfgFile, "Timers", "PostBattleDelay")
    IniWrite(SearchRadius,     CfgFile, "Timers", "SearchRadius")
    IniWrite(SavedImgTolerance, CfgFile, "Timers", "ImgTolerance")
    IniWrite(ScrollTicks,        CfgFile, "Timers", "ScrollTicks")
    IniWrite(RecoveryWait,   CfgFile, "Timers", "RecoveryWait")
    IniWrite(HealEnabled,    CfgFile, "Timers", "HealEnabled")
    IniWrite(HealEvery,      CfgFile, "Timers", "HealEvery")
    IniWrite(RestEnabled,    CfgFile, "Timers", "RestEnabled")
    IniWrite(RestEvery,      CfgFile, "Timers", "RestEvery")
    IniWrite(WBScheduleEnabled, CfgFile, "Timers", "WBScheduleEnabled")

    ; Attack toggles
    IniWrite(AtkEnabled1, CfgFile, "Attacks", "AtkEnabled1")
    IniWrite(AtkEnabled2, CfgFile, "Attacks", "AtkEnabled2")
    IniWrite(AtkEnabled3, CfgFile, "Attacks", "AtkEnabled3")
    IniWrite(AtkEnabled4, CfgFile, "Attacks", "AtkEnabled4")

    ; Universal Reconnect
    IniWrite(ReconX,  CfgFile, "Reconnect", "ReconX")
    IniWrite(ReconY,  CfgFile, "Reconnect", "ReconY")
    IniWrite(ReconOK, CfgFile, "Reconnect", "ReconOK")

    ; Discord Webhook & Rejoin Failsafe
    IniWrite(WebhookURL,          CfgFile, "General", "WebhookURL")
    IniWrite(InactivityThreshold, CfgFile, "General", "InactivityThreshold")
    IniWrite(PrivateServerURL,    CfgFile, "General", "PrivateServerURL")

    ; Per-mode button data
    SaveModeButtons()
}

; Save button data for the current mode to config
SaveModeButtons() {
    global
    local modeKey, btnSec, cnfSec, n
    modeKey := ModeNames[GameMode]
    btnSec  := modeKey "_Buttons"
    cnfSec  := modeKey "_CNF"

    Loop BtnNames.Length {
        n := BtnNames[A_Index]
        IniWrite(BtnX[A_Index],  CfgFile, btnSec, n "_X")
        IniWrite(BtnY[A_Index],  CfgFile, btnSec, n "_Y")
        IniWrite(BtnOK[A_Index], CfgFile, btnSec, n "_OK")
    }

    if HasCNF {
        IniWrite(CnfY,              CfgFile, cnfSec, "CnfY")
        IniWrite(CnfImgOK,          CfgFile, cnfSec, "CnfImgOK")
        IniWrite(CnfBaseX,          CfgFile, cnfSec, "CnfBaseX")
        IniWrite(CnfTolerance,      CfgFile, cnfSec, "CnfTolerance")
        IniWrite(CnfBandH,          CfgFile, cnfSec, "CnfBandH")
        IniWrite(CnfScanHalfW,      CfgFile, cnfSec, "CnfScanHalfW")
        IniWrite(CnfClearThreshold, CfgFile, cnfSec, "CnfClearThreshold")
    }
}


; =======================================================================
;                  A U T O - U P D A T E R
; =======================================================================

CheckForUpdate() {
    global ScriptVersion, UpdateURL
    local whr, remoteVer, result, scriptUrl, tmpPath, dlWhr, fObj

    ; Fetch remote version.txt (single line, e.g. "1.0.1")
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", UpdateURL "version.txt", true)
        whr.Send()
        whr.WaitForResponse(5)  ; 5-second timeout
        if whr.Status != 200
            return
        remoteVer := Trim(whr.ResponseText, " `t`r`n")
    } catch {
        return  ; network error — silently skip
    }

    ; Compare versions (simple string compare — works for semver if same format)
    if remoteVer = "" || remoteVer = ScriptVersion
        return

    ; Newer version available — ask user
    result := MsgBox(
        "A new version of B.A.P is available!`n`n"
        "Current:  v" ScriptVersion "`n"
        "New:       v" remoteVer "`n`n"
        "Download and apply the update?`n"
        "(The macro will restart after updating)",
        "B.A.P - Update Available",
        "YesNo Icon!"
    )
    if result != "Yes"
        return

    ; Download the new script to a temp file
    try {
        scriptUrl := UpdateURL "jojo_auto.ahk"
        tmpPath   := A_ScriptDir "\jojo_auto_update.tmp"

        dlWhr := ComObject("WinHttp.WinHttpRequest.5.1")
        dlWhr.Open("GET", scriptUrl, true)
        dlWhr.Send()
        dlWhr.WaitForResponse(15)  ; 15-second timeout for larger file
        if dlWhr.Status != 200 {
            MsgBox("Download failed (HTTP " dlWhr.Status "). Try again later.", "Update Error", "Icon!")
            return
        }

        ; Write downloaded content to temp file
        fObj := FileOpen(tmpPath, "w", "UTF-8")
        fObj.Write(dlWhr.ResponseText)
        fObj.Close()

        ; Replace current script with downloaded version
        FileMove(tmpPath, A_ScriptFullPath, 1)  ; overwrite

        MsgBox("Update applied! The macro will now restart.", "B.A.P - Updated", "Icon!")
        Reload()
    } catch as e {
        try FileDelete(A_ScriptDir "\jojo_auto_update.tmp")
        MsgBox("Update failed: " e.Message "`n`nYou can update manually from Discord.", "Update Error", "Icon!")
    }
}

; =======================================================================
;               I N A C T I V I T Y   F A I L S A F E
; =======================================================================

; Reset inactivity timer and retry flag on any confirmed game-UI detection.
; Called in every branch where a button, CNF, or flee icon is confirmed visible.
RecordDetection() {
    global LastAnyDetection, RejoinRetryDone
    LastAnyDetection := A_TickCount
    RejoinRetryDone  := false
}

; Return true when the inactivity failsafe should be suppressed.
; Prevents false triggers during expected quiet periods.
InactivityExempt(now) {
    global Phase, PH_PRESTIGE, PH_RECOVERY, PH_WORLDBOSS
    global PostBattleDelay, LastBattleEnd
    global NeedsScroll, DungeonInitDone
    global LastRejoinTime, RejoinGracePeriod
    if Phase = PH_PRESTIGE || Phase = PH_RECOVERY || Phase = PH_WORLDBOSS
        return true
    if LastBattleEnd > 0 && (now - LastBattleEnd) < PostBattleDelay
        return true
    if NeedsScroll && !DungeonInitDone   ; item 20: use profile global, not if GameMode = 3
        return true
    if LastRejoinTime > 0 && (now - LastRejoinTime) < RejoinGracePeriod
        return true
    return false
}

; Full reset of all macro state to a clean startup condition.
; Called just before launching a rejoin so the macro restarts fresh.
ResetToClean() {
    global
    ; Delegate to MacroState for a single canonical reset path
    if IsObject(gMacroState) {
        gMacroState.ResetClean()
    } else {
        Phase               := PH_IDLE
        PhaseStartTime      := A_TickCount
        BattleCount         := 0
        AttackClicks        := 0
        RunCount            := 0
        PrestigeCount       := 0
        AttackMissRun       := 0
        FleeMissRun         := 0
        NextAtk             := 1
        SeqRevisit          := false
        LastAttackTime      := 0
        LastBattleEnd       := 0
        LastBtnSeen         := A_TickCount
        HealCounter         := 0
        RestCounter         := 0
        LastReconnectClick  := 0
        NeedsRecovery       := false
        RecoveryStep        := 0
        DungeonInitDone     := false
        DungeonInitStep     := 0
        DungeonInitStepTime := 0
        DungeonInitRetries  := 0
        CnfClearCount       := 0
        WBStep              := 0
        WBStepTime          := 0
    }
    LastAnyDetection    := A_TickCount
    LastRejoinTime      := A_TickCount   ; activates RejoinGracePeriod
    RejoinRetryDone     := false
    RejoinRetryTime     := 0
    GStats.Value        := ModeStatsText()
}

; Parse a roblox.com private-server URL and return a roblox:// deep link.
; Accepts either a full roblox.com URL or an existing roblox:// URI.
; Returns "" if the input cannot be resolved to a valid join link.
BuildRejoinURL(rawURL) {
    local placeId, linkCode, pos1, pos2, paramPos, endPos, qi
    if rawURL = ""
        return ""
    ; Already a roblox:// deep link — use as-is
    if SubStr(rawURL, 1, 9) = "roblox://"
        return rawURL
    placeId  := ""
    linkCode := ""
    ; Extract placeId from path: /games/PLACEID/...
    pos1 := InStr(rawURL, "/games/")
    if pos1 {
        pos1 += 7
        pos2 := InStr(rawURL, "/", false, pos1)
        if pos2 > pos1
            placeId := SubStr(rawURL, pos1, pos2 - pos1)
        else
            placeId := SubStr(rawURL, pos1)
        qi := InStr(placeId, "?")
        if qi
            placeId := SubStr(placeId, 1, qi - 1)
        placeId := Trim(placeId, " `t`r`n")
    }
    ; Extract privateServerLinkCode query parameter
    paramPos := InStr(rawURL, "privateServerLinkCode=")
    if paramPos {
        paramPos += 22
        endPos := InStr(rawURL, "&", false, paramPos)
        if endPos
            linkCode := SubStr(rawURL, paramPos, endPos - paramPos)
        else
            linkCode := SubStr(rawURL, paramPos)
        linkCode := Trim(linkCode, " `t`r`n")
    }
    if placeId != "" && linkCode != ""
        return "roblox://experiences/start?placeId=" placeId "&linkCode=" linkCode
    ; Fallback: return the raw URL (browser → Roblox handoff)
    if InStr(rawURL, "roblox.com")
        return rawURL
    return ""
}

; Locate RobloxPlayerLauncher.exe by checking known install paths.
; Returns the full path, or "" if not found.
FindRobloxLauncher() {
    local candidates, localAppData, p
    localAppData := EnvGet("LOCALAPPDATA")
    candidates := [
        localAppData "\Roblox\Versions\RobloxPlayerLauncher.exe",
        localAppData "\Roblox\RobloxPlayerLauncher.exe",
        "C:\Program Files (x86)\Roblox\Versions\RobloxPlayerLauncher.exe",
        "C:\Program Files\Roblox\Versions\RobloxPlayerLauncher.exe"
    ]
    ; Also search LocalAppData\Roblox\Versions\* for any versioned folder
    try {
        Loop Files, localAppData "\Roblox\Versions\*", "D" {
            candidates.Push(A_LoopFilePath "\RobloxPlayerLauncher.exe")
        }
    }
    for p in candidates {
        if FileExist(p)
            return p
    }
    return ""
}

; Kill all Roblox-related processes and wait for them to fully exit.
KillRoblox() {
    local procs, p, deadline
    procs := ["RobloxPlayerBeta.exe", "RobloxPlayerLauncher.exe",
              "RobloxCrashHandler.exe", "RobloxStudioBeta.exe"]
    ; Soft kill first
    for p in procs
        try ProcessClose(p)
    Sleep(1500)
    ; Hard kill any survivors
    try Run('taskkill /F /IM RobloxPlayerBeta.exe /IM RobloxPlayerLauncher.exe /IM RobloxCrashHandler.exe', , "Hide")
    ; Wait up to 5 s for process to actually be gone
    deadline := A_TickCount + 5000
    while ProcessExist("RobloxPlayerBeta.exe") && A_TickCount < deadline
        Sleep(300)
}

; Wait up to `timeoutMs` for Roblox to create a visible, non-minimized window.
; Checks both the game process and an actual window handle to avoid false positives
; from the launcher process briefly appearing and then handing off.
; Returns true if confirmed up, false on timeout.
WaitForRobloxWindow(timeoutMs := 40000) {
    local deadline, hwnd
    deadline := A_TickCount + timeoutMs
    while A_TickCount < deadline {
        hwnd := 0
        try hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
        ; Confirm the window exists AND is not minimized (launcher stub can be iconic)
        if hwnd && !DllCall("IsIconic", "Ptr", hwnd)
            return true
        Sleep(1000)
    }
    return false
}

; Execute the private-server rejoin using a verified, multi-method retry sequence.
; Up to 2 full attempts, each trying 3 launch methods in order:
;   Method 1 — cmd /c start (Windows URI registry handler, works ~90% of installs)
;   Method 2 — explorer.exe (alternative URI dispatch, works where cmd fails)
;   Method 3 — direct RobloxPlayerLauncher.exe with URL argument (deepest fallback)
; Each attempt kills Roblox first and verifies the process actually launched.
DoRejoin() {
    global PrivateServerURL, ModeNames, GameMode, Running, LoopMS
    global gServices, ImgDir, BtnNames, HasCNF
    local url, launcherPath, appeared, attempt, methodLabel

    ; item 5 (Phase 2.3): warn if required images are missing before rejoining
    if IsObject(gServices)
        gServices.ValidateMode(ImgDir, BtnNames, HasCNF)

    url := BuildRejoinURL(PrivateServerURL)
    if url = "" {
        GStatus.Value := "STUCK"
        GDetail.Value := "Rejoin aborted: no valid private server URL (configure in Settings)"
        ResetToClean()
        return
    }

    GStatus.Value := "REJOINING"
    GDetail.Value := "Rejoin: preparing..."
    ResetToClean()

    Critical "Off"
    SetTimer(Tick, 0)   ; stop tick timer — this function blocks for up to ~60 s total

    appeared := false

    Loop 2 {
        attempt := A_Index
        GDetail.Value := "Rejoin " attempt "/2: killing Roblox..."
        KillRoblox()   ; always kill before each attempt

        ; ------ Method 1: cmd /c start ------
        GDetail.Value := "Rejoin " attempt "/2: trying URI handler (cmd start)..."
        try Run('cmd.exe /c start "" "' url '"', , "Hide")
        appeared := WaitForRobloxWindow(15000)
        if appeared {
            methodLabel := "cmd start"
            break
        }

        ; ------ Method 2: explorer.exe ------
        GDetail.Value := "Rejoin " attempt "/2: trying explorer.exe..."
        try Run('explorer.exe "' url '"', , "Hide")
        appeared := WaitForRobloxWindow(10000)
        if appeared {
            methodLabel := "explorer"
            break
        }

        ; ------ Method 3: direct launcher ------
        GDetail.Value := "Rejoin " attempt "/2: trying direct launcher..."
        launcherPath := FindRobloxLauncher()
        if launcherPath != "" {
            try Run('"' launcherPath '" "' url '"', , "Hide")
            appeared := WaitForRobloxWindow(20000)
            if appeared {
                methodLabel := "launcher"
                break
            }
        }

        ; All 3 methods failed — pause before attempt 2
        if attempt = 1 {
            GDetail.Value := "Rejoin 1/2: all methods failed, retrying in 3s..."
            Sleep(3000)
        }
    }

    if appeared {
        GStatus.Value := "IDLE"
        GDetail.Value := "Rejoin OK via " methodLabel " - forcing windowed mode..."
        Sleep(2000)   ; let Roblox finish rendering before sending F11
        ForceWindowed()
        GDetail.Value := "Rejoin OK via " methodLabel " - waiting for game to load..."
    } else {
        GStatus.Value := "STUCK"
        GDetail.Value := "Rejoin FAILED after 2 attempts (check URL / Roblox install)"
    }

    if Running
        SetTimer(Tick, LoopMS)

    SendWebhook("Rejoin " (appeared ? "OK via " methodLabel : "FAILED after 2 attempts")
        ". Mode: " ModeNames[GameMode])
}

; =======================================================================

Quit(*) {
    if IsObject(gLog) {
        gLog.Info("MACRO", "Script exiting")
        gLog.Flush()
    }
    SaveConfig()
    StopGdiplus()
    ExitApp()
}
