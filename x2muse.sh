#!/bin/bash
#
# x2muse.sh — 自動偵測剪貼板嘅 x.com 連結，發送到 Muse (muse.ai) 窗口
#
# 原理: 用 Chrome AppleScript 喺 muse.ai 分頁直接執行 JavaScript
#       填入連結並撳「Send」，唔需要輔助使用 (Accessibility) 權限，
#       亦唔會改動你嘅剪貼板。
# 前提: Chrome 要開住「允許來自 Apple Events 的 JavaScript」
#       （Chrome 選單：檢視 > 開發人員 > 允許來自 Apple Events 的 JavaScript）
#
# 規則:
#   - 每 1 秒檢查一次剪貼板
#   - 新連結要連續存在 3 秒先觸發（防手快、防複製未完成）
#   - 同一條連結只發一次；複製到唔同嘅新連結先會再發
#   - Muse 輸入框有字 → 連結會加喺後面；輸入框空 → 用 PREPEND_TEXT + 連結
#   - 發送全程喺背景分頁執行：唔推窗口上前、唔切分頁、唔 activate，唔搶畫面
#     （2026-11-13 修訂）；萬一焦點變咗，發送後自動交返俾發送前嗰個 app
#   - v3（2026-11-14）：目標分頁唔喺度嗰陣，腳本自己喺背景開返（唔 activate
#     Chrome、開完即刻將窗口顯示嗰頁切返去原本嗰頁），唔使人手開
#   - v3：待發連結改用 FIFO 隊列存檔，逐條順序發；複製新連結唔會再頂走
#     未發出嗰條（舊版單槽 pending 會靜靜丟失，2026-11-13／11-14 各丟一條）
#   - v4（2026-11-15）：重試加硬上限。源起：2026-11-15 凌晨一條連結送唔出，
#     舊版每 10 秒重試同一條、無上限，2.5 小時失敗 3,272 次（先係搵唔到
#     分頁；後來填到入框但驗證過唔到，重試又將連結重複追加，框越填越滿、
#     永遠過唔到自己嘅檢查）。v4 改法：① 每條最多試 MAX_ATTEMPTS 次，
#     退避 10→30→90→300 秒，超限入死信檔停手；② 填入前發現框內已有同一
#     條連結就唔再追加，先查頁面係咪其實已送出；③ 驗證改為多次檢查；
#     ④ Chrome 冇開嗰陣唔呼叫 osascript（唔好靠佢去啟動 Chrome），
#     亦唔計入嘗試次數；⑤ 連續失敗熔斷，停 30 分鐘先再試。
#
# 用法:
#   ./x2muse.sh             正常運行（Ctrl+C 停止）
#   ./x2muse.sh --dry-run   只偵測唔發送（測試用）
#   ./x2muse.sh --reset     清除「已發送」記錄（可以重發上一條）
#
# 背景行:
#   nohup ./x2muse.sh > "$TMPDIR/x2muse.log" 2>&1 &

# ---------- 設定 ----------
MUSE_URL_KEYWORD="muse.ai"     # 目標分頁 = 網址包含呢個字串嘅 Chrome 分頁
                               # 強烈建議鎖死去你專用對話嘅 thread 網址片段，例如:
                               # MUSE_URL_KEYWORD="muse.ai/thread/YOUR_THREAD_ID"
                               # 只寫域名會攞第一個符合嘅分頁，可能送錯對話（作者踩過坑）。
MUSE_URL="https://${MUSE_URL_KEYWORD}"
PREPEND_TEXT="请用免费车道分析这条链接，哪里对我的项目有帮助：先把原文读完（看不到正文就找评论区或镜像，不要只看标题），再逐项对照我的在研项目和舰队工具流——判断哪一条真正用得上、用在哪一步、能帮到什么；用不上的直说无帮助，不要凑数，不要复述内容。最后给一个分档结论（直接可用／有启发／无关忽略）和一句具体的下一步建议。链接："   # 輸入框係空嘅時候用嘅提示文字（作者的用法示例，換成你自己的提問即可）
POLL_SEC=1                     # 輪詢剪貼板間隔（秒）
STABLE_SEC=3                   # 新連結要穩定存在幾耐先入隊（秒）
AFTER_SEND_WAIT=5              # 發送後冷靜期（秒）
STATE_FILE="${TMPDIR:-/tmp}/x2muse_last_sent"
QUEUE_FILE="${TMPDIR:-/tmp}/x2muse_queue"
MAX_ATTEMPTS=5                 # v4：每條連結最多嘗試幾多次，超限入死信停手
DEADLETTER_FILE="$HOME/x2muse-deadletter.txt"   # v4：超限／狀態不明嘅連結泊呢度，唔會靜靜丟失
ATTEMPT_DIR="${TMPDIR:-/tmp}/x2muse_attempts"   # v4：每條連結嘅已嘗試次數存檔
BREAKER_LIMIT=12               # v4：連續失敗幾多次觸發熔斷
BREAKER_PAUSE=1800             # v4：熔斷暫停秒數（30 分鐘）
# --------------------------

DRY_RUN=0
case "$1" in
  --dry-run) DRY_RUN=1 ;;
  --reset)   rm -f "$STATE_FILE"; rm -rf "$ATTEMPT_DIR"; echo "已清除發送記錄。"; exit 0 ;;
esac

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

extract_link() {
  printf '%s' "$1" \
    | grep -Eio 'https?://(www\.)?(x|twitter)\.com/[A-Za-z0-9_?=/&.%~-]+' \
    | head -n1 | sed -E 's/[.,;:!?)\]]+$//'
}

send_to_muse() {
  osascript - "$MUSE_URL_KEYWORD" "$1" "$PREPEND_TEXT" "$MUSE_URL" <<'APPLESCRIPT'
on run argv
  set urlKey to item 1 of argv
  set jsLink to my jq(item 2 of argv)
  set jsPre to my jq(item 3 of argv)
  set fullUrl to item 4 of argv

  -- 記低發送前用戶正用緊邊個 app，發送後交返焦點俾佢，唔使人手切返轉頭
  set origApp to ""
  try
    tell application "System Events" to set origApp to name of first application process whose frontmost is true
  end try

  tell application "Google Chrome"
    -- 先搵現有目標分頁
    set targetTab to missing value
    repeat with w in windows
      repeat with i from 1 to (count of tabs of w)
        try
          set t to tab i of w
          if URL of t contains urlKey then
            set targetTab to t
            exit repeat
          end if
        end try
      end repeat
      if targetTab is not missing value then exit repeat
    end repeat

    -- 搵唔到：自己喺背景開返。唔 activate Chrome；新分頁會成為嗰個窗口嘅
    -- 顯示頁，所以記低原本顯示邊頁，開完即刻切返去，等用戶畫面唔變。
    if targetTab is missing value then
      if (count of windows) is 0 then
        set w to make new window with properties {mode:"normal"}
      else
        set w to window 1
      end if
      set prevIdx to 0
      try
        set prevIdx to active tab index of w
      end try
      set targetTab to make new tab at end of tabs of w with properties {URL:fullUrl}
      if prevIdx is not 0 then
        try
          set active tab index of w to prevIdx
        end try
      end if
      -- 開新分頁會將 Chrome 推上前景（實測），即刻將焦點交返俾原本個 app，
      -- 畫面只會閃一閃，分頁喺背景繼續載入
      try
        if origApp is not "" and origApp is not "Google Chrome" then
          tell application "System Events" to set frontmost of first application process whose name is origApp to true
        end if
      end try
      -- 等頁面載入完（最多約 15 秒），再等多 2 秒俾佢渲染輸入框
      repeat 30 times
        try
          if not (loading of targetTab) then exit repeat
        end try
        delay 0.5
      end repeat
      delay 2
    end if

    set t to targetTab
    set fillJs to "(() => {
  const link=" & jsLink & ";
  const pre=" & jsPre & ";
  const ta=document.querySelector('textarea');
  if(!ta) return 'ERR no textarea';
  const cur=(ta.value||'').trim().replace(/\\s+$/,'');
  if(cur.indexOf(link)>=0) return 'DUP';
  const msg=cur?(cur+' '+link):(pre+link);
  ta.focus();
  const setv=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value').set;
  setv.call(ta,msg);
  ta.dispatchEvent(new Event('input',{bubbles:true}));
  ta.dispatchEvent(new Event('change',{bubbles:true}));
  const all=[...document.querySelectorAll('button')];
  const send=all.find(b=>{const a=(((b.getAttribute('aria-label')||'')+' '+(b.title||'')).toLowerCase());return /send|submit|傳送|發送/.test(a)&&!b.disabled;});
  if(send){send.click();return 'OK button';}
  const ev={key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true};
  ta.dispatchEvent(new KeyboardEvent('keydown',ev));
  ta.dispatchEvent(new KeyboardEvent('keypress',ev));
  ta.dispatchEvent(new KeyboardEvent('keyup',ev));
  return 'OK enter';
})()"
    set r1 to execute t javascript fillJs
    if r1 starts with "ERR" then error r1
    if r1 is "DUP" then return "DUP"
    -- 驗證: 輸入框已經唔再含住條連結 = 已送出（v4：最多查 3 次，每次隔 1.5 秒，
    -- 唔再 1 秒就判死刑）
    set chkJs to "(() => { const ta=document.querySelector('textarea'); const v=ta?((ta.value)||''):''; return v.indexOf(" & jsLink & ")>=0 ? 'STILL' : 'CLEARED'; })()"
    set r2 to "STILL"
    repeat 3 times
      delay 1.5
      try
        set r2 to execute t javascript chkJs
      end try
      if r2 is "CLEARED" then exit repeat
    end repeat
    if r2 is "STILL" then error "發送後輸入框仍保留連結，可能未成功送出"
    -- 發送成功：焦點自動交返發送前嗰個 app
    try
      if origApp is not "" and origApp is not "Google Chrome" then
        tell application "System Events" to set frontmost of first application process whose name is origApp to true
      end if
    end try
    return "SENT"
  end tell
end run

on jq(t)
  -- 轉成 JS 字串 literal（跳 backslash 同 double quote）
  set astid to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "\\"
  set tl to text items of t
  set AppleScript's text item delimiters to "\\\\"
  set t to tl as text
  set AppleScript's text item delimiters to "\""
  set tl to text items of t
  set AppleScript's text item delimiters to "\\\""
  set t to tl as text
  set AppleScript's text item delimiters to astid
  return "\"" & t & "\""
end jq
APPLESCRIPT
}

# v4：DUP 處理——輸入框已有同一條連結嗰陣，唔再追加。先查頁面訊息區係咪
# 已經有呢條連結（即上次其實送出咗），有→當已送；冇→清走輸入框，交主
# 循環計一次嘗試、退避後由空框再試，避免越填越滿。
resolve_dup() {
  osascript - "$MUSE_URL_KEYWORD" "$1" <<'APPLESCRIPT'
on run argv
  set urlKey to item 1 of argv
  set jsLink to my jq(item 2 of argv)
  tell application "Google Chrome"
    repeat with w in windows
      repeat with i from 1 to (count of tabs of w)
        try
          set t to tab i of w
          if URL of t contains urlKey then
            set pageJs to "(() => { const tx=(document.body&&document.body.innerText)||''; return tx.indexOf(" & jsLink & ")>=0 ? 'IN_PAGE' : 'NOT_IN_PAGE'; })()"
            set rp to execute t javascript pageJs
            if rp is "IN_PAGE" then return "IN_PAGE"
            set clrJs to "(() => { const ta=document.querySelector('textarea'); if(!ta) return 'NO_TA'; const setv=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value').set; setv.call(ta,''); ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new Event('change',{bubbles:true})); return 'BOX_CLEARED'; })()"
            execute t javascript clrJs
            return "BOX_CLEARED"
          end if
        end try
      end repeat
    end repeat
    return "NO_TAB"
  end tell
end run

on jq(t)
  set astid to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "\\"
  set tl to text items of t
  set AppleScript's text item delimiters to "\\\\"
  set t to tl as text
  set AppleScript's text item delimiters to "\""
  set tl to text items of t
  set AppleScript's text item delimiters to "\\\""
  set t to tl as text
  set AppleScript's text item delimiters to astid
  return "\"" & t & "\""
end jq
APPLESCRIPT
}

# v4：嘗試次數（以連結 md5 做檔名）
link_key() { md5 -qs "$1" 2>/dev/null || printf '%s' "$1" | md5sum | cut -d' ' -f1; }
attempts_get() { local f="${ATTEMPT_DIR}/$(link_key "$1")"; [ -f "$f" ] && cat "$f" || echo 0; }
attempts_set() { mkdir -p "$ATTEMPT_DIR"; echo "$2" > "${ATTEMPT_DIR}/$(link_key "$1")"; }
attempts_clear() { rm -f "${ATTEMPT_DIR}/$(link_key "$1")"; }
backoff_for() { case "$1" in 1) echo 10 ;; 2) echo 30 ;; 3) echo 90 ;; *) echo 300 ;; esac }
deadletter() { printf '[%s] %s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$DEADLETTER_FILE"; }

queue_contains() { [ -f "$QUEUE_FILE" ] && grep -Fxq "$1" "$QUEUE_FILE"; }
queue_head() { [ -f "$QUEUE_FILE" ] && head -n1 "$QUEUE_FILE"; }
queue_pop() { local tmp="${QUEUE_FILE}.tmp"; tail -n +2 "$QUEUE_FILE" > "$tmp" 2>/dev/null; mv "$tmp" "$QUEUE_FILE"; }

# ---- 主循環 ----
last_sent=""
[ -f "$STATE_FILE" ] && last_sent="$(cat "$STATE_FILE" 2>/dev/null)"
[ -n "$last_sent" ] && log "續用上次記錄，唔會重發: $last_sent"
touch "$QUEUE_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  log "── DRY RUN 模式：偵測到新連結只會印出嚟，唔會真係發送 ──"
fi

log "開始監測剪貼板（Ctrl+C 停止）…"
candidate=""
candidate_since=0
retry_at=0
consec_fail=0
chrome_log_at=0

while true; do
  now="$(date +%s)"

  # 1) 剪貼板 → 穩定 3 秒 → 入隊（唔直接發，唔會頂走未發嗰啲）
  link="$(extract_link "$(pbpaste 2>/dev/null)")"
  if [ -n "$link" ] && [ "$link" != "$last_sent" ] && ! queue_contains "$link"; then
    if [ "$link" != "$candidate" ]; then
      candidate="$link"
      candidate_since=$now
    elif [ $((now - candidate_since)) -ge "$STABLE_SEC" ]; then
      echo "$link" >> "$QUEUE_FILE"
      log "偵測到新連結，已入隊: $link"
      candidate=""
      candidate_since=0
    fi
  else
    candidate=""
    candidate_since=0
  fi

  # 2) 隊頭 → 發送（v4：有上限、有退避、超限入死信，唔再無限重試）
  head_link="$(queue_head)"
  if [ -n "$head_link" ] && [ "$now" -ge "$retry_at" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[DRY RUN] 會發送: $head_link"
      queue_pop
      last_sent="$head_link"
      sleep "$AFTER_SEND_WAIT"
    elif ! pgrep -f "Google Chrome" >/dev/null 2>&1; then
      # Chrome 冇開：唔呼叫 osascript（唔靠佢啟動 Chrome），唔計嘗試次數，
      # 60 秒後再睇；每 10 分鐘先至再寫一行 log，唔刷屏
      if [ $((now - chrome_log_at)) -ge 600 ]; then
        log "… Chrome 未開，隊頭暫候: $head_link"
        chrome_log_at=$now
      fi
      retry_at=$((now + 60))
    else
      send_out="$(send_to_muse "$head_link" 2>&1)"
      send_rc=$?
      send_out="$(printf '%s' "$send_out" | tail -n1)"
      if [ "$send_out" = "DUP" ]; then
        # 框內已有同一條連結：查係咪其實已送出
        dup_state="$(resolve_dup "$head_link" 2>/dev/null)"
        if [ "$dup_state" = "IN_PAGE" ]; then
          send_out="SENT"; send_rc=0
          log "（上次其實已送出，框內只係殘留）"
        else
          send_rc=1
          send_out="框內殘留連結，已清框（狀態: ${dup_state:-未知}）"
        fi
      fi
      if [ $send_rc -eq 0 ]; then
        log "✓ 已發送: $head_link"
        queue_pop
        attempts_clear "$head_link"
        consec_fail=0
        last_sent="$head_link"
        echo "$last_sent" > "$STATE_FILE"
        retry_at=0
        sleep "$AFTER_SEND_WAIT"
      else
        att=$(( $(attempts_get "$head_link") + 1 ))
        attempts_set "$head_link" "$att"
        consec_fail=$((consec_fail + 1))
        if [ "$att" -ge "$MAX_ATTEMPTS" ]; then
          log "✗ 已試 $att 次仍失敗，放棄並入死信（唔再重試）: $head_link"
          deadletter "$head_link" "attempts=$att last_error=$send_out"
          queue_pop
          attempts_clear "$head_link"
          retry_at=0
        elif [ "$consec_fail" -ge "$BREAKER_LIMIT" ]; then
          log "✗ 連續失敗 $consec_fail 次，熔斷暫停 $((BREAKER_PAUSE / 60)) 分鐘"
          retry_at=$((now + BREAKER_PAUSE))
          consec_fail=0
        else
          bo="$(backoff_for "$att")"
          log "✗ 發送失敗（第 $att/$MAX_ATTEMPTS 次，${bo} 秒後再試）: $send_out"
          retry_at=$((now + bo))
        fi
      fi
    fi
  fi

  sleep "$POLL_SEC"
done
