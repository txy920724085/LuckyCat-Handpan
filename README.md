LuckyCat Handpan

基于 **Gowin FPGA / Sipeed Tang Mega 138K Pro + Pro Dock** 的电子手碟工程，集成八路敲击检测、32 声部合成、四种音色、触摸控制和 HDMI 音频可视化，并提供 Windows 调参工具及 Android 跟练 App。

乐器声音在 FPGA 内实时合成；HDMI 波形与频谱取自最终送往 DAC 的 PCM 数据。蓝牙用于音符控制、状态回传和参数调节。

## 功能概览

| 模块 | 功能 |
| --- | --- |
| 敲击输入 | ADS8688 八通道采集，基线标定、力度检测、串扰过滤、事件缓存 |
| 音频合成 | 32 个声部槽位，模态合成与 Karplus–Strong 拨弦合成，支持叠音 |
| 音色 | Handpan（手碟）、Pluck（拨弦）、Marimba（马林巴）、Drum（鼓） |
| 演奏控制 | QT2120 五个触摸键切换音色及 Echo，中央触摸环调节全局 Sustain |
| 音频输出 | 板载 PT8211，16 位 PCM，实际采样率约 48.828 kHz |
| HDMI 显示 | 八路有效敲击力度、PCM 波形、1024 点 FFT / 32 频带、当前控制状态 |
| Windows 工具 | 蓝牙串口连接、ADC 峰值/RMS 观察、检测参数回读与修改、配置保存/载入 |
| Android App | 音位试听、曲谱导入、示范/跟练、敲击事件录制回放、节拍器 |

32 声部指合成器可分配的发声槽位，运算资源通过时分复用共享。实体敲击输入为八路。

## 系统结构

```text
八路敲击传感器 → ADS8688 → 标定/检测/串扰过滤 → 事件 FIFO → 声部分配
                                                           ↓
QT2120 触摸键/环 ──────────────→ 音色 / Sustain / Echo → 32 声部合成
                                                           ↓
JDY-31 ←→ Windows 调参工具 / Android App                 最终 PCM
                                                           ├─→ PT8211 → 功放/扬声器
                                                           └─→ 波形/FFT → HDMI 显示器
```

显示分析旁路读取音频数据，分析忙时跳过显示取样窗，不反压音频或 ADC。HDMI 输出视频；JDY-31 传输控制和遥测，两者均不传输音频流。

## 硬件与开发环境

| 项目 | 配置 |
| --- | --- |
| 开发板 | Tang Mega 138K Pro + Pro Dock |
| FPGA | `GW5AST-LV138FPG676AC1/I0`，**Device Version B** |
| 主时钟 | 50 MHz |
| 工程顶层 | `handpan_visual_top` |
| FPGA 工具 | 原完整实现使用 Gowin V1.9.12.04 |
| 源码 | Verilog / SystemVerilog，编译清单见 [SOURCES.json](project/SOURCES.json) |
| ADC / 触摸 / 蓝牙 | ADS8688 / QT2120 / JDY-31 |
| Windows 调参环境 | Python 3.10+、Tkinter、pyserial |
| Android App | Android 5.0+，v0.9 / versionCode 10 |

### 主要连接

下表中的引脚为 **FPGA 封装管脚号**，不等同于扩展排针序号。完整引脚分配和时序约束以 [constraints](project/constraints) 为准。

| 接口 | FPGA 管脚 / 连接说明 |
| --- | --- |
| 主时钟 / 复位 | `P16` / `K16`（S0，低有效） |
| ADS8688 | CS=`T25`，SCLK=`W23`，SDI=`T23`，SDO=`P25`，RST_N=`R23`，DAISY=`R25` |
| QT2120 | SCL=`H14`，SDA=`L17`；I²C 需外部 3.3 V 上拉 |
| JDY-31 | FPGA `H15` → 模块 RX（J24-6），FPGA `L18` ← 模块 TX（J24-8） |
| JDY-31 串口 | **128000 baud，8N1，无流控**；模块串口配置须与固件一致 |
| PT8211 | BCLK=`E22`，WS=`F24`，DATA=`G24`，功放使能=`H17` |
| 原串口接口 | FPGA RX=`N16`，FPGA TX=`P15` |
| HDMI | Pro Dock **A(TX) / J11** |

板载 PT8211 使用 **16 位 Japanese / right-justified 串行格式**，与标准 Philips I²S 的时序不同。当前顶层的板载音频连接应按 PT8211 接口使用。

## 快速开始

### 1. 下载已有固件
### 2. 触摸控制

| 输入 | 操作 |
| --- | --- |
| KEY7 | 切换 Pluck |
| KEY8 | 切换 Echo 开关 |
| KEY9 | 切换 Drum |
| KEY10 | 切换 Marimba |
| KEY11 | 切换 Handpan |
| 中央触摸环 | 调节全局 Sustain |
| S0 / K16 | 复位 |

屏幕顶部显示当前选定的全局控制状态；正在衰减的声部可能保留触发时的部分参数。本集成版本未配置独立 HDMI 演示工程中的 S1 冻结和 S2 比例切换。

### 3. Windows 调参工具

在工程根目录安装依赖：

```powershell
python -m pip install -r requirements.txt
```

双击 [START_TUNER.bat](START_TUNER.bat)，选择 JDY-31 对应的蓝牙传出 COM 端口，连接后先读取 FPGA 参数，再按需要修改。工具提供八通道峰值/RMS、线性/dB 显示、峰值保持，以及参数配置保存和载入。

离线查看界面：

```powershell
cd project/tuner
python app.py --demo
```

同一 COM 端口不能由多个串口程序同时打开。保存到电脑的配置文件与 FPGA 中的临时运行参数是两种不同的保存方式。

### 4. Android 跟练 App

安装 [HandpanPractice-v0.9.apk](app/01_安装包/HandpanPractice-v0.9.apk)，在系统蓝牙中配对 JDY-31，再在 App 中连接。Android 12 及以上系统需要授予蓝牙相关权限。

- 内置 12 首曲谱，支持本地 JSON 导入和 HTTPS 直链下载曲谱。
- 支持八音位映射、谱面示范、实际敲击反馈和跟练判定。
- 支持敲击事件录制与回放；回放重新发送音符事件，不保存或播放录制的 PCM 音频。
- 提供独立节拍器，支持两组音色及 2/4、3/4、4/4 拍。

曲谱时值用于示范调度及谱面显示。当前 FPGA 音符协议没有 note-off，单个音符的实际尾长由硬件合成器决定。

App 安装、曲谱格式、构建环境和测试范围详见 [提交说明](app/00_提交说明.md)、[软件说明书](app/03_文档/软件说明书.md) 和 [构建说明](app/02_源码/构建说明.md)。**现有 App 文档记录了模拟器验证，实体 JDY-31 / QSU1 / HTE1 蓝牙链路尚未在提交环境中完成联调。**

## 从源码构建 FPGA 工程

在工程根目录打开 PowerShell，使用 Gowin 的 `gw_sh.exe`：

```powershell
.\BUILD.ps1 -GowinShell "<Gowin安装目录>\IDE\bin\gw_sh.exe"
```

将占位路径替换为本机工具路径；若 `gw_sh.exe` 已加入 PATH，可直接运行：

```powershell
.\BUILD.ps1
```

仅运行综合：

```powershell
.\BUILD.ps1 -GowinShell "<Gowin安装目录>\IDE\bin\gw_sh.exe" -SynthesisOnly
```

构建入口为 [BUILD.ps1](BUILD.ps1)，工程定义为 [build_hdmi.tcl](project/build_hdmi.tcl)。FPGA 构建不依赖 Python。

| 输出 | 位置 |
| --- | --- |
| Gowin 工程 | `project/build/handpan_visual/handpan_visual.gprj` |
| 实现报告与生成固件 | `project/build/handpan_visual/impl/pnr/` |
| 构建日志 | `project/build/build.log` |
| 校验通过后更新的交付固件 | `firmware/handpan_hdmi_visual_B.fs` |

完整构建会检查 Setup/Hold 违规端点及 Recovery、Removal、最小脉宽余量，通过后才更新交付固件和 SHA-256 清单。`-SynthesisOnly` 不更新固件；构建脚本不执行硬件下载。

生成工程后可用 Gowin IDE 打开 `.gprj`。移动整个目录后应重新运行构建入口，并保留视频资源目录结构，以便正确定位 ROM 初始化文件。

Android App 使用独立的非 Gradle 构建流程，在准备好其 [构建说明](app/02_源码/构建说明.md) 中的 JDK、Python 和 Android 工具后，于 `app/02_源码` 执行 `build.bat`。

## HDMI 显示说明

视频输出为 **640 × 480 @ 60 Hz**，默认针对 16:10 显示器全屏拉伸进行图形比例补偿，并非原生 1280 × 800 输出。

| 区域 | 数据来源与含义 |
| --- | --- |
| 顶部状态 | 当前选定音色、全局 Sustain、Echo |
| 八路力度条 | CH0～CH7 被合成器接受的敲击 velocity，经包络平滑；不是原始 ADC 数值或校准后的物理力 |
| 波形 | 最终 signed16 PCM 的 1024 点窗口，每四点取 min/max，形成 256 列 |
| 频谱 | 同一 PCM 数据的 1024 点定点 FFT，正频率划分为 32 个非空连续频带 |

音频实际采样率为 **48,828.125 Hz**，1024 点窗口约 **20.97 ms**，FFT 频点间隔约 **47.68 Hz**。频谱显示约 47.68 Hz～9.966 kHz，不显示 DC，使用 Hann 窗、近似幅值和固定参考范围映射，适合作为演奏可视化，不作为精密音准或声压测量工具。

波形绘制采用固定 ×8 显示增益并在面板内限幅，不改变声音或 FFT 输入。波形/FFT 约 10 Hz 更新，力度及状态约 50 Hz 更新，视频刷新为 60 Hz。

Windows 工具中的力度条来自 ADC 峰值/RMS 遥测，与 HDMI 的有效敲击 velocity 含义不同。`WDY1` 遥测也是传感器波形，不是合成音频。

## 目录结构

```text
Handpan_HDMI_Visual/
├── README.md                  项目入口说明
├── README.txt                 原有工程说明
├── BUILD.ps1                  FPGA 构建入口
├── START_TUNER.bat            Windows 调参工具入口
├── requirements.txt           Python 调参工具依赖
├── project/
│   ├── common_rtl/            ADC、音频、串口等共享 RTL
│   ├── rtl/                   合成、敲击检测、触摸、参数与遥测
│   ├── video/
│   │   ├── rtl/               PCM 分析、FFT、跨时钟域及视频绘制
│   │   ├── assets/            背景、字库、Hann 窗与旋转因子
│   │   ├── ip/                目标器件 PLL 等生成 IP
│   │   └── vendor/            第三方 TMDS 编码器
│   ├── constraints/           管脚及时间约束
│   ├── tuner/                 Python 调参界面及协议
│   ├── gui/protocol.py        调参工具依赖的遥测解码器
│   ├── SOURCES.json           顶层及 71 个编译单元清单
│   └── build_hdmi.tcl         Gowin 工程生成与构建定义
├── firmware/                  已有 FS 固件及 SHA-256 清单
├── app/                       Android APK、源码、文档和示例曲谱
├── docs/                      RTL 预览及原完整实现摘要
└── THIRD_PARTY_NOTICES.md      第三方来源与许可说明
```

## 实现参考与验证范围

以下为 [build_summary.json](docs/build_summary.json) 记录的原完整实现结果，用于评估工程规模；它不代表对本目录重新执行了一次综合和布局布线。

| 项目 | 原完整实现结果 |
| --- | --- |
| Logic | 50,508 / 138,240 |
| Register | 46,719 / 139,140 |
| BSRAM | 131 / 340 |
| DSP | 69 / 298 |
| Setup / Hold 违规端点 | 0 / 0 |
| Hold 最小余量 | 0.183 ns |
| Recovery / Removal 最小余量 | 2.371 ns / 0.102 ns |
| 最小脉宽余量 | 6.553 ns |

- [完整乐器界面预览](docs/instrument_panel_16x10.png) 由实际合成器数据路径驱动的 RTL 仿真生成；[单频校验预览](docs/real_fft_panel_preview.png) 的顶部状态及力度使用测试刺激。
- 发布包未提供完整的仿真回归环境，预览图不等同于可直接运行的测试用例。
- 检测模块的流水线拍数、FFT 窗口时长均不能直接作为传感器敲击到扬声器发声的实测总延迟。
- Android 实体蓝牙联调状态见前文；新增板卡或修改约束后，应以对应硬件上的实现报告和运行结果为准。

## 常见问题

**HDMI 没有画面？** 先确认接入 Pro Dock 的 A(TX) / J11，并使用本工程的完整固件；再检查显示器是否接受 640 × 480 @ 60 Hz。

**调参工具连接失败？** 检查蓝牙配对、传出 COM 端口、模块串口速率及端口占用情况，可先用 `--demo` 检查界面能否启动。

**HDMI 力度与电脑柱状条不同？** HDMI 显示经过检测过滤后被接受的敲击力度，电脑显示 ADC 峰值/RMS，两者统计对象不同。

**修改参数后断电恢复默认值？** 当前参数修改保存在运行态，重新配置或上电后使用固件默认值；电脑端可另行保存配置并重新载入应用。

## 第三方来源与许可

本目录尚未为全部自有源码指定统一开源许可证，不能据此默认按 MIT、Apache-2.0 等许可证使用或再分发。

TMDS 编码器来自 Clifford Wolf 的 Simple Video Out，相关原始版权及许可保留在源码中；Gowin 生成 IP 遵循相应厂商条款。详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Android 节拍器素材来源及许可见 [第三方许可与素材来源](app/03_文档/第三方许可与素材来源.md)。


## Android 跟练应用

app目录提供手碟跟练APP的安装包、Java源码、构建说明、示例曲谱及使用文档。详见[APP说明](app/00_提交说明.md)。公开源码及源码ZIP均排除签名私钥，构建时在本地生成开发测试证书。原有FPGA源码、ROM与固件保持不变。
