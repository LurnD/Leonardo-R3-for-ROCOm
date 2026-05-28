#Requires AutoHotkey v2.0
#SingleInstance Force

if !A_IsAdmin {
    try Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    ExitApp()
}

global CONFIG_FILE := A_ScriptDir "\roco_single_flower.ini"
global MAX_LOG_LINES := 30
global SEND_MODES := ["后台 (PostMessage)", "前台 (激活窗口+真实按键)"]
global app := CreateAppState()

DetectHiddenWindows true
SetKeyDelay 50, 50

InitializeApp()

^=::ToggleLoop()

CreateAppState() {
    settings := LoadSettings()
    return {
        settings: settings,
        isRunning: false,
        mainGui: 0,
        controls: {},
        gameWindowHwnds: [],
        currentHwnd: 0
    }
}

InitializeApp() {
    BuildGui()
    SetStatus("状态：空闲（按 Ctrl+= 开始/停止）")
    AddLog("窗口已打开，全局热键：Ctrl+=")
    RefreshGameWindows(false)
}

GetDefaultSettings() {
    return {
        targetExe: "NRC-Win64-Shipping.exe",
        prefixKeys: "13456",
        loopSequence: "Tab,2,Esc,R,X",
        loopMin: 0,
        loopMax: 0,
        keyDelayMs: 350,
        afkChance: 3,
        restChance: 5,
        alwaysOnTop: 0,
        sendMode: 1
    }
}

LoadSettings() {
    defaults := GetDefaultSettings()
    candidate := {
        targetExe: defaults.targetExe,
        prefixKeys: IniRead(CONFIG_FILE, "Settings", "PrefixKeys", defaults.prefixKeys),
        loopSequence: IniRead(CONFIG_FILE, "Settings", "LoopSequence", defaults.loopSequence),
        loopMin: IniRead(CONFIG_FILE, "Settings", "LoopMin", defaults.loopMin),
        loopMax: IniRead(CONFIG_FILE, "Settings", "LoopMax", defaults.loopMax),
        keyDelayMs: IniRead(CONFIG_FILE, "Settings", "KeyDelayMs", defaults.keyDelayMs),
        afkChance: IniRead(CONFIG_FILE, "Settings", "AfkChance", defaults.afkChance),
        restChance: IniRead(CONFIG_FILE, "Settings", "RestChance", defaults.restChance),
        alwaysOnTop: IniRead(CONFIG_FILE, "Settings", "AlwaysOnTop", defaults.alwaysOnTop),
        sendMode: IniRead(CONFIG_FILE, "Settings", "SendMode", defaults.sendMode)
    }

    try {
        return ValidateSettings(candidate)
    } catch {
        return ValidateSettings(defaults)
    }
}

SaveSettings(settings) {
    IniWrite(settings.prefixKeys, CONFIG_FILE, "Settings", "PrefixKeys")
    IniWrite(settings.loopSequence, CONFIG_FILE, "Settings", "LoopSequence")
    IniWrite(settings.loopMin, CONFIG_FILE, "Settings", "LoopMin")
    IniWrite(settings.loopMax, CONFIG_FILE, "Settings", "LoopMax")
    IniWrite(settings.keyDelayMs, CONFIG_FILE, "Settings", "KeyDelayMs")
    IniWrite(settings.afkChance, CONFIG_FILE, "Settings", "AfkChance")
    IniWrite(settings.restChance, CONFIG_FILE, "Settings", "RestChance")
    IniWrite(settings.alwaysOnTop, CONFIG_FILE, "Settings", "AlwaysOnTop")
    IniWrite(settings.sendMode, CONFIG_FILE, "Settings", "SendMode")
}

BuildGui() {
    global app

    guiObj := Gui(app.settings.alwaysOnTop ? "+AlwaysOnTop" : "", "洛克王国循环助手 (Ctrl+= 启停)")
    guiObj.SetFont("s10", "Microsoft YaHei UI")

    controls := {}
    controls.statusText := guiObj.Add("Text", "xm w540", "状态：空闲")

    guiObj.Add("Text", "xm y+10 w70", "目标窗口：")
    controls.windowSelect := guiObj.Add("DropDownList", "x+10 yp-3 w310", ["请先刷新窗口列表"])
    controls.windowSelect.OnEvent("Change", OnWindowChanged)
    guiObj.Add("Button", "x+10 yp-1 w70 h26", "刷新").OnEvent("Click", RefreshGameWindowsClick)

    guiObj.Add("Text", "xm y+14 w95", "前置按键序列：")
    controls.prefixEdit := guiObj.Add("Edit", "x+8 yp-3 w360", app.settings.prefixKeys)

    guiObj.Add("Text", "xm y+14 w95", "循环按键序列：")
    controls.sequenceEdit := guiObj.Add("Edit", "x+8 yp-3 w360", app.settings.loopSequence)

    guiObj.Add("Text", "xm y+14 w150", "循环次数最小(0=无限)：")
    controls.loopMinEdit := guiObj.Add("Edit", "x+8 yp-3 w60 Number", app.settings.loopMin)

    guiObj.Add("Text", "x+18 yp+3 w150", "循环次数最大(0=无限)：")
    controls.loopMaxEdit := guiObj.Add("Edit", "x+8 yp-3 w60 Number", app.settings.loopMax)

    guiObj.Add("Text", "xm y+14 w110", "按键延迟(ms)：")
    controls.keyDelayEdit := guiObj.Add("Edit", "x+8 yp-3 w70 Number", app.settings.keyDelayMs)

    guiObj.Add("Text", "x+18 yp+3 w90", "走神概率%：")
    controls.afkChanceEdit := guiObj.Add("Edit", "x+8 yp-3 w50 Number", app.settings.afkChance)

    guiObj.Add("Text", "x+10 yp+3 w90", "喘息概率%：")
    controls.restChanceEdit := guiObj.Add("Edit", "x+8 yp-3 w50 Number", app.settings.restChance)

    guiObj.Add("Text", "xm y+14 w90", "发送模式：")
    controls.sendModeSelect := guiObj.Add("DropDownList", "x+8 yp-3 w260 Choose" app.settings.sendMode, SEND_MODES)

    guiObj.Add("Button", "xm y+16 w130 h30", "开始/停止 (Ctrl+=)").OnEvent("Click", ToggleLoop)
    guiObj.Add("Button", "x+10 w110 h30", "发送按键测试").OnEvent("Click", ManualSend)
    guiObj.Add("Button", "x+10 w110 h30", "初始化(↓×10)").OnEvent("Click", RunInitialization)
    guiObj.Add("Button", "x+10 w80 h30", "退出").OnEvent("Click", HandleExitClick)
    controls.alwaysOnTopCheck := guiObj.Add("Checkbox", "x+15 yp+8 Checked" app.settings.alwaysOnTop, "窗口置顶")
    controls.alwaysOnTopCheck.OnEvent("Click", OnAlwaysOnTopToggle)

    controls.logEdit := guiObj.Add("Edit", "xm y+10 w540 r12 ReadOnly -Wrap", "")

    app.mainGui := guiObj
    app.controls := controls
    UpdateSettingsUi(app.settings)
    guiObj.OnEvent("Close", HandleAppClose)
    guiObj.Show()
}

HandleExitClick(*) {
    HandleAppClose()
}

HandleAppClose(*) {
    if app.isRunning
        app.isRunning := false

    SaveSettingsIfValid()
    ExitApp()
}

ToggleLoop(*) {
    if app.isRunning {
        StopLoop("已手动停止")
        return
    }
    StartLoop()
}

StartLoop() {
    settings := ApplySettingsFromUi()
    if !settings
        return

    hwnd := FindSelectedGameWindow()
    if !hwnd
        return

    app.isRunning := true
    app.currentHwnd := hwnd
    SetStatus("状态：循环已启动")
    AddLog("开始循环，窗口 hwnd=" hwnd "，发送=" SEND_MODES[settings.sendMode])
    SetTimer RunMainLoop, -1
}

StopLoop(reason) {
    app.isRunning := false
    SetStatus("状态：" reason)
    AddLog(reason)
}

RunMainLoop() {
    while app.isRunning {
        hwnd := app.currentHwnd
        if !hwnd || !WinExist("ahk_id " hwnd) {
            StopLoop("游戏窗口丢失，循环停止")
            return
        }

        if !RunPrefixSequence(hwnd)
            return

        SetStatus("状态：发送主键 2")
        if !SendKeyByName(hwnd, "2", 180, 240)
            return
        if !SafeSleep(3800, 4200)
            return
        AddLog("主键 2 完成，进入内循环")

        if IsInfiniteLoop(app.settings) {
            SetStatus("状态：执行内循环（无限）")
            AddLog("内循环：无限")
            Loop {
                if !app.isRunning
                    return
                if !RunInnerCycle(hwnd, A_Index, 0)
                    return
            }
        } else {
            loopCount := Random(app.settings.loopMin, app.settings.loopMax)
            SetStatus("状态：执行内循环 " loopCount " 次")
            AddLog("内循环：" loopCount " 次")
            Loop loopCount {
                if !app.isRunning
                    return
                if !RunInnerCycle(hwnd, A_Index, loopCount)
                    return
            }
        }

        if !RestPause()
            return
    }
}

IsInfiniteLoop(settings) {
    return settings.loopMin = 0 || settings.loopMax = 0
}

RunPrefixSequence(hwnd) {
    keys := app.settings.prefixKeys
    AddLog("前置序列开始：" keys "（每个数字后跟一次左键点击）")
    Loop Parse, keys {
        if !app.isRunning
            return false
        ch := A_LoopField
        SetStatus("状态：前置按键 " ch)
        if !SendKeyByName(hwnd, ch, 80, 120)
            return false
        if !SafeSleep(450, 550)
            return false

        if !app.isRunning
            return false
        SetStatus("状态：前置左键 " ch)
        if !SendClickAtCenter(hwnd, 80, 120)
            return false
        if !SafeSleep(450, 550)
            return false
    }
    AddLog("前置序列完成，准备发送主键 2")
    return true
}

RunInnerCycle(hwnd, index, total) {
    if Random(1, 100) <= app.settings.afkChance {
        SetStatus("状态：模拟走神中")
        AddLog("走神：插入随机长延迟")
        if !SafeSleep(10000, 20000)
            return false
    }

    parts := StrSplit(app.settings.loopSequence, ",")
    for _, key in parts {
        if !app.isRunning
            return false
        keyName := Trim(key)
        if keyName = ""
            continue

        sleepRange := GetKeySleepRange(keyName)
        presses := GetMultiPressCount(keyName)
        holdRange := GetKeyHoldRange(keyName)

        totalText := total = 0 ? "∞" : total
        SetStatus("状态：内循环 " index "/" totalText " - 发送 " keyName)
        Loop presses {
            if !app.isRunning
                return false
            if !SendKeyByName(hwnd, keyName, holdRange.min, holdRange.max)
                return false
            if A_Index < presses
                if !SafeSleep(150, 300)
                    return false
        }
        if !SafeSleep(sleepRange.min, sleepRange.max)
            return false
    }
    return true
}

GetKeySleepRange(keyName) {
    switch StrUpper(keyName) {
        case "TAB":
            return { min: 900, max: 1100 }
        case "2":
            return { min: 3800, max: 4200 }
        case "ESC", "ESCAPE":
            return { min: 450, max: 550 }
        case "R":
            return { min: 9500, max: 10500 }
        case "X":
            return { min: 40, max: 60 }
        default:
            return { min: 500, max: 700 }
    }
}

GetMultiPressCount(keyName) {
    upper := StrUpper(keyName)
    if upper = "R" || upper = "X" {
        roll := Random(1, 100)
        if roll <= 15
            return 2
        else if roll <= 20
            return 3
    }
    return 1
}

GetKeyHoldRange(keyName) {
    if RegExMatch(keyName, "^\d$")
        return { min: 180, max: 240 }
    return { min: 80, max: 120 }
}

RestPause() {
    if Random(1, 100) <= app.settings.restChance {
        SetStatus("状态：短暂休息")
        AddLog("喘息：随机停顿 5-10 秒")
        return SafeSleep(5000, 10000)
    }
    return SafeSleep(800, 1200)
}

SafeSleep(minTime, maxTime) {
    targetTime := Random(minTime, maxTime)
    if targetTime <= 50 {
        Sleep targetTime
        return app.isRunning
    }
    ticks := Round(targetTime / 50)
    Loop ticks {
        if !app.isRunning
            return false
        Sleep 50
    }
    return true
}

ManualSend(*) {
    settings := ApplySettingsFromUi()
    if !settings
        return

    hwnd := FindSelectedGameWindow()
    if !hwnd
        return

    AddLog("测试：发送一次循环按键序列")
    parts := StrSplit(settings.loopSequence, ",")
    for _, key in parts {
        keyName := Trim(key)
        if keyName = ""
            continue
        holdRange := GetKeyHoldRange(keyName)
        SendKeyByName(hwnd, keyName, holdRange.min, holdRange.max)
    }
    SetStatus("状态：测试发送完成")
    AddLog("测试发送完成")
}

RunInitialization(*) {
    if app.isRunning {
        SetStatus("状态：循环中，请先停止后再初始化")
        AddLog("初始化失败：当前正在循环")
        return
    }

    settings := ApplySettingsFromUi()
    if !settings
        return

    hwnd := FindSelectedGameWindow()
    if !hwnd
        return

    AddLog("初始化：连续按 10 次下箭头（发送=" SEND_MODES[settings.sendMode] "）")
    Loop 10 {
        SetStatus("状态：初始化中 " A_Index "/10")
        if !SendKeyByName(hwnd, "Down", 80, 120) {
            SetStatus("状态：初始化中断")
            AddLog("初始化中断")
            return
        }
        Sleep 200
    }
    SetStatus("状态：初始化完成，可按 Ctrl+= 启动")
    AddLog("初始化完成，可按 Ctrl+= 启动循环")
}

ApplySettingsFromUi() {
    try {
        settings := ValidateSettings(ReadSettingsFromUi())
    } catch as err {
        SetStatus("状态：配置无效")
        AddLog("配置无效：" err.Message)
        return 0
    }

    app.settings := settings
    UpdateSettingsUi(settings)
    SaveSettings(settings)
    return settings
}

SaveSettingsIfValid() {
    if !HasUiControls()
        return

    try {
        settings := ValidateSettings(ReadSettingsFromUi())
        SaveSettings(settings)
    } catch {
    }
}

ReadSettingsFromUi() {
    if !HasUiControls()
        return app.settings

    return {
        targetExe: app.settings.targetExe,
        prefixKeys: app.controls.prefixEdit.Value,
        loopSequence: app.controls.sequenceEdit.Value,
        loopMin: app.controls.loopMinEdit.Value,
        loopMax: app.controls.loopMaxEdit.Value,
        keyDelayMs: app.controls.keyDelayEdit.Value,
        afkChance: app.controls.afkChanceEdit.Value,
        restChance: app.controls.restChanceEdit.Value,
        alwaysOnTop: HasUiControls() && app.controls.HasOwnProp("alwaysOnTopCheck") ? app.controls.alwaysOnTopCheck.Value : app.settings.alwaysOnTop,
        sendMode: app.controls.HasOwnProp("sendModeSelect") ? app.controls.sendModeSelect.Value : app.settings.sendMode
    }
}

ValidateSettings(settings) {
    prefixKeys := Trim(settings.prefixKeys . "")
    if prefixKeys = ""
        throw Error("前置按键不能为空")

    loopSequence := Trim(settings.loopSequence . "")
    if loopSequence = ""
        throw Error("循环按键序列不能为空")

    loopMin := ParseNonNegativeInteger(settings.loopMin, "循环次数最小值")
    loopMax := ParseNonNegativeInteger(settings.loopMax, "循环次数最大值")
    if loopMin > 0 && loopMax > 0 && loopMin > loopMax
        throw Error("循环次数最小不能大于最大")

    keyDelayMs := ParsePositiveInteger(settings.keyDelayMs, "按键延迟")
    afkChance := ParseChance(settings.afkChance, "走神概率")
    restChance := ParseChance(settings.restChance, "喘息概率")
    alwaysOnTop := (settings.alwaysOnTop + 0) ? 1 : 0

    sendMode := ParsePositiveInteger(settings.sendMode, "发送模式")
    if sendMode < 1 || sendMode > 2
        throw Error("发送模式无效")

    return {
        targetExe: settings.targetExe,
        prefixKeys: prefixKeys,
        loopSequence: loopSequence,
        loopMin: loopMin,
        loopMax: loopMax,
        keyDelayMs: keyDelayMs,
        afkChance: afkChance,
        restChance: restChance,
        alwaysOnTop: alwaysOnTop,
        sendMode: sendMode
    }
}

ParsePositiveInteger(value, fieldName) {
    text := Trim(value . "")
    if text = ""
        throw Error(fieldName "不能为空")
    if !RegExMatch(text, "^\d+$")
        throw Error(fieldName "必须是正整数")

    number := text + 0
    if number <= 0
        throw Error(fieldName "必须大于 0")
    return number
}

ParseNonNegativeInteger(value, fieldName) {
    text := Trim(value . "")
    if text = ""
        throw Error(fieldName "不能为空")
    if !RegExMatch(text, "^\d+$")
        throw Error(fieldName "必须是非负整数")
    return text + 0
}

ParseChance(value, fieldName) {
    text := Trim(value . "")
    if text = ""
        throw Error(fieldName "不能为空")
    if !RegExMatch(text, "^\d+$")
        throw Error(fieldName "必须是 0-100 的整数")
    number := text + 0
    if number < 0 || number > 100
        throw Error(fieldName "必须在 0-100 之间")
    return number
}

UpdateSettingsUi(settings) {
    if !HasUiControls()
        return

    app.controls.prefixEdit.Value := settings.prefixKeys
    app.controls.sequenceEdit.Value := settings.loopSequence
    app.controls.loopMinEdit.Value := settings.loopMin
    app.controls.loopMaxEdit.Value := settings.loopMax
    app.controls.keyDelayEdit.Value := settings.keyDelayMs
    app.controls.afkChanceEdit.Value := settings.afkChance
    app.controls.restChanceEdit.Value := settings.restChance
    if app.controls.HasOwnProp("alwaysOnTopCheck")
        app.controls.alwaysOnTopCheck.Value := settings.alwaysOnTop
    if app.controls.HasOwnProp("sendModeSelect")
        app.controls.sendModeSelect.Value := settings.sendMode
}

HasUiControls() {
    return IsObject(app.controls) && app.controls.HasOwnProp("prefixEdit")
}

RefreshGameWindowsClick(*) {
    RefreshGameWindowsCore(true)
}

RefreshGameWindows(showLog := true) {
    RefreshGameWindowsCore(showLog)
}

RefreshGameWindowsCore(showLog := true) {
    oldIndex := HasUiControls() ? app.controls.windowSelect.Value : 0
    oldHwnd := (oldIndex >= 1 && oldIndex <= app.gameWindowHwnds.Length) ? app.gameWindowHwnds[oldIndex] : 0
    hwnds := WinGetList("ahk_exe " app.settings.targetExe)
    items := []
    app.gameWindowHwnds := []

    for hwnd in hwnds {
        title := WinGetTitle("ahk_id " hwnd)
        if title = ""
            title := "无标题窗口"
        items.Push(title " | hwnd:" hwnd)
        app.gameWindowHwnds.Push(hwnd)
    }

    app.controls.windowSelect.Delete()

    if items.Length = 0 {
        app.controls.windowSelect.Add(["未找到游戏窗口"])
        app.controls.windowSelect.Choose(1)
        if showLog {
            SetStatus("状态：未找到游戏窗口")
            AddLog("刷新完成，未找到游戏窗口")
        }
        return
    }

    app.controls.windowSelect.Add(items)
    newIndex := 1
    if oldHwnd {
        for index, hwnd in app.gameWindowHwnds {
            if hwnd = oldHwnd {
                newIndex := index
                break
            }
        }
    }

    app.controls.windowSelect.Choose(newIndex)
    if showLog {
        SetStatus("状态：已刷新窗口列表，共 " items.Length " 个")
        AddLog("刷新完成，找到 " items.Length " 个游戏窗口")
    }
}

FindSelectedGameWindow(showLog := true) {
    if !ProcessExist(app.settings.targetExe) {
        if showLog {
            SetStatus("状态：未检测到游戏进程")
            AddLog("未找到游戏进程：" app.settings.targetExe)
        }
        return 0
    }

    if app.gameWindowHwnds.Length = 0
        RefreshGameWindowsCore(false)

    hwnd := GetSelectedWindowHwnd()
    if hwnd && WinExist("ahk_id " hwnd)
        return hwnd

    RefreshGameWindowsCore(false)
    hwnd := GetSelectedWindowHwnd()
    if !hwnd && showLog {
        SetStatus("状态：未找到可用游戏窗口")
        AddLog("未找到可用游戏窗口，请点击刷新")
    }
    return hwnd
}

GetSelectedWindowHwnd() {
    index := app.controls.windowSelect.Value
    return (index >= 1 && index <= app.gameWindowHwnds.Length) ? app.gameWindowHwnds[index] : 0
}

OnWindowChanged(*) {
    index := app.controls.windowSelect.Value
    if index >= 1 && index <= app.gameWindowHwnds.Length
        AddLog("已选择窗口：" app.controls.windowSelect.Text)
}

OnAlwaysOnTopToggle(*) {
    state := app.controls.alwaysOnTopCheck.Value
    app.settings.alwaysOnTop := state
    app.mainGui.Opt(state ? "+AlwaysOnTop" : "-AlwaysOnTop")
    SaveSettings(app.settings)
    AddLog("窗口置顶：" (state ? "开启" : "关闭"))
}

SendKeyByName(hwnd, keyName, holdMin, holdMax) {
    if app.settings.sendMode = 2
        return SendKeyForeground(hwnd, keyName, holdMin, holdMax)
    return SendKeyBackground(hwnd, keyName, holdMin, holdMax)
}

SendKeyBackground(hwnd, keyName, holdMin, holdMax) {
    try {
        vk := GetKeyVK(keyName)
        sc := GetKeySC(keyName)
        if !vk || !sc {
            AddLog("无法识别按键：" keyName)
            return false
        }

        SendKeyEvent(hwnd, vk, sc, true)
        Sleep Random(holdMin, holdMax)
        SendKeyEvent(hwnd, vk, sc, false)
        Sleep app.settings.keyDelayMs
        return true
    } catch as err {
        AddLog("后台按键报错：" err.Message)
        return false
    }
}

SendKeyForeground(hwnd, keyName, holdMin, holdMax) {
    try {
        if !WinActive("ahk_id " hwnd) {
            WinActivate "ahk_id " hwnd
            if !WinWaitActive("ahk_id " hwnd, , 1) {
                AddLog("前台按键失败：窗口激活超时")
                return false
            }
            Sleep 30
        }

        Send "{" keyName " down}"
        Sleep Random(holdMin, holdMax)
        Send "{" keyName " up}"
        Sleep app.settings.keyDelayMs
        return true
    } catch as err {
        AddLog("前台按键报错：" err.Message)
        return false
    }
}

SendClickAtCenter(hwnd, holdMin, holdMax) {
    if app.settings.sendMode = 2
        return SendClickForeground(hwnd, holdMin, holdMax)
    return SendClickBackground(hwnd, holdMin, holdMax)
}

SendClickBackground(hwnd, holdMin, holdMax) {
    try {
        WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
        targetX := Round(cw / 2)
        targetY := Round(ch / 2)
        ControlClick("X" targetX " Y" targetY, "ahk_id " hwnd, , "Left", 1, "NA D")
        Sleep Random(holdMin, holdMax)
        ControlClick("X" targetX " Y" targetY, "ahk_id " hwnd, , "Left", 1, "NA U")
        return true
    } catch as err {
        AddLog("后台点击报错：" err.Message)
        return false
    }
}

SendClickForeground(hwnd, holdMin, holdMax) {
    try {
        if !WinActive("ahk_id " hwnd) {
            WinActivate "ahk_id " hwnd
            if !WinWaitActive("ahk_id " hwnd, , 1) {
                AddLog("前台点击失败：窗口激活超时")
                return false
            }
            Sleep 30
        }
        WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
        screenX := cx + Round(cw / 2)
        screenY := cy + Round(ch / 2)
        MouseClick "Left", screenX, screenY, 1, 0, "D"
        Sleep Random(holdMin, holdMax)
        MouseClick "Left", screenX, screenY, 1, 0, "U"
        return true
    } catch as err {
        AddLog("前台点击报错：" err.Message)
        return false
    }
}

SendKeyEvent(hwnd, vk, sc, isKeyDown) {
    message := isKeyDown ? 0x0100 : 0x0101
    lParam := BuildKeyLParam(sc, !isKeyDown)
    PostMessage message, vk, lParam, , "ahk_id " hwnd
}

BuildKeyLParam(sc, isKeyUp := false) {
    lParam := 1 | (sc << 16)
    if isKeyUp
        lParam |= 0xC0000000
    return lParam
}

SetStatus(text) {
    if HasUiControls()
        app.controls.statusText.Value := text
}

AddLog(text) {
    if !HasUiControls()
        return

    timeText := FormatTime(, "HH:mm:ss")
    line := "[" timeText "] " text
    lines := StrSplit(app.controls.logEdit.Value, "`r`n")
    filteredLines := []

    for _, existingLine in lines {
        if existingLine != ""
            filteredLines.Push(existingLine)
    }

    filteredLines.Push(line)
    while filteredLines.Length > MAX_LOG_LINES
        filteredLines.RemoveAt(1)

    app.controls.logEdit.Value := JoinParts(filteredLines, "`r`n")
    if filteredLines.Length > 0
        app.controls.logEdit.Value .= "`r`n"
}

JoinParts(parts, separator) {
    result := ""
    for index, part in parts {
        if index > 1
            result .= separator
        result .= part
    }
    return result
}
