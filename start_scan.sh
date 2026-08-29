#!/bin/bash
# 統一入口：依序執行三步掃描流程
#   1. 連通性   -> ./01_vpn_reachability.sh        （results_*）
#   2. nmap     -> sudo ./02_nmap_inventory.sh      （nmap_*，open_ports.csv）
#   3. Web scope：由 nmap 的 open_ports.csv 產生可掃 URL 清單（run_*/web_scope.txt），
#      只有 nmap 標出 Web 埠的主機才進 04_nuclei_scan.sh 與 05_zap_scan.sh
#   4. SSH 主機稽核與 ClamAV 不在此腳本：另跑 ./start_host.sh（稽核）與 ./start_clam.sh（ClamAV）
#
# 用法：
#   ./start_scan.sh                                     # 跑 1-3 與 Web 掃描
#   APPROVED_ACTIVE=yes ./start_scan.sh --active        # 05 追加有限主動掃描（未授權時 05 會攔下）
#
# 環境變數：
#   APPROVED_ACTIVE 05 的主動掃描授權（需搭配 --active）
#
# 刻意不含 OpenVAS／Greenbone：單台深度複驗太費時，只留給人工複驗後確認為
# 高風險的主機，由操作者手動照 README「選配」章節執行，不在預設流程內。
set -u

cd "$(dirname "$0")" || exit 1
[ -s targets.txt ] || { echo "缺少 targets.txt（受測主機清單）"; exit 1; }

# 本輪執行的工作目錄與流水日誌，所有步驟的輸出都追加進 progress.log。
# 一輪掃描固定一個 RUN_ID（時間戳），該輪所有工具產出統一在 outputs/<RUN_ID>/ 下，
# 各工具再分 reachability、nmap、nuclei、zap、run 子目錄，同輪關聯一目了然；
# outputs 根可用 SCAN_OUTPUT_DIR 覆寫。
OUT_ROOT="${SCAN_OUTPUT_DIR:-outputs}"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$OUT_ROOT/$RUN_ID"
LOGDIR="$RUN_DIR/run"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/progress.log"
: > "$LOG"
T0=$(date +%s)
log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
step() { echo ""; echo "########## $* ##########" | tee -a "$LOG"; }

# 背景進度心跳：每 HEARTBEAT_INTERVAL 秒（預設 60）印一次耗時，開頭帶 ASCII spinner
# （- \ | / 依輪次輪替）讓操作者一眼看出流程仍在進行，又不洗流程日誌。
HB_INTERVAL="${HEARTBEAT_INTERVAL:-60}"
HB_SPIN=('-' '\' '|' '/')
( while :; do
    sleep "$HB_INTERVAL"
    IDX=$(( ($(date +%s) / HB_INTERVAL) % 4 ))
    echo "${HB_SPIN[$IDX]} 已耗時 $(( $(date +%s) - T0 )) 秒"
  done ) &
HB=$!
trap 'kill "$HB" 2>/dev/null' EXIT

# 解析命令列旗標：出現 --active 就把 ACTIVE 設為 yes，交給 step 3 決定 ZAP 是否做主動掃描。
ACTIVE=no
for arg in "$@"; do
  [ "$arg" = "--active" ] && ACTIVE=yes
done

# ---------- step 1: 連通性 ----------
step "1/3 連通性檢查（路由、ping、常見埠）"
SCAN_OUTPUT_DIR="$RUN_DIR/reachability" ./01_vpn_reachability.sh 2>&1 | tee -a "$LOG"
RC01=${PIPESTATUS[0]}
# 連通性完全失敗（沒有任何主機回應）時，01 會回傳非零；此時中止，
# 避免在未連上 VPN 的前提下白跑 nmap 與後續 Web 掃描。
if [ "$RC01" -ne 0 ]; then
  log "step 1 連通性失敗：沒有任何主機回應。先確認 VPN 連上且 targets.txt 正確，再重跑 start_scan.sh。"
  exit 1
fi

# ---------- step 2: nmap 盤點 ----------
step "2/3 nmap 服務盤點（需 sudo）"
# 互動詢問是否追加只出「線索」的 NSE，預設關閉：
#   RUN_SAFE_SCRIPTS=1  補旗標與已知弱點線索（default and safe），較慢
#   RUN_VULNERS=1       vulners CVE 版本比對（--version-all），最慢
# 環境變數先設好就跳過詢問；非互動模式（冒煙/CI）也不問。
SAFE="${RUN_SAFE_SCRIPTS:-0}"
VUL="${RUN_VULNERS:-0}"
if [ -z "${RUN_SAFE_SCRIPTS:-}" ] && [ -t 0 ] && [ -t 1 ]; then
  read -r -p "追加 default and safe NSE（補安全線索，較慢）？[y/N] " a
  [ "$a" = "y" ] || [ "$a" = "Y" ] && SAFE=1
fi
if [ -z "${RUN_VULNERS:-}" ] && [ -t 0 ] && [ -t 1 ]; then
  read -r -p "追加 vulners CVE 比對（逐服務全版本探測，最慢）？[y/N] " a
  [ "$a" = "y" ] || [ "$a" = "Y" ] && VUL=1
fi
# 並行度：PARALLEL=n（>1）時 02 一次掃 n 台、step 3 的 nuclei 與 zap 同時跑。
# 預設 9：與 targets.txt 的 9 台目標一致，對全部主機同時掃；不想全並行的操作者用手動設回較小值。
PAR="${PARALLEL:-9}"
case "$PAR" in (*[!0-9]*|'') PAR=9;; esac
[ "$PAR" -gt 9 ] && PAR=9
[ "$PAR" -le 0 ] && PAR=1
log "nmap 參數：RUN_SAFE_SCRIPTS=$SAFE RUN_VULNERS=$VUL 並行度=${PAR}"
sudo RUN_SAFE_SCRIPTS=$SAFE RUN_VULNERS=$VUL NMAP_PARALLEL=$PAR SCAN_OUTPUT_DIR=$RUN_DIR/nmap ./02_nmap_inventory.sh 2>&1 | tee -a "$LOG"

# ---------- step 3: 由 nmap 產生 Web scope，接 nuclei 與 zap ----------
step "3/3 Web scope（nmap 結果 -> ZAP / Nuclei）"
# open_ports.csv 唯一來源：本輪 nmap 子目錄的彙整表。
if [ -f "$RUN_DIR/nmap/open_ports.csv" ]; then
  CSV="$RUN_DIR/nmap/open_ports.csv"
else
  CSV=""
fi

if [ -z "$CSV" ]; then
  log "step 2 未產出 nmap_*/open_ports.csv，跳過 Web 掃描。"
else
  XSCOPE="$LOGDIR/web_scope.txt"
  : > "$XSCOPE"
  # Web scope 完全以 nmap 的 service 欄位為準：判成含 http 的服務才進清單，
  # 不另外用固定埠號猜，避免遺漏 nmap 偵測到的非標準 Web 埠。
  while IFS=, read -r ip port svc; do
    [ -n "$ip" ] || continue
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    [[ "$svc" == *http* ]] || continue
    # 依服務推測優先 scheme：ssl/https 先試 https，其餘先試 http。
    if [[ "$svc" == *ssl* ]] || [[ "$svc" == https ]] || [[ "$svc" == *https* ]]; then
      cand1="https://$ip"; cand2="http://$ip"
    else
      cand1="http://$ip"; cand2="https://$ip"
    fi
    # 非標準埠（非 80/443）要帶上埠號。
    if [ "$port" != 80 ] && [ "$port" != 443 ]; then
      cand1="${cand1}:${port}"; cand2="${cand2}:${port}"
    fi
    # 用 curl HEAD 實測哪個 scheme 真的有回應，取第一個成功的寫入 scope；避免把不存在的假 URL 列進去。
    for u in "$cand1" "$cand2"; do
      if curl -k -sI --connect-timeout 5 --max-time 10 "$u" >/dev/null 2>&1; then
        echo "$u" >> "$XSCOPE"
        break
      fi
    done
  done < "$CSV"
  sort -u -o "$XSCOPE" "$XSCOPE"
  COUNT=$(wc -l < "$XSCOPE" 2>/dev/null || echo 0)
  log "Web scope：${XSCOPE}（${COUNT} 個 URL）"
  cat "$XSCOPE" | tee -a "$LOG"
  # 有 Web 標的才接 04 與 05；完全不回應就記錄跳過，避免空掃描浪費時間。
  if [ "$COUNT" -gt 0 ]; then
    if [ "${PAR}" -gt 1 ]; then
      # 並行：nuclei 與 zap 是兩個獨立工具，同時跑可省一段時間。
      log "並行執行 04 nuclei 與 05 ZAP"
      ( SCAN_OUTPUT_DIR=$RUN_DIR/nuclei NUCLEI_TARGETS="$XSCOPE" ./04_nuclei_scan.sh 2>&1 | tee -a "$LOG" ) &
      P_N=$!
      if [ "$ACTIVE" = yes ]; then
        ( SCAN_OUTPUT_DIR=$RUN_DIR/zap ./05_zap_scan.sh "$XSCOPE" --active 2>&1 | tee -a "$LOG" ) &
      else
        ( SCAN_OUTPUT_DIR=$RUN_DIR/zap ./05_zap_scan.sh "$XSCOPE" 2>&1 | tee -a "$LOG" ) &
      fi
      P_Z=$!
      wait "$P_N" "$P_Z"
      log "04/05 已並行完成"
    else
      log "執行 04 nuclei（只掃 Web scope）"
      SCAN_OUTPUT_DIR=$RUN_DIR/nuclei NUCLEI_TARGETS="$XSCOPE" ./04_nuclei_scan.sh 2>&1 | tee -a "$LOG"
      log "執行 05 ZAP 被動掃描"
      if [ "$ACTIVE" = yes ]; then
        SCAN_OUTPUT_DIR=$RUN_DIR/zap ./05_zap_scan.sh "$XSCOPE" --active 2>&1 | tee -a "$LOG"
      else
        SCAN_OUTPUT_DIR=$RUN_DIR/zap ./05_zap_scan.sh "$XSCOPE" 2>&1 | tee -a "$LOG"
      fi
    fi
  else
    log "沒有任何 Web 主機回應，跳過 04/05。"
  fi
fi

# ---------- step 4: SSH 主機稽核與 ClamAV ----------
step "主機稽核與 ClamAV 請另行執行"
log "主機稽核請另行執行：SSH_USER=<登入帳號> ./start_host.sh"
log "ClamAV 掃描（縮緊主機範圍後）：SSH_USER=<登入帳號> ./start_clam.sh <清單>"

echo ""
echo "==== start_scan.sh 完成，輸出：$LOGDIR ===="
ls -1 "$LOGDIR" | tee -a "$LOG"