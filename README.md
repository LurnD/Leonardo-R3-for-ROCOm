# 洛克王国 - Leonardo R3 硬件 HID 方案

把原本的两个 AutoHotkey 脚本（`ahk/roco_auto_catch.ahk`、`ahk/roco_single_flower.ahk`）
迁移成 **真硬件 HID** 输入：Leonardo R3 在 USB 上枚举为标准键盘 + 绝对鼠标，
PC 上的 Python 程序只负责前台窗口检测、参数下发和 GUI，不再发送任何系统级键鼠事件。

```
ahk/                          原 AHK 脚本（仅保留作参考）
firmware/leonardo_roco/
  leonardo_roco.ino           烧到 Leonardo 的固件
host/
  roco_host.py                PC 上位机（Python + Tk）
  requirements.txt
  roco_host.json              首次运行后会生成（设置存档）
```

---

## 1. 固件部分（Leonardo R3）

### 1.1 安装库

打开 Arduino IDE → 工具 → 管理库，安装：

- **AbsMouse**  作者 Jonathan Edgecombe（提供绝对坐标鼠标 HID）
- `Keyboard` 是 Arduino 自带的，不用单独装

如果库管理器搜不到 `AbsMouse`，去  
<https://github.com/jonathanedgecombe/absmouse> 下载 zip，IDE → 项目 → 加载库 → 添加 .ZIP。

### 1.2 烧录

1. 把 Leonardo R3 用 USB 接到电脑。
2. 工具 → 开发板：`Arduino Leonardo`，工具 → 端口选中它对应的 COM。
3. 打开 `firmware/leonardo_roco/leonardo_roco.ino`，点上传。

烧录成功后，开发板会被识别为一个 USB 键盘 + 鼠标。从这一刻起，
不要在串口监视器里敲奇怪东西，否则可能误按键。

> **提示**：如果想让 Leonardo "刚插上 1 秒就开始打字"，
> 不要去 `setup()` 里直接发键 —— 它会在拔下来重插时给你来一发。
> 当前固件默认空闲，必须收到 `START`/`CATCH`/`FLOWER` 才动作。

### 1.3 协议（PC 通过串口下发，115200 baud，LF 结尾）

| 命令 | 作用 |
|------|------|
| `PING` | 心跳，回 `PONG` |
| `STOP` | 立刻中止任何运行中的脚本，释放所有按键 |
| `K <code> <holdMs>` | 单击一个键（`code` 是 Arduino `Keyboard.h` 字节，比如 `'2'` = 50） |
| `MC <x> <y> <holdMs>` | 鼠标移到绝对坐标 `(x,y)`（0..32767）并左键单击 |
| `INIT` | 连按 10 次 ↓（对应原 AHK 的初始化按钮）|
| `CATCH x y holdMin holdMax intvMin intvMax` | 启动抓取循环：移到 `(x,y)`，随机停留后单击，按随机间隔重复 |
| `FLOWER cx cy loopMin loopMax afkPct restPct keyDelay` | 启动单花循环（前置 `13456` + 主键 `2` + `Tab,2,Esc,R,X` 内循环 + 走神/喘息），完全复刻原 AHK 行为 |

所有回复都以 `OK` 或 `ERR` 开头。

---

## 2. 上位机部分（PC）

### 2.1 Python 环境

```
python -m pip install -r host/requirements.txt
```

仅需 `pyserial`。GUI 用 Tk（Python 自带），其余功能（前台窗口、全局热键）
都是直接 ctypes 调 `user32.dll` —— 没有第三方注入式键鼠库（`keyboard`、
`pynput` 等都没用），尽量减少被反作弊扫到的可疑特征。

### 2.2 启动

```
cd host
python roco_host.py
```

界面操作：

1. **串口** 行选中 Leonardo（描述带 `Arduino Leonardo`），点"连接"。
2. **游戏进程** 默认 `NRC-Win64-Shipping.exe`，需要时改。
3. 勾上"前台不是游戏时自动暂停"（推荐）。  
   开了之后，凡是切到桌面/聊天/浏览器，上位机就立刻 `STOP`，
   Leonardo 不再发键鼠；切回游戏自动续上。
4. 自动抓取面板：
   - 点击位置选择"窗口客户区中心"会自动用游戏窗口的客户区中心做单击点。
   - "屏幕坐标" + "3 秒后记录鼠标位置" 用来手动拾取（鼠标停在目标点，等 3 秒）。
   - 间隔 / 按键停留是 ms 范围，硬件随机化。
5. 循环助手面板对应 `roco_single_flower.ahk`：循环次数 0/0 表示无限，
   走神/喘息百分比含义不变。
6. 全局热键：**Ctrl+-** 抓取启停、**Ctrl+=** 循环助手启停（即使焦点在游戏里也能用）。

### 2.3 设置存档

`host/roco_host.json` 在关闭程序时写入；下次启动恢复。

---

## 3. 注意事项

1. **绝对鼠标和虚拟桌面**：Leonardo 报告的是 0..32767 范围，Windows 把它映射到
   主显示器。如果你是多显示器并且游戏不在主显示器，先把游戏拖到主屏。
   上位机里 `get_screen_size()` 只取主屏分辨率。
2. **DPI 缩放**：上位机已调 `SetProcessDPIAware()`，所以拿到的 `GetSystemMetrics`
   是真实像素，能和 HID 范围正确对应。如果游戏在 1920×1080 全屏，应该完全准确。
3. **拔板子等于撤销作弊设备**：游戏完全看不到 Leonardo 是受程序控制的，
   它只看到一把键盘和一把绝对定位鼠标插上 USB。
4. **腾讯 ACE**：本方案不再使用 AHK，不再调用 `SendInput`/`PostMessage` 之类
   被监控的 API。Python 上位机也不挂全局键盘钩子，只用 `RegisterHotKey`
   （Outlook、QQ 等都在用的标准接口）和 `GetForegroundWindow`。
5. **暂停回执的延迟**：失焦检测周期 500ms，最坏情况下 0.5 秒后才会发 `STOP`，
   到 Arduino 端再过一个 sleep tick (≤ 2ms) 真正停下。CATCH 间隔通常 800ms 以上，
   够用；如果担心，把 `_tick_foreground` 里的 `self.root.after(500, …)` 改小。
6. **想把固件的"前置 13456"或"循环序列 Tab,2,Esc,R,X"改掉**：
   修改 `leonardo_roco.ino` 里 `runFlowerOnce` 中的 `const char* prefix = "13456";`
   和 `innerCycle` 里那张 `KeySpec keys[5]` 表，然后重新烧录。

---

## 4. 调试

- 看不到 OK/PONG 回执：上位机右下日志区每行带 `<<` 前缀的就是 Arduino 回的。
  连不上时换根 USB 数据线、确认不是仅充电线。
- 烧完后 COM 口跑掉了：Leonardo 有 bootloader / sketch 两个 PID（0x0036 / 0x8036），
  烧录瞬间会跳到 bootloader 然后回到 sketch。上位机刷新串口列表即可。
- 抓取点偏了：用"3 秒后记录鼠标位置"取点；如果游戏窗口拖动了/分辨率变了，
  重新取点。"窗口客户区中心"模式每次启动都会重算，自动跟着窗口走。
- 按键无效：游戏可能拦截了硬件 HID（极少见）。看回的 `OK` 是不是真到了，
  以及 Leonardo 上的板载 LED 是不是亮（运行 CATCH/FLOWER 时会常亮）。
