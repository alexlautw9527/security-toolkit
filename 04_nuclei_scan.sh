#!/bin/bash
# 第四步：以 Nuclei 對授權主機掃描。
# 預設只用 exposure、misconfig、cve 三類模板，排除 brute、fuzz、intrusive 等破壞性模板，維持非破壞。
# 結果是「疑似」線索，需人工驗證，不直接當作弱點定論。
# 目標清單：NUCLEI_TARGETS（start_scan.sh 餵 Web scope URL 清單）或預設 targets.txt。
# 限縮範圍（冒煙或時間緊迫時用）：
#   NUCLEI_TEMPLATES  指定單一模板檔案或目錄取代 -tags（例：跑冒煙限 http/miscellaneous，幾分鐘內收尾）
#   NUCLEI_TAGS / NUCLEI_ETAGS  改模板類別與排除類別
# 產出：nuclei_<時間戳>/，含 nuclei.jsonl（每行一筆發現）與 progress.log。
set -u
# SCAN_OUTPUT_DIR 指定「最終輸出目錄」：start_scan.sh 會傳該輪 run 資料夾下的 nuclei 子目錄；
# 未設定（手動執行）時在目前目錄建 nuclei_<時間戳>，避免覆蓋前一次結果。
OUT="${SCAN_OUTPUT_DIR:-nuclei_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"
LOG="$OUT/progress.log"
# 目標來源：start_scan.sh 會以 Web scope URL 清單覆寫，手動執行時預設讀 targets.txt。
TARGETS="${NUCLEI_TARGETS:-targets.txt}"
TMPL="${NUCLEI_TEMPLATES:-}"
TAGS="${NUCLEI_TAGS:-exposure,misconfig,cve}"
ETAGS="${NUCLEI_ETAGS:-brute,fuzz,intrusive}"

# 先檢查 nuclei 是否安裝，缺工具直接中止並提示安裝方式，避免跑出空結果。
command -v nuclei >/dev/null 2>&1 || { echo "缺 nuclei，安裝：brew install projectdiscovery/tap/nuclei" | tee "$LOG"; exit 1; }

# 嘗試更新模板；離線或失敗不中斷（沿用既有模板），避免被網路問題卡住。
echo "更新模板（離線或失敗不影響既有模板）" | tee "$LOG"
nuclei -update-templates >/dev/null 2>&1 || true

echo "掃描開始 $(date '+%H:%M:%S')，目標 ${TARGETS}，輸出目錄 $OUT" | tee -a "$LOG"
# 指定 NUCLEI_TEMPLATES 時用 -t 縮到單一模板/目錄（取代 -tags）；否則沿用 -tags/-etags 限定類別。
# -no-interactsh 停用外部 OOB 交互伺服器，-rate-limit 控每秒請求量，-concurrency 控並行數，-stats 定期印進度。
if [ -n "$TMPL" ]; then
  nuclei -l "$TARGETS" \
    -t "$TMPL" \
    -etags "$ETAGS" \
    -no-interactsh \
    -rate-limit 20 -concurrency 50 -timeout 10 -retries 1 \
    -stats -stats-interval 5 \
    -jsonl -o "$OUT/nuclei.jsonl" 2>&1 | tee -a "$LOG"
else
  nuclei -l "$TARGETS" \
    -tags "$TAGS" \
    -etags "$ETAGS" \
    -no-interactsh \
    -rate-limit 20 -concurrency 50 -timeout 10 -retries 1 \
    -stats -stats-interval 5 \
    -jsonl -o "$OUT/nuclei.jsonl" 2>&1 | tee -a "$LOG"
fi

COUNT=$(wc -l < "$OUT/nuclei.jsonl" 2>/dev/null || echo 0)
echo "掃描結束，發現 $COUNT 條。原始結果：$OUT/nuclei.jsonl" | tee -a "$LOG"