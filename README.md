<div align="center">

<img src=".github/assets/icon.png" width="128" alt="EasyDisplay">

# EasyDisplay

**macOS 選單列的螢幕亮度工具 —— 讓 MacBook Pro 的 XDR 螢幕在一般畫面也能亮到 1000 nit，色彩不變。**


[![正式版](https://img.shields.io/github/v/release/ExpTechTW/EasyDisplay?label=%E6%AD%A3%E5%BC%8F%E7%89%88&color=1B8A50)](https://github.com/ExpTechTW/EasyDisplay/releases/latest)

[![測試版](https://img.shields.io/github/v/tag/ExpTechTW/EasyDisplay?sort=date&label=%E6%B8%AC%E8%A9%A6%E7%89%88&color=orange)](https://github.com/ExpTechTW/EasyDisplay/releases)

[![建置](https://img.shields.io/github/actions/workflow/status/ExpTechTW/EasyDisplay/release.yml?branch=main&label=%E5%BB%BA%E7%BD%AE)](https://github.com/ExpTechTW/EasyDisplay/actions/workflows/release.yml)

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#下載)

[![Discord](https://img.shields.io/discord/926545182407688273?logo=discord&logoColor=white&label=Discord&color=5865F2)](https://discord.gg/5dbHqV8ees)


**繁體中文** • [English](README.en.md) • [日本語](README.ja.md)


[下載](https://github.com/ExpTechTW/EasyDisplay/releases/latest) • [更新日誌](https://github.com/ExpTechTW/EasyDisplay/releases) • [回報問題](https://github.com/ExpTechTW/EasyDisplay/issues)

</div>

## EasyDisplay 是什麼

EasyDisplay 是住在選單列的 macOS 螢幕亮度工具。MacBook Pro 的 Liquid Retina XDR 螢幕在一般（SDR）畫面最亮只有 600 nit，更高的亮度只留給 HDR 內容；EasyDisplay 直接調高背光，讓一般畫面也能亮到 1000 nit。

它只改背光，不縮放像素、不動色彩管理，所以色彩和原本一樣準。增亮時還能依環境光自動調整亮度，並記住你在不同光線下喜歡的亮度。外接螢幕的亮度也能在同一個地方調整。

## 截圖

<table>
<tr>
<td align="center"><img src="imgs/menu-bar.png" width="240" alt="選單列面板"><br>選單列面板：各螢幕的亮度與即時監測</td>
<td align="center"><img src="imgs/settings-boost.png" width="520" alt="XDR 增亮"><br>XDR 增亮：開關、目前狀態與自動亮度</td>
</tr>
</table>

<table>
<tr>
<td align="center"><img src="imgs/settings-auto-brightness.png" width="390" alt="自動亮度學習"><br>自動亮度學習：學到的亮度曲線與溫度保護</td>
<td align="center"><img src="imgs/settings-general.png" width="390" alt="一般"><br>一般：登入時啟動、亮度鍵與語言</td>
</tr>
<tr>
<td align="center"><img src="imgs/settings-monitor.png" width="390" alt="監測"><br>監測：亮度、背光功耗與螢幕溫度</td>
<td align="center"><img src="imgs/settings-monitor-light-power.png" width="390" alt="監測"><br>監測：環境光與整機功耗</td>
</tr>
<tr>
<td align="center"><img src="imgs/settings-analysis.png" width="390" alt="分析"><br>分析：增亮時間、背光用電與各亮度的時間</td>
<td align="center"><img src="imgs/settings-analysis-details.png" width="390" alt="分析明細"><br>分析明細與資料保留</td>
</tr>
</table>

## 能做什麼

| | |
|---|---|
| **XDR 增亮** | 直接調高內建 XDR 螢幕的背光，讓一般畫面最亮到 1000 nit，色彩不變。關閉增亮、結束 App，或當機後重新開啟，都會還原原本的顯示器預設模式、亮度與自動亮度 |
| **增亮時的自動亮度** | 依環境光感測器調整亮度，最高 1000 nit。環境光要真的改變（亮 10% 持續 4 秒、暗 20% 持續 8 秒）才會跟著調整，亮度也會平滑漸變，不會跳動 |
| **學習你的偏好** | 自動亮度運作時用滑桿或亮度鍵調整，會記住你在當下光線選的亮度，而且只影響相近的光線：在暗房間調亮，不會讓白天也跟著變亮。學到的曲線可以在設定中查看，也能全部忘記 |
| **溫度保護** | 直接控制背光會繞過 macOS 本身的溫度管理，所以 EasyDisplay 在面板變熱之前自己降低上限：螢幕溫度 42 °C 起逐步降低，45 °C 時 600 nit，48 °C 以上 400 nit |
| **亮度鍵** | 接手鍵盤的亮度鍵，調整你正在使用的螢幕（最前面視窗所在的螢幕，否則是游標所在的螢幕），內建或外接都可以，並在該螢幕右上角顯示亮度（nit）。按住 ⌥⇧ 可以微調 |
| **外接螢幕** | 在選單列調整外接螢幕的亮度：Apple 的螢幕透過系統控制，其他螢幕透過 DDC/CI |
| **監測** | 每秒記錄亮度、背光功耗、整機功耗、螢幕溫度與環境光，可以看最近 5 分鐘到 30 天的圖表。指到任一張圖，所有圖表都會顯示同一時間的數值，增亮的期間以底色標出 |
| **分析** | 今天、7 天或 30 天內的增亮時間、背光用電（每小時或每天，一般與增亮分開）、占整機用電的比例、平均與最高亮度、各亮度的時間、最高溫度與平均環境光。資料只存在這台 Mac 上，保留 30、90 或 365 天，每天約 400 KB |
| **選單列顯示亮度** | 選單列圖示旁顯示內建螢幕目前的亮度，增亮時太陽圖示是實心的 |
| **自動更新** | 從 GitHub 取得經 Apple 公證的更新，而且只安裝同一個開發者簽署的版本；可以選擇接收測試版 |
| **三種語言** | 繁體中文、English、日本語，預設跟隨系統，也可以在設定中切換 |

## 下載

需要 **macOS 26 以上**與 Apple silicon。XDR 增亮需要有 Liquid Retina XDR 螢幕的 MacBook Pro。

1. 到 [Releases](https://github.com/ExpTechTW/EasyDisplay/releases/latest) 下載 `EasyDisplay-<版本>.zip`，解壓縮後把 EasyDisplay.app 放進「應用程式」資料夾再打開。App 經過 Apple 公證，可以直接開啟。
2. 第一次打開時，macOS 會詢問「輔助使用」權限，讓 EasyDisplay 接手亮度鍵，請允許。也可以在選單列面板或「設定 › 一般」按「允許…」。
   - 對話框沒出現或之前拒絕過：打開「系統設定 › 隱私權與安全性 › 輔助使用」，把 EasyDisplay 的開關打開。
   - 沒有這個權限時亮度鍵由 macOS 處理，增亮時按調亮鍵會沒有作用。
3. 在「設定 › XDR 增亮」打開「XDR 增亮」。想在開機後自動恢復增亮，請在「設定 › 一般」開啟「登入時啟動」；「啟動時恢復增亮」預設就是開啟的。

EasyDisplay 在啟動時與之後每 6 小時檢查一次更新，有新版本時會通知你；也可以在「設定 › 軟體更新」按「立即檢查」。選單列圖示被收起來時，再次打開 EasyDisplay（從 Finder 或 Spotlight）就會顯示設定視窗。

### 正式版與測試版

| | 名稱 | 發布時機 |
|---|---|---|
| 正式版 | `26.1`：年份．第幾版 | 手動發布 |
| 測試版 | `26w39a`：年份、第幾週、當週第幾個 | 每次推送到 `main` 自動發布；未經審查，可能有問題 |

想搶先試用，請在「設定 › 軟體更新」開啟「接收測試版」。正式版只會更新到正式版，測試版只會更新到測試版。選單列面板底部會顯示目前的版本：測試版是橘色標籤，正式版是綠色標籤。

## 已知限制

- XDR 增亮目前只在 M4 Max 的 MacBook Pro 上實測過。
- 增亮時螢幕會切到「Apple Display (P3-600 nits)」預設模式，HDR 影片不會有比白色更亮的亮部。要看 HDR 內容，請先關閉增亮。
- 增亮時 macOS 的亮度固定在最大，請用 EasyDisplay 的滑桿或亮度鍵調整；「控制中心」的亮度滑桿調整後會跳回最大。
- 不要和 BetterDisplay 等同樣直接控制背光的工具同時使用，兩邊會互相改寫亮度。
- 外接螢幕要支援 DDC/CI 才能調整亮度；有些螢幕或轉接器不支援。
- EasyDisplay 用到 macOS 的私有 API，未來的 macOS 更新可能讓部分功能暫時失效，也因此無法上架 App Store。

## 參與開發

需要 macOS 26 以上、Xcode 26 以上（提供 macOS 26 SDK），以及 [mise](https://mise.jdx.dev)：Swift 的版本固定在 [mise.toml](mise.toml)，本機與 CI 用同一版。

```bash
git clone https://github.com/ExpTechTW/EasyDisplay.git
cd EasyDisplay
mise install                          # 安裝 mise.toml 指定的 Swift
git config core.hooksPath .githooks   # 提交時檢查 commit 訊息
mise exec -- swift test               # 跑測試
scripts/build-app.sh                  # 建置 build/EasyDisplay.app
open build/EasyDisplay.app
```

- `scripts/build-app.sh` 用鑰匙圈裡的憑證簽署：優先 Developer ID Application，其次 Apple Development。都沒有時改用 ad-hoc 簽署，每次重新建置後 macOS 都會再詢問權限，也無法自動更新。
- `swift run` 也能執行，但輔助使用權限會算在終端機上，建議用打包好的 App。
- commit 訊息就是更新日誌，格式見 [commit.md](commit.md)，由 git hook 與 CI 檢查。
- `Experiments/DirectUpscalingTest.swift` 是找出與驗證這個增亮方式時用的命令列工具。

### 運作方式

開啟增亮時，EasyDisplay 會：

1. 記下目前的顯示器預設模式、亮度滑桿、自動亮度與背光上限；關閉增亮、結束，或當機後重新開啟時，照這份紀錄還原。
2. 關閉系統的自動亮度，切到「Apple Display (P3-600 nits)」預設模式，並把 macOS 的亮度固定在最大。
3. 在內建螢幕的 `IOMobileFramebufferShim` 寫入 `IOMFBIndicatorNitsCap`、`BLNitsCap`、`limit_max_physical_brightness`，再寫入 `IOMFBBrightnessLevel`（都是 16.16 定點數的 nit），直接設定背光。

macOS 的亮度固定在最大時，corebrightnessd 眼中的白色就是這個模式的 HDR 上限 600 nit，EDR headroom 維持 1。否則只要有 App 要求 HDR，corebrightnessd 就會開始 EDR 漸變：約 2 秒內不斷改寫背光並壓暗 SDR 像素，和 EasyDisplay 寫回背光互相拉扯，看起來就是閃爍。也因為亮度固定了，亮度鍵改由 EasyDisplay 自己處理。

- **背光**：由 `BacklightDriver` 在自己的佇列上維持，不經過主執行緒。每秒 30 次讀取背光：被別的程式改寫（喚醒、切換模式、原彩顯示）就在一個週期內寫回，約 10–20 ms；螢幕關閉時不動作；前往新亮度時，在對數刻度上漸變一步。其他工作每秒隨感測器取樣做一次，滑桿與亮度鍵則立即生效。
- **自動亮度**：corebrightnessd 的 `AggregatedLux` 在系統自動亮度關閉時仍會更新。`AmbientFilter`（仿 Android 的 AutomaticBrightnessController：快慢兩個平均、遲滯區間與延遲）決定要跟隨的環境光，再由亮度曲線換算亮度。曲線從 `AmbientLight.curve` 開始，每次調整都是該光線下的一個點（和 Android 9 以後相同）：點之間在對數尺度上內插，範圍外以高斯函數淡回預設，並從最新的點往外保持單調。
- **為什麼是 1000 nit**：全白畫面時，面板在約 17.6 W、約 1100 nit 碰到功耗上限。停在 1000 nit，亮度就不會隨畫面內容改變。
- **監測資料**：存在 `~/Library/Application Support/io.github.yuyu1015.EasyDisplay/Monitor.sqlite`。每 5 分鐘一筆二進位資料（Float16、差分、位元組平面、LZMA 壓縮，平均每秒約 4–6 位元組），另有每 5 分鐘的摘要，給長時間的圖表與分析使用。
- **日誌**：`log stream --predicate 'subsystem == "io.github.yuyu1015.EasyDisplay"'`

| 檔案 | 內容 |
|---|---|
| `BuiltInDisplay.swift` | 內建螢幕：開關與還原增亮、目標亮度、自動亮度、溫度上限 |
| `BacklightDriver.swift`、`BuiltInFramebuffer.swift` | 在獨立佇列上維持背光並漸變；讀寫背光屬性 |
| `AutoBrightness.swift`、`AmbientLight.swift` | 環境光濾波與學到的亮度曲線；讀取環境光、預設曲線 |
| `DisplayManager.swift`、`ExternalDisplay.swift`、`DDC.swift` | 螢幕清單與亮度鍵的分派；外接螢幕與 DDC/CI |
| `BrightnessKeys.swift`、`BrightnessOSD.swift` | 攔截亮度鍵、找出正在使用的螢幕；亮度指示 |
| `DisplayPresets.swift`、`PrivateFrameworks.swift` | 顯示器預設模式；DisplayServices 與逾時 |
| `SensorMonitor.swift`、`SMC.swift` | 每秒取樣；讀取 SMC 的功耗與溫度 |
| `MonitorDatabase.swift`、`SampleCodec.swift`、`MonitorChartModel.swift` | SQLite 儲存、壓縮格式、圖表資料 |
| `TrayView.swift`、`SettingsWindow.swift`、`SettingsView.swift`、`MonitorCharts.swift`、`MonitorAnalysisView.swift`、`AutoCurveChart.swift`、`Components.swift` | 選單列面板、設定視窗與各頁面、圖表與共用元件 |
| `Update.swift`、`Updater.swift` | 自動更新：比較版本、下載、驗證與替換 |
| `AppSettings.swift`、`Localization.swift` | 設定；介面語言 |

### 發布

沿用 DPIP 的規則：推送到 `main` 會自動發布測試版，推送 `v<yy>.<n>` tag（例如 `v26.1`）會發布正式版。每個版本都以 Developer ID 簽署、經 Apple 公證；更新日誌由 commit 的條目行自動產生（見 [commit.md](commit.md)），並公告到 Discord。
