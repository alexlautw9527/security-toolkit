#!/bin/bash
# 主機稽核主控：並行對多台目標 Ubuntu 主機執行 ubuntu_host_audit.sh（純稽核，不含 ClamAV）。
# 並行度由 PARALLEL 決定，與 start_scan.sh 的 step 2／3 共用同一套並行參數。
#
# 用法：
#   SSH_USER=user ./start_host.sh                 # 稽核 targets.txt 全部
#   SSH_USER=user ./start_host.sh some_hosts.txt  # 稽核指定清單
#
# 環境變數：
#   SSH_USER         登入帳號（必要）。此屬「已授權的身分」登入，先向委託單位確認範圍。
#   PARALLEL         並行台數（預設 9）
#   SCAN_OUTPUT_DIR  產出根目錄（預設 outputs/，一輪一個 audit_<時間戳> 子目錄）
set -u

cd "$(dirname "$0")" || exit 1
TARGETS="${1:-targets.txt}"

[ -n "${SSH_USER:-}" ] || { echo "需要 SSH_USER=<登入帳號> 才能執行稽核。"; exit 1; }
[ -s "$TARGETS" ] || { echo "缺目標清單：$TARGETS"; exit 1; }

OUT_ROOT="${SCAN_OUTPUT_DIR:-outputs}"
RUN_DIR="$OUT_ROOT/audit_$(date +%Y%m%d_%H%M%S)"
LOGDIR="$RUN_DIR/run"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/progress.log"
: > "$LOG"
log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
step() { echo ""; echo "########## $* ##########" | tee -a "$LOG"; }

. ./lib_ssh_pool.sh

PAR=$(norm "${PARALLEL:-9}" 9 9)
run_audit() { ssh_send_pull "$1" "$2" ubuntu_host_audit.sh ubuntu_audit audit; }

step "SSH 主機稽核（ubuntu_host_audit.sh，並行度=${PAR}）"
pool "$TARGETS" "$PAR" run_audit
summarize audit "稽核結果一覽"

echo ""
echo "==== start_host.sh 完成，輸出：$LOGDIR ===="
ls -1 "$LOGDIR" | tee -a "$LOG"