# x2muse

**複製一條 X 連結，佢自己走去 Muse 度。**

一個 macOS 小腳本：喺背景監測剪貼板，一見到新的 `x.com` / `twitter.com` 連結，就自動填入 Chrome 入面已開住的 Muse（muse.ai）分頁並送出，全程不搶畫面、不改你的剪貼板。

> A tiny macOS script: it watches your clipboard for X (Twitter) links and sends each new one to the Muse tab already open in your Chrome — in the background, without stealing focus or touching your clipboard.

## 為什麼做它

看 X 的時候，值得深究的帖子總想丟給 AI 分析。手動流程是：複製連結 → 切去瀏覽器 → 找到對話分頁 → 貼上 → 加一句提示 → 送出。一天十幾次，煩，而且打斷閱讀。

x2muse 把這串動作壓縮成一個：**複製**。剩下的它做。

## 它怎樣運作

1. 每 1 秒讀一次剪貼板，抽出第一條 `x.com` / `twitter.com` 連結。
2. 同一條連結要穩定存在 3 秒才觸發（防複製未完成、防手快改主意）。
3. 用 AppleScript 在 Chrome 的 muse.ai 分頁**直接執行 JavaScript**：填入輸入框並按下送出。
   - 輸入框是空的 → 用 `PREPEND_TEXT + 連結` 送出；
   - 輸入框已有文字 → 連結附加在後面。
4. 送出後驗證輸入框已清空，確認真的送出了，才把連結寫入「已發送」記錄；同一條連結不會重發。
5. **不搶畫面**：舊版會把 Chrome 窗口推到最前、切換分頁，每次都要人手切回來。2026-11-13 修訂後改為背景分頁直接執行，並在送出後把焦點自動交回你原本在用的 app——複製完，你可以留在 X 繼續看。
6. **重試有上限（v4，2026-11-15）**：待發連結用 FIFO 隊列逐條送；每條最多嘗試 5 次，等待時間遞增（10→30→90→300 秒），超限就寫入死信檔 `~/x2muse-deadletter.txt` 停手，不再無限重試。源起是一次真實事故：一條連結送不出去，舊版每 10 秒重試同一條，一個多小時失敗了 342 次——填進輸入框卻過不了自己的驗證，重試又把連結重複追加，越填越滿（而這支腳本的累計日誌裡，歷次事故的失敗加起來逾 3,000 次）。v4 同時修了這兩處：輸入框已有同一條連結就不追加，先查頁面是否其實已送出；驗證改為多次檢查。

不需要輔助使用（Accessibility）權限，不模擬鍵盤滑鼠，不經任何伺服器，沒有遙測。

## 需求

- macOS（用到 `pbpaste`、`osascript`、launchd）
- Google Chrome，且已開啟「允許來自 Apple Events 的 JavaScript」：
  Chrome 選單 → **檢視（View）> 開發人員（Developer）> 允許來自 Apple Events 的 JavaScript**
- Chrome 裡開著一個 muse.ai 分頁（登入好你的帳號；腳本不碰密碼、不代登入）

## 安裝

```bash
# 1. 下載腳本，放好
cp x2muse.sh ~/x2muse.sh
chmod +x ~/x2muse.sh

# 2. 先試跑（偵測到也只會印出來，不真送出）
~/x2muse.sh --dry-run
# 複製一條 X 連結試試，看到 [DRY RUN] 會發送 就Ctrl+C 停掉

# 3. 正式跑
~/x2muse.sh
```

### 開機自動啟動（launchd，可選）

把 `com.user.x2muse.plist.example` 裡的 `YOUR_USERNAME` 換成你的 Mac 用戶名，改名為 `com.user.x2muse.plist`，放到 `~/Library/LaunchAgents/`，再載入：

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.x2muse.plist
```

日誌在 `~/Library/Logs/x2muse.log`。

## 用法

```bash
./x2muse.sh             # 正常運行（Ctrl+C 停止）
./x2muse.sh --dry-run   # 只偵測、不發送（測試用）
./x2muse.sh --reset     # 清除「已發送」記錄（可以重發上一條）
```

## 可調設定（腳本頂部）

| 設定 | 說明 |
| --- | --- |
| `MUSE_URL_KEYWORD` | 目標分頁的網址關鍵字，預設 `muse.ai`（任何 Muse 分頁）。**強烈建議鎖定**到你專用對話的 thread 網址片段：只寫域名時，它會送去第一個找到的 Muse 分頁——同時開著幾個對話，就可能送錯地方（這是作者本人踩過的坑，見下方「限制」） |
| `PREPEND_TEXT` | 輸入框為空時，連結前面加的提示文字。預設值是作者本人用的完整提問（用免費通道讀完原文、逐項對照在研項目判幫助、分檔給結論），換成你自己的提問即可——這支腳本的用法精髓，一半在這句提問寫得夠不夠具體 |
| `POLL_SEC` / `STABLE_SEC` | 輪詢間隔（預設 1 秒）／連結穩定多久才送（預設 3 秒） |

## 限制，老實講

- 只認剪貼板裡的**文字**連結，一次只處理第一條；圖片、檔案不處理。
- 只送去**第一個**符合關鍵字的分頁；開了多個 Muse 對話又不鎖定 thread，它會送去第一個找到的。
- Chrome 必須開著；目標分頁不存在時腳本會自己在背景開回（開完把顯示頁切回原頁）。送出失敗會按上限重試（見上），超限入死信檔，不會無限重試；Chrome 沒開時它只會等待，不會自己啟動 Chrome。
- 背景執行 JavaScript 是靠 Chrome 的 Apple Events 通道；Chrome 若關掉那個選項，腳本會失敗——先檢查「需求」那一步。
- 只在 macOS 上驗證過。

## 隱私

腳本只在本機讀你的剪貼板，只對你已登入的 Muse 分頁執行填入與送出；不儲存連結以外的剪貼板內容，不上傳任何東西到第三方。「已發送」記錄只存最後一條連結在本機暫存目錄，用來防重發，`--reset` 可清除。

## 授權

MIT，見 `LICENSE`。
