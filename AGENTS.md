# AGENTS.md

## bash 3.2 變數展開規則（不可違反）

本專案腳本以 macOS 內建 bash 3.2 執行。雙引號內 `$VAR` 後面緊接中文全形字元（如 `，`、`（`、`）`、`：`）時，bash 3.2 會把後續的 bytes 併進變數名，`set -u` 下直接以 `unbound variable` 中止執行。

實際案例：`step "並行度=$PAR）"` 觸發 `PAR（...` unbound；修正為 `step "並行度=${PAR}）"`。

規則：所有 `.sh` 檔中，凡 `$VAR` 後直接接非 ASCII 字元，一律改寫成 `${VAR}`。

## 改動與驗證規則

- 改動任何 `.sh` 後先以 `bash -n <file>` 做語法檢查。
- 連上 VPN 後跑 `./start_scan.sh` 驗證依序產出：
    - `outputs/<RUN_ID>/reachability/reachability.txt`
    - `outputs/<RUN_ID>/nmap/open_ports.csv`
    - 有 Web 主機時產生 `run/web_scope.txt`，接續 `nuclei/nuclei.jsonl` 與 `zap/zap_report.html`
    - 設 `SSH_USER` 時 `run/` 出現各可登入主機的 `ubuntu_audit_*.tar.gz`
- 以 `SSH_USER=user ./start_host.sh` 驗證稽核主控：`outputs/audit_<時間戳>/run/` 出現各可登入主機的 `ubuntu_audit_*.tar.gz`。
- 以 example.com／example.org 冒煙時，Nuclei 全模板（5644 個）在 Cloudflare 前被限速，2 個 host 約要 40 分鐘才跑得完；要快速驗證管道就限縮模板子集。