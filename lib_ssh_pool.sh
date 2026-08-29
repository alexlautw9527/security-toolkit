# SSH 並行主控的共用函式，由 start_host.sh 與 start_clam.sh source 使用，不作為獨立程式執行。
# 依賴呼叫方已設定：SSH_USER、LOGDIR、LOG，以及 log()／step() 兩支輸出函式。
# 提供：norm、pool、ssh_send_pull、summarize。

# 並行度校準：非數字、過大、過小都收回界內，與 start_scan.sh 的邏輯一致。
norm() {
  local v="$1" def="$2" hi="$3"
  case "$v" in (*[!0-9]*|'') v=$def;; esac
  [ "$v" -gt "$hi" ] && v=$hi
  [ "$v" -le 0 ] && v=1
  printf '%s' "$v"
}

# 執行 job pool：一次保持最多 $limit 個背景 job，滿額時等最早啟動的一個空出槽位。
# 不用 wait -n（macOS bash 3.2 不支援），用陣列記錄啟動順序。
pool() {
  local list="$1" limit="$2" fn="$3" idx=0 pids=() ip
  while read -r ip || [ -n "$ip" ]; do
    [ -n "$ip" ] || continue
    [[ "$ip" == \#* ]] && continue
    idx=$((idx + 1))
    $fn "$ip" "$idx" &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$limit" ]; then
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
    fi
  done < "$list"
  for p in "${pids[@]}"; do wait "$p"; done
}

# 逐台：BatchMode 測免密登入，能登入才把 <script> 以 bash -s 送進目標就地執行（不落地），
# 把 <rem_base>_*.tar.gz 以 scp 拉回 $LOGDIR 後刪目標端殘留。
# 逐台狀態寫 <tag>_<ip>.log，避免並行輸出交錯。$rem_base 是腳本在目標端產物檔名前綴（如 ubuntu_audit）。
ssh_send_pull() {
  local ip="$1" n="$2" script="$3" rem_base="$4" tag="$5"
  local lf="$LOGDIR/${tag}_$ip.log"
  {
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$ip" 'true' >/dev/null 2>&1; then
      echo "無法以 BatchMode 免密登入，記入限制事項"
      return 0
    fi
    echo "SSH 可登入，執行 $script"
    if ssh -o ConnectTimeout=5 "$SSH_USER@$ip" "bash -s" < "$script"; then
      if scp -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$ip":"${rem_base}_*.tar.gz" "$LOGDIR/" >/dev/null 2>&1; then
        echo "tar.gz 已拉回"
        ssh -o BatchMode=yes "$SSH_USER@$ip" "rm -rf ${rem_base}_*" >/dev/null 2>&1
      else
        echo "遠端 script 完成但 tar.gz 拉回失敗"
      fi
    else
      echo "$script 執行失敗"
    fi
  } > "$lf" 2>&1
}

# 把每台結果最後一行摘要進 progress.log，方便一次掃過全部主機狀態。
summarize() {
  local prefix="$1" label="$2" lf ip
  step "$label"
  for lf in "$LOGDIR"/${prefix}_*.log; do
    [ -e "$lf" ] || continue
    ip=$(basename "$lf")
    ip=${ip#${prefix}_}
    ip=${ip%.log}
    log "[$ip] $(tail -n1 "$lf")"
  done
}