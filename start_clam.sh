#!/bin/bash
# ClamAV 掃描主控：對指定主機清單並行執行 ubuntu_clamav_scan.sh（ClamAV 惡意程式掃描）。
# ClamAV 對目標端 CPU／磁碟有實質壓力，主機範圍要依 audit 結果或授權範圍縮緊，
# 並行度預設 2，需要時以 CLAMAV_PARALLEL 放寬。
#
# 用法：
#   SSH_USER=user ./start_clam.sh                 # 掃描 targets.txt 全部
#   SSH_USER=user ./start_clam.sh hot_hosts.txt   # 只掃指定主機（縮緊範圍）
#
# 環境變數：
#   SSH_USER         登入帳號（必要）
#   CLAMAV_PARALLEL  並行台數（預設 2）
#   SCAN_OUTPUT_DIR  產出根目錄（預設 outputs/，一輪一個 clam_<時間戳> 子目錄）
set -u

cd "$(dirname "$0")" || exit 1
TARGETS="${1:-targets.txt}"

[ -n "${SSH_USER:-}" ] || { echo "需要 SSH_USER=<登入帳號> 才能執行 ClamAV 掃描。"; exit 1; }
[ -s "$TARGETS" ] || { echo "缺目標清單：$TARGETS"; exit 1; }

OUT_ROOT="${SCAN_OUTPUT_DIR:-outputs}"
RUN_DIR="$OUT_ROOT/clam_$(date +%Y%m%d_%H%M%S)"
LOGDIR="$RUN_DIR/run"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/progress.log"
: > "$LOG"
log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
step() { echo ""; echo "########## $* ##########" | tee -a "$LOG"; }

. ./lib_ssh_pool.sh

PAR=$(norm "${CLAMAV_PARALLEL:-2}" 2 9)
run_clam() { ssh_send_pull "$1" "$2" ubuntu_clamav_scan.sh ubuntu_clamav clam; }

step "ClamAV 掃描（ubuntu_clamav_scan.sh，並行度=${PAR}）"
pool "$TARGETS" "$PAR" run_clam
summarize clam "ClamAV 結果一覽"

echo ""
echo "==== start_clam.sh 完成，輸出：$LOGDIR ===="
ls -1 "$LOGDIR" | tee -a "$LOG"