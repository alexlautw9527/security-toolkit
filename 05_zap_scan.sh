#!/bin/bash
# 第五步：用 ZAP Automation Framework 一次跑完（spider + 被動掃描；經授權才加有限主動掃描）。
# ZAP 以 -cmd -silent -autorun 在本機 headless 執行，掃描 home 目錄隔離在輸出內的 zap_home，結束即退出不常駐。
# 用法：
#   ./05_zap_scan.sh                        # 自動偵測 HTTP/HTTPS scope，只做被動
#   ./05_zap_scan.sh <urls.txt>             # 改用指定 URL 清單當 scope
#   APPROVED_ACTIVE=yes ./05_zap_scan.sh --active   # 追加有限主動掃描
# 主動掃描與被動掃描都只吃「已核准」的 scope；主動掃描需 --active 與 APPROVED_ACTIVE=yes 雙重確認。
# 產出：zap_<時間戳>/，含 zap_report.html（報告）、plan.yaml（automation plan）、scope.txt、progress.log、zap_home。
set -u -o pipefail
# SCAN_OUTPUT_DIR 指定「最終輸出目錄」：start_scan.sh 會傳該輪 run 資料夾下的 zap 子目錄；
# 未設定（手動執行）時在目前目錄建 zap_<時間戳>，避免覆蓋前一次結果。
OUT="${SCAN_OUTPUT_DIR:-zap_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"
LOG="$OUT/progress.log"

# 解析參數：--active 啟用主動掃描；其餘參數視為 URL 清單檔路徑。
ACTIVE=no
URLFILE=""
for arg in "$@"; do
  case "$arg" in
    --active) ACTIVE=yes ;;
    *) [ -f "$arg" ] && URLFILE="$arg" || { echo "未知參數：$arg" | tee "$LOG"; exit 1; } ;;
  esac
done
# 授權未過時直接擋下主動掃描，避免誤啟動對生產環境的主動測試。
if [ "$ACTIVE" = yes ] && [ "${APPROVED_ACTIVE:-no}" != yes ]; then
  echo "主動掃描需醫院另行同意：APPROVED_ACTIVE=yes ./05_zap_scan.sh --active" | tee "$LOG"
  exit 1
fi

# 找 ZAP 執行檔：優先查 macOS app bundle，其次 PATH。找不到就提示安裝方式。
ZAP=""
for p in "/Applications/ZAP.app/Contents/Java/zap.sh" \
         "/Applications/OWASP ZAP.app/Contents/Java/zap.sh" \
         "$(command -v zap.sh 2>/dev/null || true)"; do
  [ -n "$p" ] && [ -x "$p" ] && ZAP="$p" && break
done
if [ -z "$ZAP" ]; then
  echo "找不到 ZAP，安裝：brew install --cask zaproxy" | tee "$LOG"
  exit 1
fi

# 決定 Web scope：指定 URL 清單就直接使用；否則自動對 targets.txt 每台跑 HTTP/HTTPS 探測，
# 有回應的才列入。最後 sort -u 去重，避免同一主機重複掃。
SCOPE="$OUT/scope.txt"
if [ -n "$URLFILE" ]; then
  cp "$URLFILE" "$SCOPE"
else
  : > "$SCOPE"
  while read -r ip; do
    for scheme in http https; do
      if curl -k -sI --connect-timeout 5 --max-time 10 "$scheme://$ip" >/dev/null 2>&1; then
        echo "${scheme}://$ip" >> "$SCOPE"
      fi
    done
  done < targets.txt
fi
sort -u -o "$SCOPE" "$SCOPE"
if [ ! -s "$SCOPE" ]; then
  echo "沒有任何 HTTP/HTTPS 主機回應，沒有可掃描的 Web scope，結束。" | tee "$LOG"
  exit 0
fi
echo "Web scope（${SCOPE}）" | tee -a "$LOG"
cat "$SCOPE" | tee -a "$LOG"

# 產生 automation plan（spider → 被動掃描 → 報告；授權才加主動）。
# spider 在此不爬整個網站，只做有限遍歷（maxDuration 20 分鐘上限），避免刺激生產服務。
# 只要啟動任何主動掃描，就套用低強度（low）＋高門檻（high threshold）＋每請求延遲 200ms，
# 並限制單規則最多 1 分鐘、整輪最多 30 分鐘；HAPI 範圍限制由授權與 scope 決定，不在本檔處理。
PLAN="$PWD/$OUT/plan.yaml"
{
  echo "env:"
  echo "  contexts:"
  echo "    - name: hospital"
  echo "      urls:"
  sed 's/^/        - /' "$SCOPE"
  echo "  parameters:"
  echo "    failOnError: false"
  echo "    failOnWarning: false"
  echo "    progressToStdout: true"
  echo "jobs:"
  echo "  - type: spider"
  echo "    parameters:"
  echo "      context: hospital"
  echo "      maxDuration: 20"
  echo "  - type: passiveScan-config"
  echo "  - type: passiveScan-wait"
  echo "    parameters:"
  echo "      maxDuration: 5"
  if [ "$ACTIVE" = yes ]; then
    echo "  - type: activeScan"
    echo "    parameters:"
    echo "      context: hospital"
    echo "      maxScanDurationInMins: 30"
    echo "      maxRuleDurationInMins: 1"
    echo "      delayInMs: 200"
    echo "    policyDefinition:"
    echo "      defaultStrength: low"
    echo "      defaultThreshold: high"
  fi
  echo "  - type: report"
  echo "    parameters:"
  echo "      template: traditional-html"
  echo "      reportDir: $PWD/$OUT"
  echo "      reportFile: zap_report"
} > "$PLAN"

echo "ZAP automation 開始 $(date '+%H:%M:%S')，plan: $PLAN" | tee -a "$LOG"
# -dir 指定獨立的 ZAP home，隔離偏好設定與資料庫，避免污染主機上既有的 ZAP 使用環境。
"$ZAP" -cmd -silent -autorun "$PLAN" -dir "$PWD/$OUT/zap_home" 2>&1 | tee -a "$LOG"
RC=$?
echo "ZAP 退出碼 ${RC}（0=無錯誤無警告，2=有警告）。報告：$OUT/zap_report.html" | tee -a "$LOG"
exit 0