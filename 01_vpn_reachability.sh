#!/bin/bash
# 第一步：VPN 連通性檢查。
# 產出：results_<時間戳>/，內含 routes.txt（路由表）與 reachability.txt（ping 與常見埠結果）。
# 前提：已連上 VPN，目標網段可達。本步不發送攻擊封包，純連通性確認。
# 注意：nc -G 的支援隨 macOS 版本而異，若不支援改用 -w 1。
# 加速：縮短 ping/連線 timeout，並以 PING_PARALLEL 控制跨台並行（預設 4，連通性負荷極輕）。
#   設成 1 即回到逐台依序執行。以慢目標的單埠 timeout 估算最壞時間，與並行數無關的等待上限。
set -u
# SCAN_OUTPUT_DIR 指定「最終輸出目錄」：start_scan.sh 會傳該輪 run 資料夾下的 reachability 子目錄；
# 未設定（手動執行）時在目前目錄建 reachability_<時間戳>，避免覆蓋前一次結果。
OUT="${SCAN_OUTPUT_DIR:-reachability_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"

# 先記錄路由表，確認 VPN 網段（如 172.28.14.0/24）確實在路由表中，才能判斷連線狀態是否正常。
echo "== Route table ==" | tee "$OUT/routes.txt"
netstat -rn | tee -a "$OUT/routes.txt"

echo "== Reachability / common ports =="
# 並行上限：環境變數可調，預設 4。
PARALLEL="${PING_PARALLEL:-4}"

# 單台檢查：輸出寫入各台自己的暫存檔，ping 與 10 個常見埠的結果都往該檔 append。
check_host() {
  local ip="$1" f="$2"
  {
    echo "### $ip"
    # -c 1 只測一次；-W 500 每包最多等 0.5 秒。
    ping -c 1 -W 500 "$ip" 2>&1
    # 常見服務埠：22 SSH、80/443 Web、3389 RDP、5432 PostgreSQL、3306 MySQL、
    # 1521 Oracle、1433 MSSQL、8443/8080 常見替代 Web 埠。-G 1 單埠最多等 1 秒。
    for p in 22 80 443 3389 5432 3306 1521 1433 8443 8080; do
      nc -G 1 -zv "$ip" "$p" 2>&1
    done
  } > "$f"
}

# 從 targets.txt 讀主機，去掉空行；每累積到 PARALLEL 台就等一批跑完，控制同時在測的家數。
# read 條件帶 [ -n "$ip" ]：handle targets.txt 最後一行沒有結尾換行時（bash 3.2 的 read
# 對這情況回傳非零），否則最後一台主機不會被掃到。
TMPD="$OUT/.reach_tmp"
mkdir -p "$TMPD"
i=0
while read -r ip || [ -n "$ip" ]; do
  [ -n "$ip" ] || continue
  i=$((i + 1))
  check_host "$ip" "$TMPD/h$i" &
  if [ $((i % PARALLEL)) -eq 0 ]; then
    wait
  fi
done < targets.txt
wait

# 依 targets.txt 順序合併各台輸出，避免背景完成的先後造成結果交錯。
for f in "$TMPD"/h*; do
  cat "$f" >> "$OUT/reachability.txt"
done
rm -rf "$TMPD"

# 退出碼語意：只要有一台任一探測成功（ping 收到回應或 nc succeeded）就回傳 0；
# 全部失敗時回傳 1，讓 start_scan.sh 能在步驟間停止，不讓掃描在未連上 VPN 時白跑。
if grep -qE '1 packets received|succeeded' "$OUT/reachability.txt"; then
  echo "Reachability: OK（至少一台有回應，後續步驟可繼續）"
  echo "Results: $OUT"
  exit 0
else
  echo "Reachability: FAIL（沒有任何主機回應，疑 VPN 未連上）" >&2
  echo "Results: ${OUT}（該目錄無有效探測，勿作為後續掃描依據）" >&2
  exit 1
fi