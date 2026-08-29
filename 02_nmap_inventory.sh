#!/bin/bash
# 第二步：nmap 服務盤點。
# 逐台盤點 targets.txt 內全部主機，單台失敗不中斷。預設依序；NMAP_PARALLEL=n（>1）時一次並行掃 n 台。
# 預設只跑前段盤點（前 1000 常用埠 + 版本偵測）；需要 NSE 補強時以環境變數開啟：
#   RUN_SAFE_SCRIPTS=1  跑 "default and safe" NSE
#   RUN_VULNERS=1       跑 vulners NSE（逐服務全版本探測，最慢）
# 產出：nmap_<時間戳>/，含各主機的 inventory_<ip>.{nmap,gnmap,xml}、open_ports.csv 彙整、progress.log。
# 後續 Web scope（start_scan.sh）以 open_ports.csv 為唯一來源。
set -u
# SCAN_OUTPUT_DIR 指定「最終輸出目錄」：start_scan.sh 會傳該輪 run 資料夾下的 nmap 子目錄；
# 未設定（手動執行）時在目前目錄建 nmap_<時間戳>，避免覆蓋前一次結果。
OUT="${SCAN_OUTPUT_DIR:-nmap_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"
LOG="$OUT/progress.log"
# open_ports.csv 格式：target,port,service，供 start_scan.sh 篩出 Web 主機。
CSV="$OUT/open_ports.csv"

# 載入 targets.txt，忽略空行。
HOSTS=()
while IFS= read -r h; do HOSTS+=("$h"); done < <(grep -vE '^[[:space:]]*$' targets.txt)
TOTAL=${#HOSTS[@]}
: > "$LOG"
echo "target,port,service" > "$CSV"

# 並行度：NMAP_PARALLEL 非正整數一律視為依序。上限 9（與目標總數一致），避免超過授權範圍同時打太多台。
NP="${NMAP_PARALLEL:-1}"
case "$NP" in (*[!0-9]*|'') NP=1;; esac
[ "$NP" -gt 9 ] && NP=9
[ "$NP" -le 0 ] && NP=1

scan_host() {
  # scan_host <主機> <序號> <進度檔>：盤點單台（盤點 + 選配 safe/vulners NSE），寫入指定進度檔。
  local h="$1" i="$2" L="$3"
  echo "[$i/$TOTAL] $h 掃描開始 $(date '+%H:%M:%S')" | tee -a "$L"

  # 保守服務盤點：前 1000 常用埠，不含 exploit 或 DoS 腳本。
  # -Pn 不做 host discovery（VPN 內主機可能不回 ICMP）、-sT TCP connect、-sV 版本偵測、--version-light 加快。
  sudo nmap -Pn -sT -sV --version-light -T3 --top-ports 1000 \
    "$h" -oA "$OUT/inventory_${h}" 2>&1 | tee -a "$L" || true

  # safe NSE 集合，補足版本與弱點線索。這一段比前面的 -sV 盤點慢不少，
  # 且部分腳本要連外部服務，預設關閉避免拖慢掃描，需 RUN_SAFE_SCRIPTS=1 開啟。
  if [ "${RUN_SAFE_SCRIPTS:-0}" = "1" ]; then
    sudo nmap -Pn -sT -sV -T3 \
      --script "default and safe" --script-timeout 300s \
      "$h" -oA "$OUT/safe_${h}" 2>&1 | tee -a "$L" || true
  else
    echo "[$i/$TOTAL] $h 略過 safe NSE（設定 RUN_SAFE_SCRIPTS=1 開啟）" | tee -a "$L"
  fi

  # vulners NSE：對偵測到的服務版本比對公開 CVE 資料庫，只做已知版本線索、不打連線。
  # 需要 noc.nmap.org 或 vulners.com 可達；離線時會顯示警告但不中斷掃描。
  # --version-all 逐服務全版本探測，最慢，預設關閉，需 RUN_VULNERS=1 開啟。
  if [ "${RUN_VULNERS:-0}" = "1" ]; then
    sudo nmap -Pn -sT -sV --version-all -T3 \
      --script "vulners" --script-timeout 300s \
      "$h" -oA "$OUT/vulners_${h}" 2>&1 | tee -a "$L" || true
  else
    echo "[$i/$TOTAL] $h 略過 vulners（設定 RUN_VULNERS=1 開啟）" | tee -a "$L"
  fi

  echo "[$i/$TOTAL] $h 掃描結束 $(date '+%H:%M:%S')" | tee -a "$L"
}

echo "總共 $TOTAL 台，並行度 ${NP}，輸出目錄 $OUT" | tee "$LOG"

i=0
if [ "$NP" -le 1 ]; then
  # 依序：全部輸出直接寫進 progress.log，維持既有可讀性。
  for h in "${HOSTS[@]}"; do
    i=$((i + 1))
    scan_host "$h" "$i" "$LOG"
  done
else
  # 並行：每台寫自己的進度檔，滑動視窗最多 NP 台同時跑，全部結束後合併進 progress.log。
  pids=()
  for h in "${HOSTS[@]}"; do
    i=$((i + 1))
    scan_host "$h" "$i" "$OUT/progress_${h}.log" &
    pids+=("$!")
    while [ "${#pids[@]}" -ge "$NP" ]; do
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
    done
  done
  wait
  cat "$OUT"/progress_*.log >> "$LOG" 2>/dev/null || true
fi

# 彙整所有可用的 gnmap（safe_* 或 inventory_*）open ports 進 CSV。
# 只要 safe 或 inventory 任一存在就納入，避免同一台重複列。
for g in "$OUT"/safe_*.gnmap "$OUT"/inventory_*.gnmap; do
  [ -f "$g" ] || continue
  # 從 gnmap 的 Ports: 欄位解析：每個 open 埠取 IP、埠號、service 名稱，寫成 csv 一列。
  awk -v f="$g" '
    /Ports:/ {
      split($0, rest, "Ports: ")
      n = split(f, arr, "/"); base = arr[n]
      split(base, arr2, "_"); ip = arr2[2]; sub(/\.gnmap$/, "", ip)
      n = split(rest[2], ports, ",")
      for (k = 1; k <= n; k++) {
        split(ports[k], p, "/")
        if (p[2] == "open") print ip "," p[1] "," p[5]
      }
    }' "$g"
done | sort -u >> "$CSV"

echo "==== Open ports 彙整 ===="
column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
echo "完成，輸出目錄：$OUT"