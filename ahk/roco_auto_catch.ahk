#Requires AutoHotkey v2.0
#SingleInstance Force

if !A_IsAdmin {
    try Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    ExitApp()
}

global CONFIG_FILE := A_ScriptDir "\roco_auto_catch.ini"
global MAX_LOG_LINES := 30
global CLICK_MODES := ["窗口客户区中心", "自定义坐标", "跟随鼠标位置"]
global SEND_MODES := ["后台 (PostMessage)", "前台 (激活窗口+真实点击)"]
global app := CreateAppState()

DetectHiddenWindows true
SetKeyDelay 50, 50
CoordMode "Mouse", "Screen"

InitializeApp()

^-::ToggleLoop()

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
    SetStatus("状态：空闲（按 Ctrl+- 开始/停止）")
    AddLog("窗口已打开，全局热键：Ctrl+-")
    RefreshGameWindows(false)
}

GetDefaultSettings() {
    return {
        targetExe: "NRC-Win64-Shipping.exe",
        intervalMinMs: 800,
        intervalMaxMs: 1200,
        holdMinMs: 30,
        holdMaxMs: 60,
        clickMode: 1,
        customX: 0,
        customY: 0,
        sendMode: 1,
        alwaysOnTop: 0
    }
}

LoadSettings() {
    defaults := GetDefaultSettings()
    candidate := {
        targetExe: defaults.targetExe,
        intervalMinMs: IniRead(CONFIG_FILE, "Settings", "IntervalMinMs", defaults.intervalMinMs),
        intervalMaxMs: IniRead(CONFIG_FILE, "Settings", "IntervalMaxMs", defaults.intervalMaxMs),
        holdMinMs: IniRead(CONFIG_FILE, "Settings", "HoldMinMs", defaults.holdMinMs),
        holdMaxMs: IniRead(CONFIG_FILE, "Settings", "HoldMaxMs", defaults.holdMaxMs),
        clickMode: IniRead(CONFIG_FILE, "Settings", "ClickMode", defaults.clickMode),
        customX: IniRead(CONFIG_FILE, "Settings", "CustomX", defaults.customX),
        customY: IniRead(CONFIG_FILE, "Settings", "CustomY", defaults.customY),
        sendMode: IniRead(CONFIG_FILE, "Settings", "SendMode", defaults.sendMode),
        alwaysOnTop: IniRead(CONFIG_FILE, "Settings", "AlwaysOnTop", defaults.alwaysOnTop)
    }

    try {
        return ValidateSettings(candidate)
    } catch {
        return ValidateSettings(defaults)
    }
}

SaveSettings(settings) {
    IniWrite(settings.intervalMinMs, CONFIG_FILE, "Settings", "IntervalMinMs")
    IniWrite(settings.intervalMaxMs, CONFIG_FILE, "Settings", "IntervalMaxMs")
    IniWrite(settings.holdMinMs, CONFIG_FILE, "Settings", "HoldMinMs")
    IniWrite(settings.holdMaxMs, CONFIG_FILE, "Settings", "HoldMaxMs")
    IniWrite(settings.clickMode, CONFIG_FILE, "Settings", "ClickMode")
    IniWrite(settings.customX, CONFIG_FILE, "Settings", "CustomX")
    IniWrite(settings.customY, CONFIG_FILE, "Settings", "CustomY")
    IniWrite(settings.sendMode, CONFIG_FILE, "Settings", "SendMode")
    IniWrite(settings.alwaysOnTop, CONFIG_FILE, "Settings", "AlwaysOnTop")
}

BuildGui() {
    global app

    guiObj := Gui(app.settings.alwaysOnTop ? "+AlwaysOnTop" : "", "洛克王国自动抓取 (Ctrl+- 启停)")
    guiObj.SetFont("s10", "Microsoft YaHei UI")

    controls := {}
    controls.statusText := guiObj.Add("Text", "xm w470", "状态：空闲")

    guiObj.Add("Text", "xm y+10 w70", "目标窗口：")
    controls.windowSelect := guiObj.Add("DropDownList", "x+10 yp-3 w310", ["请先刷新窗口列表"])
    controls.windowSelect.OnEvent("Change", OnWindowChanged)
    guiObj.Add("Button", "x+10 yp-1 w70 h26", "刷新").OnEvent("Click", RefreshGameWindowsClick)

    guiObj.Add("Text", "xm y+14 w130", "点击间隔最小(ms)：")
    controls.intervalMinEdit := guiObj.Add("Edit", "x+8 yp-3 w70 Number", app.settings.intervalMinMs)

    guiObj.Add("Text", "x+18 yp+3 w130", "点击间隔最大(ms)：")
    controls.intervalMaxEdit := guiObj.Add("Edit", "x+8 yp-3 w70 Number", app.settings.intervalMaxMs)

    guiObj.Add("Text", "xm y+14 w130", "按键停留最小(ms)：")
    controls.holdMinEdit := guiObj.Add("Edit", "x+8 yp-3 w70 Number", app.settings.holdMinMs)

    guiObj.Add("Text", "x+18 yp+3 w130", "按键停留最大(ms)：")
    controls.holdMaxEdit := guiObj.Add("Edit", "x+8 yp-3 w70 Number", app.settings.holdMaxMs)

    guiObj.Add("Text", "xm y+14 w90", "发送模式：")
    controls.sendModeSelect := guiObj.Add("DropDownList", "x+8 yp-3 w240 Choose" app.settings.sendMode, SEND_MODES)

    guiObj.Add("Text", "xm y+14 w90", "点击位置：")
    controls.clickModeSelect := guiObj.Add("DropDownList", "x+8 yp-3 w180 Choose" app.settings.clickMode, CLICK_MODES)

    guiObj.Add("Text", "xm y+14 w90", "自定义 X：")
    controls.customXEdit := guiObj.Add("Edit", "x+8 yp-3 w70", app.settings.customX)

    guiObj.Add("Text", "x+18 yp+3 w90", "自定义 Y：")
    controls.customYEdit := guiObj.Add("Edit", "x+8 yp-3 w70", app.settings.customY)

    guiObj.Add("Button", "x+18 yp-1 w130 h26", "记录当前鼠标").OnEvent("Click", CaptureMousePos)

    guiObj.Add("Button", "xm y+16 w140 h30", "开始/停止 (Ctrl+-)").OnEvent("Click", ToggleLoop)
    guiObj.Add("Button", "x+10 w120 h30", "测试单击").OnEvent("Click", ManualClick)
    guiObj.Add("Button", "x+10 w100 h30", "退出").OnEvent("Click", HandleExitClick)
    controls.alwaysOnTopCheck := guiObj.Add("Checkbox", "x+15 yp+8 Checked" app.settings.alwaysOnTop, "窗口置顶")
    controls.alwaysOnTopCheck.OnEvent("Click", OnAlwaysOnTopToggle)

    controls.logEdit := guiObj.Add("Edit", "xm y+10 w470 r12 ReadOnly -Wrap", "")

    app.mainGui := guiObj
    app.controls := controls
    UpdateSettingsUi(app.settings)
    guiObj.OnEvent("Close", HandleAppClose)
    guiObj.Show()
}

CaptureMousePos(*) {
    hwnd := FindSelectedGameWindow(false)
    if !hwnd {
        SetStatus("状态：请先选择有效窗口再记录")
        AddLog("记录失败：无可用目标窗口")
        return
    }

    MouseGetPos &mx, &my
    try {
        WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
    } catch as err {
        AddLog("记录失败：" err.Message)
        return
    }
    relX := mx - cx
    relY := my - cy

    if !HasUiControls()
        return
    app.controls.customXEdit.Value := relX
    app.controls.customYEdit.Value := relY
    app.controls.clickModeSelect.Value := 2
    AddLog("已记录鼠标位置（窗口客户区相对坐标）：(" relX ", " relY ")，并切换到自定义坐标模式")
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
    SetStatus("状态：循环点击中")
    AddLog("开始循环，hwnd=" hwnd "，发送=" SEND_MODES[settings.sendMode] "，位置=" CLICK_MODES[settings.clickMode])
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

        coords := ResolveClickCoords(hwnd)
        if !coords {
            StopLoop("无法计算点击位置，循环停止")
            return
        }

        if !SendClick(hwnd, coords.x, coords.y, app.settings.holdMinMs, app.settings.holdMaxMs) {
            StopLoop("点击发送失败，循环停止")
            return
        }

        if !SafeSleep(app.settings.intervalMinMs, app.settings.intervalMaxMs)
            return
    }
}

ResolveClickCoords(hwnd) {
    try {
        WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
    } catch as err {
        AddLog("无法获取窗口客户区：" err.Message)
        return 0
    }

    switch app.settings.clickMode {
        case 1:
            return { x: Round(cw / 2), y: Round(ch / 2) }
        case 2:
            return { x: app.settings.customX, y: app.settings.customY }
        case 3:
            MouseGetPos &mx, &my
            return { x: mx - cx, y: my - cy }
    }
    return 0
}

SendClick(hwnd, x, y, holdMin, holdMax) {
    if app.settings.sendMode = 2
        return SendForegroundClick(hwnd, x, y, holdMin, holdMax)
    return SendBackgroundClick(hwnd, x, y, holdMin, holdMax)
}

SendBackgroundClick(hwnd, x, y, holdMin, holdMax) {
    try {
        ControlClick("X" x " Y" y, "ahk_id " hwnd, , "Left", 1, "NA D")
        Sleep Random(holdMin, holdMax)
        ControlClick("X" x " Y" y, "ahk_id " hwnd, , "Left", 1, "NA U")
        return true
    } catch as err {
        AddLog("后台点击报错：" err.Message)
        return false
    }
}

SendForegroundClick(hwnd, x, y, holdMin, holdMax) {
    try {
        if !WinActive("ahk_id " hwnd) {
            WinActivate "ahk_id " hwnd
            if !WinWaitActive("ahk_id " hwnd, , 1) {
                AddLog("前台点击失败：窗口激活超时")
                return false
            }
            Sleep 30
        }

        WinGetClientPos &cx, &cy, , , "ahk_id " hwnd
        screenX := cx + x
        screenY := cy + y

        MouseClick "Left", screenX, screenY, 1, 0, "D"
        Sleep Random(holdMin, holdMax)
        MouseClick "Left", screenX, screenY, 1, 0, "U"
        return true
    } catch as err {
        AddLog("前台点击报错：" err.Message)
        return false
    }
}

ManualClick(*) {
    settings := ApplySettingsFromUi()
    if !settings
        return

    hwnd := FindSelectedGameWindow()
    if !hwnd
        return

    coords := ResolveClickCoords(hwnd)
    if !coords {
        SetStatus("状态：无法计算点击位置")
        return
    }

    if SendClick(hwnd, coords.x, coords.y, settings.holdMinMs, settings.holdMaxMs) {
        SetStatus("状态：测试点击 (" coords.x ", " coords.y ")")
        AddLog("测试点击发送成功 (" coords.x ", " coords.y ")")
    } else {
        SetStatus("状态：测试点击失败")
    }
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
        intervalMinMs: app.controls.intervalMinEdit.Value,
        intervalMaxMs: app.controls.intervalMaxEdit.Value,
        holdMinMs: app.controls.holdMinEdit.Value,
        holdMaxMs: app.controls.holdMaxEdit.Value,
        clickMode: app.controls.clickModeSelect.Value,
        customX: app.controls.customXEdit.Value,
        customY: app.controls.customYEdit.Value,
        sendMode: app.controls.sendModeSelect.Value,
        alwaysOnTop: app.controls.HasOwnProp("alwaysOnTopCheck") ? app.controls.alwaysOnTopCheck.Value : app.settings.alwaysOnTop
    }
}

ValidateSettings(settings) {
    intervalMin := ParsePositiveInteger(settings.intervalMinMs, "点击间隔最小")
    intervalMax := ParsePositiveInteger(settings.intervalMaxMs, "点击间隔最大")
    if intervalMin > intervalMax
        throw Error("点击间隔最小不能大于最大")

    holdMin := ParsePositiveInteger(settings.holdMinMs, "按键停留最小")
    holdMax := ParsePositiveInteger(settings.holdMaxMs, "按键停留最大")
    if holdMin > holdMax
        throw Error("按键停留最小不能大于最大")

    clickMode := ParsePositiveInteger(settings.clickMode, "点击位置模式")
    if clickMode < 1 || clickMode > 3
        throw Error("点击位置模式无效")

    customX := ParseInteger(settings.customX, "自定义 X")
    customY := ParseInteger(settings.customY, "自定义 Y")

    sendMode := ParsePositiveInteger(settings.sendMode, "发送模式")
    if sendMode < 1 || sendMode > 2
        throw Error("发送模式无效")

    alwaysOnTop := (settings.alwaysOnTop + 0) ? 1 : 0

    return {
        targetExe: settings.targetExe,
        intervalMinMs: intervalMin,
        intervalMaxMs: intervalMax,
        holdMinMs: holdMin,
        holdMaxMs: holdMax,
        clickMode: clickMode,
        customX: customX,
        customY: customY,
        sendMode: sendMode,
        alwaysOnTop: alwaysOnTop
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

ParseInteger(value, fieldName) {
    text := Trim(value . "")
    if text = ""
        throw Error(fieldName "不能为空")
    if !RegExMatch(text, "^-?\d+$")
        throw Error(fieldName "必须是整数")
    return text + 0
}

UpdateSettingsUi(settings) {
    if !HasUiControls()
        return

    app.controls.intervalMinEdit.Value := settings.intervalMinMs
    app.controls.intervalMaxEdit.Value := settings.intervalMaxMs
    app.controls.holdMinEdit.Value := settings.holdMinMs
    app.controls.holdMaxEdit.Value := settings.holdMaxMs
    app.controls.clickModeSelect.Value := settings.clickMode
    app.controls.customXEdit.Value := settings.customX
    app.controls.customYEdit.Value := settings.customY
    app.controls.sendModeSelect.Value := settings.sendMode
    if app.controls.HasOwnProp("alwaysOnTopCheck")
        app.controls.alwaysOnTopCheck.Value := settings.alwaysOnTop
}

HasUiControls() {
    return IsObject(app.controls) && app.controls.HasOwnProp("intervalMinEdit")
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
