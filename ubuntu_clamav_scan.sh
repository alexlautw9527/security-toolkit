#!/bin/bash
# 目標 Ubuntu 主機上執行的 ClamAV 惡意程式掃描腳本。需透過已授權身分 SSH 登入後以
# `bash -s` 送入執行（腳本不落地目標主機），由 start_clam.sh 主控並行送達。
# 只做掃描與打包，不做系統稽核（稽核另跑 ubuntu_host_audit.sh）。
# 產出：ubuntu_clamav_<hostname>_<時間戳>.tar.gz。
set -u
OUT="ubuntu_clamav_$(hostname)_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

if command -v clamscan >/dev/null 2>&1; then
  clamscan --version > "$OUT/clamav_version.txt" 2>&1 || true
  # 只掃一般會放置內容與程式的目錄，限制單檔與總掃描大小，避免掃到大型資料庫目錄拖垮主機。
  clamscan --infected --recursive \
    --max-filesize=10M --max-scansize=40M \
    /home /tmp /var/www /opt /usr/local \
    > "$OUT/clamav_scan.txt" 2>&1 || true
else
  echo "ClamAV 未安裝，略過惡意程式掃描" > "$OUT/clamav_scan.txt"
fi

tar czf "${OUT}.tar.gz" "$OUT"
echo "Created ${OUT}.tar.gz"