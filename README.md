# security-toolkit

以 macOS 主控機連線委託單位內部 Linux 主機群做非破壞性弱點盤點，分三支主控：

- `start_scan.sh`：依序三步——連通性、nmap 盤點、Web 主機跑 ZAP／Nuclei。
- `start_host.sh`：SSH 主機稽核，對能以授權身分免密登入的主機並行執行 `ubuntu_host_audit.sh` 並拉回結果。
- `start_clam.sh`：ClamAV 掃描，對指定主機清單執行 `ubuntu_clamav_scan.sh`，範圍與並行度都比稽核保守。

## 執行前提（不可違反）

- 已取得委託單位書面授權與測試時窗。未授權不得執行任何掃描。受測清單以 `targets.txt`（純 IP，每行一個）為準。
- 已連上 VPN，目標網段可達。
- 只允許非破壞性掃描。禁止 DoS、暴力破解、密碼噴濺、破壞性 exploit、負載或壓力測試。
- 掃描腳本全部在 macOS 本機執行，不會把工具安裝或部署到目標主機。例外建立在下列兩處：
    - `ubuntu_host_audit.sh` 是「在目標 Ubuntu 主機上本地執行」的稽核腳本，以授權身分 SSH 送入執行，腳本不落地主機。
    - `windows_host_audit.ps1` 與 `windows_defender_scan.ps1` 在 Windows 主機上以 PowerShell 執行，結果由主機端匯出，不回傳本機。

## 工具安裝（本機，缺才裝）

```bash
brew install nmap
brew install projectdiscovery/tap/nuclei     # 首次跑 04 需能連 GitHub 下載模板
brew install --cask zaproxy
```

## 執行流程

```bash
./start_scan.sh                          # 連通性、nmap、Web 掃描
APPROVED_ACTIVE=yes ./start_scan.sh --active   # 05 追加有限主動掃描（需再取得委託單位同意）
SSH_USER=user ./start_host.sh            # 主機稽核（並行，讀 targets.txt 或指定清單）
SSH_USER=user ./start_clam.sh hot.txt    # ClamAV（只掃指定主機）
```

- 主機稽核與 ClamAV 不在 `start_scan.sh` 內，跑完 Web 掃描後另行執行。SSH 主控需先向委託單位確認「低權限 SSH 掃描帳號」的授權範圍與鎖定規則。
- `--active` 與 `APPROVED_ACTIVE=yes` 必須同時出現 05 才放行主動掃描（兩道防呆，見環境變數總規則）。

### 輸出結構

所有產出統一收在本機 `outputs/`（可用 `SCAN_OUTPUT_DIR` 覆寫）。`start_scan.sh` 一輪固定一個 `RUN_ID`（時間戳），該輪全部產出在同一個 `outputs/<RUN_ID>/` 內，再分 `reachability`、`nmap`、`nuclei`、`zap`、`run` 五個子目錄（`run/` 含 progress.log 與 web_scope.txt）。稽核與 ClamAV 的 tar.gz 另收在 `start_host.sh` 的 `outputs/audit_<時間戳>/run/` 與 `start_clam.sh` 的 `outputs/clam_<時間戳>/run/`。

產出不提交版本控制。清理直接 `rm -rf outputs/`，不要用 `rm -rf run_*` 這類寬 glob（`run_*` 會誤匹配以 `run` 開頭的檔案）；手動單步執行、產出落在專案根時，用明確前綴 `reachability_20*`、`nmap_20*` 清理。

### 步驟 1：連通性（`01_vpn_reachability.sh`）

- 輸出路由表，對 `targets.txt` 每台 ping，並以 netcat 測常見埠（22、80、443、3389、5432、3306、1521、1433、8443、8080）。
- 產出 `outputs/<RUN_ID>/reachability/routes.txt` 與 `reachability.txt`。

失敗處理：

- 退出碼語意：只要有一台任一探測成功就算通過；都沒回應時回傳非零，`start_scan.sh` 在此中止，不進 step 2。中止先確認 VPN 已連上、`targets.txt` 內容正確，再重跑。
- `nc -G` 支援隨 macOS 版本而異（macOS 15.7.4 支援，較舊不一定）。出現 `nc: illegal option -- G` 時，把 `nc -G 2 -zv` 改成 `nc -w 2 -zv`。
- 目錄沒產生：檢查腳本可執行（`chmod +x`）與 `targets.txt` 是否有內容。

### 步驟 2：nmap 盤點（`sudo ./02_nmap_inventory.sh`）

- 逐台保守服務盤點（`--top-ports 1000`），任一台失敗不中斷後續。太慢可降 `--top-ports 100`。02 需要 sudo。
- 產出 `outputs/<RUN_ID>/nmap/open_ports.csv`（target、port、service），是下一步 Web scope 的唯一來源。
- 追加 NSE 線索（`default and safe`、vulners）預設關閉，避免拖慢掃描。經 `start_scan.sh` 執行時 step 2 前會互動詢問，Enter 維持關閉；先設好 `RUN_SAFE_SCRIPTS=1`／`RUN_VULNERS=1` 就跳過詢問。
- `vulners` 需要本機可連 `vulners.com`；離線時該台顯示警告但不中斷，不視為失敗。
- 並行：設 `PARALLEL=n`（2–9）時，02 一次同時掃 n 台，step 3 的 nuclei 與 zap 也同時跑，預設 9。並行會放大對目標的連線壓力，在授權範圍內斟酌。

### 步驟 3：Web scope → Nuclei 與 ZAP

`start_scan.sh` 從 `nmap/open_ports.csv` 篩出 Web 標的，只以 nmap 的 service 欄位為準：被判成含 `http` 的服務才進清單，不另以固定埠號猜，非標準 Web 埠不會漏。scheme 依 `ssl`／`https` 推測，再以 curl HEAD 確認哪個 scheme 真的有回應，寫進 `run/web_scope.txt`。沒有 Web 埠的主機完全不進 ZAP 與 Nuclei。

- `04_nuclei_scan.sh`：用 exposure、misconfig、cve 模板，排除 brute、fuzz、intrusive，產出 `outputs/<RUN_ID>/nuclei/nuclei.jsonl`。結果都是疑似線索，需人工複驗。
- `05_zap_scan.sh web_scope.txt`：ZAP Automation Framework 一次跑完 spider → 被動掃描 → 報告，headless 跑完即退出不常駐，home 隔離在 `outputs/<RUN_ID>/zap/zap_home`。也可直接餵 URL 清單；它內建對 `targets.txt` 的 HTTP／HTTPS 探測邏輯。
- 主動掃描的強度已壓到最低：`defaultStrength: low`、`defaultThreshold: high`、單規則上限 1 分鐘。

失敗處理：

- Nuclei 連不上 GitHub 無法更新模板：警告並沿用既存模板，不中斷。
- ZAP 執行異常：看 `outputs/<RUN_ID>/zap/plan.yaml`，可在 GUI 用「Run automation plan」載入除錯；daemon 日誌在 `zap_home`。
- 只抓到少量 URL：SPA 或 JS 動態載入的頁面要靠人工作業，把手動探索到的 URL 存成清單，再用 `./05_zap_scan.sh <urls.txt>` 補掃。

### 步驟 4（另行執行）：SSH 主機稽核（`start_host.sh`）

SSH 稽核不在 `start_scan.sh` 內，跑完 Web 掃描後另行執行：

```bash
SSH_USER=user ./start_host.sh                 # 稽核 targets.txt 全部
SSH_USER=user ./start_host.sh some_hosts.txt  # 稽核指定清單
```

以 `PARALLEL`（預設 9）並行，對清單每台：

1. 以 `ssh -o BatchMode=yes` 測能否免密登入；不能登入的記入限制事項，不稽核。
2. 可登入的以 `ssh user@host 'bash -s' < ubuntu_host_audit.sh` 就地執行稽核（腳本不落地主機），收集套件清單與可升級套件、監聽埠與執行中服務、防火牆規則、sudo 群組與安全狀態。
3. 產出 `ubuntu_audit_<hostname>_<時間戳>.tar.gz` 後用 scp 拉回本機，再刪主機端稽核檔。

- 套件修補缺口以套件清單人工比對公開 CVE，或改用 Vuls（agentless，非侵入式）。
- 每台狀態寫 `audit_<ip>.log`，結束後在 `progress.log` 列出結果一覽。

失敗處理：

- 拿不到 SSH 登入身分：記入限制事項，標註該台未稽核。
- 主機沒有 pro 或 ubuntu-security-status：腳本自動略過該列，不影響其餘項目。

### 步驟 4（另行執行）：ClamAV 掃描（`start_clam.sh`）

ClamAV 對目標端 CPU／磁碟有實質壓力，與稽核分開、縮緊範圍後在授權時窗內跑：

```bash
SSH_USER=user ./start_clam.sh                 # 掃描 targets.txt 全部
SSH_USER=user ./start_clam.sh hot_hosts.txt   # 只掃指定主機（縮緊範圍）
```

- 主機範圍由清單（位置參數）決定，未給就是 `targets.txt`；實務上建議只挑稽核或 Web 掃描顯示可疑的主機。
- 並行度 `CLAMAV_PARALLEL`（預設 2），比稽核低，避免同時對多台目標施壓。
- 送出 `ubuntu_clamav_scan.sh`，對 `/home /tmp /var/www /opt /usr/local` 做限定目錄與大小上限的非全盤掃描；未裝 ClamAV 記錄「未安裝」不報錯。
- 產物 `ubuntu_clamav_<hostname>_<時間戳>.tar.gz` 拉回本機後刪主機端殘留。

## 環境變數指令集

輸入全靠環境變數與少數命令列旗標。兩句總規則：

- `start_scan.sh` 只是順序呼叫單步腳本、環境一路繼承，所以它沒列出的變數（`NUCLEI_*`、`NMAP_PARALLEL`、`PING_PARALLEL`、`TLS_*` 等）照樣會被單步腳本讀取。
- 命令列旗標 `--active`：出現在 `start_scan.sh` 或 `05_zap_scan.sh` 參數中，要求 05 做有限主動掃描；05 還需 `APPROVED_ACTIVE=yes`，兩者都齊才放行。
- `SCAN_OUTPUT_DIR` 兩層語意：經 `start_scan.sh` 執行時是產出根目錄（預設 `outputs/`，一輪一個 `RUN_ID`），各步再把子目錄傳下去；手動單步執行、未設定時，各腳本自建 `<工具>_<時間戳>` 目錄避免覆蓋前一次結果。各單步腳本都接受 `SCAN_OUTPUT_DIR`。

### start_scan.sh（主掃描主控）

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `PARALLEL` | `9` | 02 一次並行掃台數（2–9）；step 3 的 nuclei 與 zap 也同時跑 |
| `RUN_SAFE_SCRIPTS` | `0` | 轉傳 02，`1` 跑 `default and safe` NSE |
| `RUN_VULNERS` | `0` | 轉傳 02，`1` 跑 vulners NSE |
| `APPROVED_ACTIVE` | `no` | 05 主動掃描授權，需搭配 `--active` |
| `HEARTBEAT_INTERVAL` | `60` | 背景進度心跳間隔秒數 |
| `SCAN_OUTPUT_DIR` | `outputs` | 產出根目錄（一輪一個 `RUN_ID`） |

### 01_vpn_reachability.sh

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `PING_PARALLEL` | `4` | 跨台 ping 並行數；`1` 回到逐台依序 |

### 02_nmap_inventory.sh

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `NMAP_PARALLEL` | `1` | 逐台並行掃描台數 |
| `RUN_SAFE_SCRIPTS` | `0` | `1` 跑 `default and safe` NSE |
| `RUN_VULNERS` | `0` | `1` 跑 vulners NSE（逐服務全版本探測，最慢） |

範例：

```bash
sudo ./02_nmap_inventory.sh
NMAP_PARALLEL=8 RUN_SAFE_SCRIPTS=1 RUN_VULNERS=1 sudo ./02_nmap_inventory.sh
```

### 04_nuclei_scan.sh

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `NUCLEI_TARGETS` | `targets.txt` | 目標清單檔；`start_scan.sh` 會餵 Web scope URL 清單 |
| `NUCLEI_TEMPLATES` | 未設 | 指定單一模板檔或目錄取代 `-tags`（冒煙、限縮範圍用） |
| `NUCLEI_TAGS` | `exposure,misconfig,cve` | 使用的模板類別 |
| `NUCLEI_ETAGS` | `brute,fuzz,intrusive` | 排除的模板類別 |

模板下載在本機 `~/.local/share/nuclei-templates`，可離線沿用。

### 05_zap_scan.sh

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `APPROVED_ACTIVE` | `no` | 主動掃描授權，需與 `--active` 同時出現 |

### start_host.sh（SSH 主機稽核）

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `SSH_USER` | 必要 | 稽核的登入帳號（需為已授權身分） |
| `PARALLEL` | `9` | 並行稽核台數 |
| `SCAN_OUTPUT_DIR` | `outputs` | 產出根目錄（一輪一個 `audit_<時間戳>` 子目錄） |

範例：

```bash
SSH_USER=user ./start_host.sh                 # 稽核 targets.txt 全部
SSH_USER=user ./start_host.sh some_hosts.txt  # 稽核指定清單
```

### start_clam.sh（ClamAV 掃描）

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `SSH_USER` | 必要 | 掃描的登入帳號 |
| `CLAMAV_PARALLEL` | `2` | 並行掃描台數，比稽核保守 |
| `SCAN_OUTPUT_DIR` | `outputs` | 產出根目錄（一輪一個 `clam_<時間戳>` 子目錄） |

範例：

```bash
SSH_USER=user ./start_clam.sh                 # 掃描 targets.txt 全部
SSH_USER=user ./start_clam.sh hot_hosts.txt   # 只掃指定主機（縮緊範圍）
```

### 06_tls_ssl_check.sh

| 環境變數 | 預設 | 作用 |
| --- | --- | --- |
| `TLS_TARGETS` | 未設 | 直接給 `host` 或 `host:port` 清單；未設且無參數時對 `targets.txt` 各主機試 443 |
| `TLS_TIMEOUT` | `8` | 單一探測等待秒數，無法連線的主機以此強制結束 |
| `TLS_TESTSSL` | `0` | `1` 且本機有 testssl.sh 時，對每個標的追加深度輸出 |

範例：

```bash
./06_tls_ssl_check.sh web_scope.txt                       # 從 URL 清單取 https 標的
TLS_TARGETS="mail.example.com:443,portal.example.com" ./06_tls_ssl_check.sh
TLS_TESTSSL=1 ./06_tls_ssl_check.sh web_scope.txt
```

## sudoers：讓非互動流程（AI／CI／排程）取得權限

全程只有一支程式需要 sudo：step 2。互動執行直接輸入密碼即可。無法輸入密碼的流程要在 sudoers 開放這支 script 免密碼執行，只要設定一次：

```bash
sudo install -m 440 -o root -g wheel /dev/stdin /etc/sudoers.d/scan-nmap <<'EOF'
<使用者帳號> ALL=(root) SETENV: NOPASSWD: <專案絕對路徑>/02_nmap_inventory.sh
EOF
sudo visudo -c
```

- 生效後用 `sudo -l` 驗證會看到 `SETENV: NOPASSWD: ...`。`SETENV:` 是必要標籤：`start_scan.sh` 以 `sudo RUN_SAFE_SCRIPTS=... RUN_VULNERS=... NMAP_PARALLEL=... ./02_nmap_inventory.sh` 傳遞環境變數，sudo 預設禁止命令列前置變數，少了它會得「you are not allowed to set the following environment variables」。
- 只授權這支 script 以 root 執行，不要把規則放寬成 `NOPASSWD: ALL`。script 可被改寫，改動後等於授權任意 root 執行，只能接受這個風險才開放。
- 不要用 `sudo -v` 快取密碼替代：macOS 的 sudo 時間戳綁 tty，非互動流程的 tty 不同，快取不生效。
- `visudo` 預設開 `$EDITOR`；若 `$EDITOR` 指向 GUI 編輯器（如 Cursor），在終端機開不起來，改用上面的 `sudo install` 或 `EDITOR=nano sudo visudo -f /etc/sudoers.d/scan-nmap`。

## 冒煙測試（不碰授權環境）

用本機 dummy 驗證掃描管道端到端跑通，不必連 VPN：

```bash
python3 vulnserver.py                    # 預設綁 127.0.0.1:8901，單檔 Python 標準函式庫靶子，內建缺安全標頭、反射、資訊洩漏等弱點
echo 'http://127.0.0.1:8901' > demo_urls.txt
./05_zap_scan.sh demo_urls.txt
```

- ZAP 對 loopback 沒問題，報告預期約 12 條 alert，退出碼 0 或 2 都算完成。
- Nuclei 對 `127.0.0.1` 掃描會卡死，要用本機 LAN IP：`VULNSERVER_HOST=0.0.0.0 python3 vulnserver.py`，目標用 `ipconfig getifaddr en0` 查到的 LAN IP。
- 冒煙成功判準：ZAP 產生有預期 alert 的報告；Nuclei 進度與 requests 推進至收尾（matched 0 屬正常）。

## 選配：Greenbone／OpenVAS 深度複驗

只在某台疑有高風險漏洞時對那一台做深度複驗，不整網全掃，日常流程不需要部署或常駐。

```bash
cd greenbone
docker compose -f compose.yaml up -d     # 啟動 16 個常駐容器；關閉用 down
docker compose -f compose.yaml ps        # 確認 gvmd 與 pg-gvm 是 healthy
```

- feed 同步需幾分鐘，期間 `get_configs` 可能回傳 0，不是故障。
- gvmd 日誌出現 `vts.all_vts does not exist` 表示資料庫缺 `vts` 表格，以相同版本定義手動建立後 `docker compose restart gvmd`。
- 批次掃描與冒煙以 `greenbone` 目錄為工作目錄：批次指令見 `README.md` 原文，結果在 `greenbone/batch_out/<ip>.pdf`（每個 IP 一份）；冒煙 script 是 `openvas_smoke_test.gmp.py`，target 用 `host.docker.internal`（容器內 `127.0.0.1` 是容器自己），輸出去 `greenbone/smoke_out`。
- 不要掃描書面範圍以外的網段或受保護的設備網段。完成後關閉容器。

## 分析與報告

分析與報告作業直接依 `ANALYSIS_GUIDE.md`，材料以 `outputs/<RUN_ID>/` 的原始輸出為準：收集材料與目錄對照（第 1 節）、五步分析流程與章節骨架（第 2 節）、發現評等與採信規則（第 3 節）、各工具讀判要點（第 4 節）、交叉比對（第 5 節）、最終報告填寫與範本（第 6、9 節）、證據路徑格式（第 7 節）。README 不重複這些細節。

## 針對本次範圍

- 受測網段與主機 IP 清單屬機敏，收在 `env.md`（已排除於版本控制），本檔不列具體 IP。
- 非 Web 主機（LB、中介軟體、DB）以 nmap 盤點＋主機稽核為主，ZAP／Nuclei 對它們幾乎沒有可掃的 Web 面，step 3 會自動略過。
- 時間不足的取捨順序：
  1. 砍深度：不做 ZAP 主動掃描、OpenVAS 深度複驗。
  2. 砍廣度：ZAP 被動只留 FHIR＋AP 四台，Nuclei 保持原設定。
  3. 底線不讓步：nmap 盤點、Nuclei 被動、ZAP 被動的前半。
  4. 時間到一律停止，在報告標註「部分完成／未執行」，不在時窗外硬撐。
- 主動掃描對象由被動結果決定，不先指定某一台：預設候選 `app01` 與 `fhir01`，擴充條件是被動在 `lb01` Web 入口或中介軟體 Web 面發現高風險；被動乾淨的台不開主動掃描。FHIR 台的主動掃描 scope 只限定在 `/fhir` base。

## 開發與改動腳本時的規則

- 開發、改動與驗證規則統一收在 `AGENTS.md`。

## 檔案總覽

| 檔案 | 用途 |
|---|---|
| `start_scan.sh` | 主掃描主控，依序跑連通性、nmap、Web 掃描。從這裡開始 |
| `start_host.sh` | SSH 主機稽核主控，並行執行 `ubuntu_host_audit.sh` |
| `start_clam.sh` | ClamAV 掃描主控，對指定清單並行執行 `ubuntu_clamav_scan.sh` |
| `targets.txt` | 受測主機清單（純 IP，每行一個） |
| `01_vpn_reachability.sh` | 步驟 1：連通性檢查 |
| `02_nmap_inventory.sh` | 步驟 2：nmap 服務盤點 |
| `04_nuclei_scan.sh` | 步驟 3：Nuclei 快速弱點掃描（只掃 Web scope） |
| `05_zap_scan.sh` | 步驟 3：ZAP 被動／有限主動掃描 |
| `lib_ssh_pool.sh` | `start_host.sh`／`start_clam.sh` 共用的 SSH 並行函式庫 |
| `ubuntu_host_audit.sh` | 主機稽核：目標 Ubuntu 主機本機稽核腳本 |
| `ubuntu_clamav_scan.sh` | ClamAV：目標 Ubuntu 主機本機掃描腳本 |
| `windows_host_audit.ps1` | Windows 主機稽核腳本（PowerShell） |
| `windows_defender_scan.ps1` | Windows Defender 掃描腳本（PowerShell） |
| `ANALYSIS_GUIDE.md` | 收尾：掃描輸出解讀、採信標準與報告各節填寫指引；含最終報告範本（第 9 節） |
| `vulnserver.py` | 本機冒煙測試靶子（見冒煙測試） |
| `greenbone/` | 選配。Greenbone Community Edition 深度複驗，日常流程不需部署 |
