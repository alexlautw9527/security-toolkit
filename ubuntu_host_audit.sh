#!/bin/bash
# 主機稽核腳本：在「目標 Ubuntu 主機」本機執行，產出 tar.gz 後由 start_scan.sh 拉回 mac。
# 不是從 mac 掃描遠端機的腳本；需透過已授權身分 SSH 登入後以 `bash -s` 送入執行（腳本不落地目標主機）。
# 收集項目：系統識別、套件清單與可升級項、監聽埠、執行中服務、防火牆規則、SSH 設定、
#   sudo 群組成員、後門藏身點檢查（cron、systemd、authorized_keys、shell 啟動檔、ld.so.preload、
#   套件竄改、對外連線、記憶體執行體、近期修改的系統執行檔）、Ubuntu 安全狀態。
# 惡意程式掃描不在此腳本，改用 ubuntu_clamav_scan.sh。
# 產出：ubuntu_audit_<hostname>_<時間戳>/，最後壓成 ubuntu_audit_<hostname>_<時間戳>.tar.gz。
set -u
OUT="ubuntu_audit_$(hostname)_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

# 系統識別：發行版與核心版本，判斷補丁狀態的基準。
cat /etc/os-release > "$OUT/os-release.txt" 2>&1
uname -a > "$OUT/uname.txt" 2>&1
# 套件修補缺口：全部套件清單（供後續人工比對 CVE）與可升級清單。
dpkg-query -W -f='${Package}\t${Version}\n' > "$OUT/packages.tsv" 2>&1
apt list --upgradable > "$OUT/upgradable.txt" 2>&1
# 監聽中的 TCP/UDP 埠與對應行程，確認本機對外開放了哪些服務。
ss -lntup > "$OUT/listening_ports.txt" 2>&1
# 執行中的 service，判斷有哪些服務常駐運作。
systemctl --type=service --state=running > "$OUT/running_services.txt" 2>&1
# 防火牆：ufw 與 nftables 現行規則。部分主機可能沒裝，用 || true 不報錯。
ufw status verbose > "$OUT/ufw.txt" 2>&1 || true
nft list ruleset > "$OUT/nftables.txt" 2>&1 || true
# SSH 有效設定（sshd -T 輸出實際生效值），檢查如 PermitRootLogin、PasswordAuthentication 等項目。
sshd -T > "$OUT/sshd_effective.txt" 2>&1 || true
# sudo 群組成員，盤點有管理權限的使用者。
getent group sudo > "$OUT/sudo_group.txt" 2>&1 || true

# 後門藏身點檢查（第一層，預設執行）：針對最常見的後門持久化手段，只使用系統內建工具，
# 單台主機約 1 分鐘內完成。每個檢查輸出為「一行一項」的短清單，方便多台主機橫向比對。
# cron 排程後門：列出系統與所有可登入使用者的排程，確認其中沒有指向可疑路徑的指令。
{
  echo "## /etc/crontab"
  cat /etc/crontab 2>/dev/null
  echo "## /etc/cron.d"
  grep -R -H -v -E '^\s*(#|$)' /etc/cron.d 2>/dev/null
  echo "## /etc/cron.hourly|daily|weekly|monthly"
  ls -la /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null
  echo "## 使用者 crontab"
  for _u in $(awk -F: '!/nologin|false/ {print $1}' /etc/passwd); do
    _crontab="$(crontab -l -u "$_u" 2>/dev/null)"
    if [ -n "$_crontab" ]; then
      echo "### $_u"
      printf '%s\n' "$_crontab"
    fi
  done
} > "$OUT/persistence_cron.txt" 2>&1

# systemd 開機自動啟動的服務：確認清單中沒有陌生人新增的 unit。
systemctl list-unit-files --state=enabled --no-legend --no-pager \
  > "$OUT/persistence_systemd.txt" 2>&1 || true
# /etc/systemd/system 是管理員額外放置或 symlink 服務定義的位置，人工新增服務通常從這裡進來。
ls -la /etc/systemd/system 2>/dev/null | grep -E '\.(service|timer|socket)$' \
  > "$OUT/persistence_systemd_custom.txt" 2>&1 || true

# authorized_keys：列出所有允許免密碼登入的金鑰與來源路徑，比對是否都是已知金鑰。
{
  for _f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    if [ -f "$_f" ]; then
      grep -H -E '^(ssh-rsa|ssh-ed25519|ecdsa-|sk-ecdsa|sk-ssh)' "$_f" 2>/dev/null
    fi
  done
  if [ ! -s /root/.ssh/authorized_keys ]; then
    echo "(root 沒有 authorized_keys，屬正常)"
  fi
} > "$OUT/ssh_authorized_keys.txt" 2>&1

# shell 啟動檔：登入時會被自動執行的設定檔，攻擊者常把下載與執行指令藏在這裡。
{
  for _f in /root/.bashrc /root/.bash_profile /root/.profile /etc/profile \
            /etc/bash.bashrc /home/*/.bashrc /home/*/.profile; do
    if [ -f "$_f" ]; then
      grep -H -v -E '^\s*(#|$)' "$_f" 2>/dev/null
    fi
  done
} > "$OUT/shell_startup.txt" 2>&1
# 從上述清單篩出高風險模式（遠端下載、從 /tmp 執行、混淆指令），方便直接聚焦判讀。
grep -h -E 'curl|wget|nc |ncat|/tmp/[A-Za-z]|/dev/shm|base64|python|perl|ruby|php|eval|sh[[:space:]]+-c' \
  "$OUT/shell_startup.txt" > "$OUT/shell_startup_suspicious.txt" 2>/dev/null || true

# ld.so.preload：全域共用程式庫掛載清單，正常為空或不存在；有內容即屬嫌疑。
{
  if [ -f /etc/ld.so.preload ]; then
    cat /etc/ld.so.preload
  else
    echo "(/etc/ld.so.preload 不存在，屬正常)"
  fi
} > "$OUT/ld_preload.txt" 2>&1

# dpkg --verify：比對已安裝套件的檔案內容與安裝時是否一致，找出被竄改的系統程式。
# 完整結果留在 dpkg_verify.txt；hash 不符（狀態第 3 位為 5）單獨篩出，降低判讀雜訊。
dpkg --verify > "$OUT/dpkg_verify.txt" 2>&1 || true
grep -E '^..5' "$OUT/dpkg_verify.txt" > "$OUT/dpkg_verify_hash_changed.txt" 2>/dev/null || true

# 對外連線：包含 established 連線，後門定期向控制伺服器回報時會顯示在這裡。
ss -tunap > "$OUT/network_connections.txt" 2>&1 || true

# 來源檔案已被刪除的執行中行程：正常程式不會這樣，出現即高度可疑（記憶體後門手法）。
{
  for _l in /proc/[0-9]*/exe; do
    _dest="$(readlink "$_l" 2>/dev/null)"
    case "$_dest" in
      *" (deleted)"*) echo "${_l#/proc/} -> ${_dest}";;
    esac
  done
} > "$OUT/deleted_exe.txt" 2>&1

# 最近 30 天內修改過的系統執行檔：正常系統很少改動 /usr、/bin 下的內容。
{
  find /usr/local/bin /usr/local/sbin /usr/sbin /sbin /bin /usr/bin \
       /etc/cron.daily /etc/cron.weekly -type f -mtime -30 \
       -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort -r
} > "$OUT/recent_binaries_mtime.txt" 2>&1

# Ubuntu 安全更新狀態：Ubuntu Pro 優先，舊版本改用 ubuntu-security-status。
if command -v pro >/dev/null 2>&1; then
  pro security-status > "$OUT/security_status.txt" 2>&1 || true
elif command -v ubuntu-security-status >/dev/null 2>&1; then
  ubuntu-security-status > "$OUT/security_status.txt" 2>&1 || true
fi

# 打包成單一個 tar.gz，方便 scp 拉回本機。
tar czf "${OUT}.tar.gz" "$OUT"
echo "Created ${OUT}.tar.gz"