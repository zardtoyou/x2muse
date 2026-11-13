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
#
# 用法:
#   ./x2muse.sh             正常運行（Ctrl+C 停止）
#   ./x2muse.sh --dry-run   只偵測唔發送（測試用）
#   ./x2muse.sh --reset     清除「已發送」記錄（可以重發上一條）
#
# 背景行:
#   nohup ./x2muse.sh > "$TMPDIR/x2muse.log" 2>&1 &

# ---------- 設定 ----------
MUSE_URL_KEYWORD="muse.ai"     # 目標分頁 = 網址包含呢個字串嘅任何 Chrome 分頁（唔使係 active tab）
                               # 想鎖死某一個 chat thread，可以填網址一段，例如:
                               # MUSE_URL_KEYWORD="muse.ai/thread/YOUR_THREAD_ID"
PREPEND_TEXT="请用免费车道分析这条链接，哪里对我的项目有帮助：先把原文读完（看不到正文就找评论区或镜像，不要只看标题），再逐项对照我的在研项目和舰队工具流——判断哪一条真正用得上、用在哪一步、能帮到什么；用不上的直说无帮助，不要凑数，不要复述内容。最后给一个分档结论（直接可用／有启发／无关忽略）和一句具体的下一步建议。链接："   # 輸入框係空嘅時候用嘅提示文字（作者的用法示例，換成你自己的提問即可）
POLL_SEC=1                     # 輪詢剪貼板間隔（秒）
STABLE_SEC=3                   # 新連結要穩定存在幾耐先發送（秒）
AFTER_SEND_WAIT=5              # 發送後冷靜期（秒）
STATE_FILE="${TMPDIR:-/tmp}/x2muse_last_sent"
# --------------------------

DRY_RUN=0
case "$1" in
  --dry-run) DRY_RUN=1 ;;
  --reset)   rm -f "$STATE_FILE"; echo "已清除發送記錄。"; exit 0 ;;
esac

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

extract_link() {
  printf '%s' "$1" \
    | grep -Eio 'https?://(www\.)?(x|twitter)\.com/[A-Za-z0-9_?=/&.%~-]+' \
    | head -n1 | sed -E 's/[.,;:!?)\]]+$//'
}

send_to_muse() {
  osascript - "$MUSE_URL_KEYWORD" "$1" "$PREPEND_TEXT" <<'APPLESCRIPT'
on run argv
  set urlKey to item 1 of argv
  set jsLink to my jq(item 2 of argv)
  set jsPre to my jq(item 3 of argv)

  -- 記低發送前用戶正用緊邊個 app，發送後交返焦點俾佢，唔使人手切返轉頭
  set origApp to ""
  try
    tell application "System Events" to set origApp to name of first application process whose frontmost is true
  end try

  tell application "Google Chrome"
    repeat with w in windows
      repeat with i from 1 to (count of tabs of w)
        try
          set t to tab i of w
          if URL of t contains urlKey then
            -- 唔再將窗口推到最前／切換分頁／activate：execute javascript
            -- 本身唔使分頁喺前景，背景執行就唔會搶走用戶畫面
            set fillJs to "(() => {
  const link=" & jsLink & ";
  const pre=" & jsPre & ";
  const ta=document.querySelector('textarea');
  if(!ta) return 'ERR no textarea';
  const cur=(ta.value||'').trim().replace(/\\s+$/,'');
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
            delay 1
            -- 驗證: 輸入框已經唔再含住條連結 = 已送出
            set chkJs to "(() => { const ta=document.querySelector('textarea'); const v=ta?((ta.value)||''):''; return v.indexOf(" & jsLink & ")>=0 ? 'STILL' : 'CLEARED'; })()"
            set r2 to execute t javascript chkJs
            if r2 is "STILL" then error "發送後輸入框仍保留連結，可能未成功送出"
            -- 發送成功：焦點自動交返發送前嗰個 app（原本喺 Chrome 就唔使郁，
            -- 畫面／分頁由頭到尾冇變過）；用戶唔使再做多一步人手返回
            try
              if origApp is not "" and origApp is not "Google Chrome" then
                tell application "System Events" to set frontmost of first application process whose name is origApp to true
              end if
            end try
            return "SENT"
          end if
        end try
      end repeat
    end repeat
    error "搵唔到任何分頁網址包含「" & urlKey & "」嘅 Chrome 窗口"
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

# ---- 主循環 ----
last_sent=""
[ -f "$STATE_FILE" ] && last_sent="$(cat "$STATE_FILE" 2>/dev/null)"
[ -n "$last_sent" ] && log "續用上次記錄，唔會重發: $last_sent"

if [ "$DRY_RUN" -eq 1 ]; then
  log "── DRY RUN 模式：偵測到新連結只會印出嚟，唔會真係發送 ──"
fi

log "開始監測剪貼板（Ctrl+C 停止）…"
pending=""
pending_since=0

while true; do
  link="$(extract_link "$(pbpaste 2>/dev/null)")"
  now="$(date +%s)"

  if [ -n "$link" ] && [ "$link" != "$last_sent" ]; then
    if [ "$link" != "$pending" ]; then
      pending="$link"
      pending_since=$now
      log "偵測到新連結，${STABLE_SEC} 秒後發送: $link"
    elif [ $((now - pending_since)) -ge "$STABLE_SEC" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "[DRY RUN] 會發送: $link"
        last_sent="$link"
        pending=""
        sleep "$AFTER_SEND_WAIT"
      elif send_to_muse "$link"; then
        log "✓ 已發送: $link"
        last_sent="$link"
        pending=""
        echo "$last_sent" > "$STATE_FILE"
        sleep "$AFTER_SEND_WAIT"
      else
        log "✗ 發送失敗（見上面錯誤），10 秒後重試同一條"
        pending_since=$((now - STABLE_SEC + 10))
      fi
    fi
  else
    pending=""
    pending_since=0
  fi

  sleep "$POLL_SEC"
done
