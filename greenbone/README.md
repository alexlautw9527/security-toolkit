# Greenbone Community Edition（Docker）

本目錄佈署的 Greenbone 病毒與弱點掃描系統，用官方容器在 mac 上以 Docker 執行，掃描醫院內部授權主機。掃描指令與排程流程見專案根目錄的 `runbook.md`「選配：OpenVAS 深度複驗」一章。

## 受測目標

- LB-Jump：172.28.14.131
- LB2：172.28.14.132
- Application：172.28.14.133-134
- HAPI：172.28.14.135-136
- IBM：172.28.14.137
- Database：172.28.14.138-139

只掃這份清單。不要掃描書面範圍以外的網段或醫療設備 VLAN。

## 環境

- Docker Desktop，`greenbone/compose.yaml` 定義 21 個服務，常駐 16 個容器。
- Web 介面：`https://127.0.0.1`，預設帳密 admin / admin。
- GMP（管理協定）經 gvmd 的 unix socket，只能用容器內的 `gvm-tools` 存取，mac 本機不可直連。
- gvmd 版本 26.37（DB revision 281），GMP 22.7。

## 啟動與停止

```bash
# 啟動
docker compose -f compose.yaml up -d

# 停止（掃描結束後不常駐）
docker compose -f compose.yaml down

# 看健康狀態
docker compose -f compose.yaml ps

# 看 gvmd 日誌
docker compose -f compose.yaml logs -f gvmd
```

## 診斷指令

在容器內執行 GMP 指令。一律要用 `docker compose run -T --rm gvm-tools ...`（gvm-tools 是不常駐的工具容器）：

```bash
# 確認 gvmd 有回應
docker compose -f compose.yaml run -T --rm gvm-tools \
  gvm-cli --gmp-username admin --gmp-password admin socket --xml "<get_version/>"

# 看掃描設定（config）
docker compose -f compose.yaml run -T --rm gvm-tools \
  gvm-cli --gmp-username admin --gmp-password admin socket --xml "<get_configs/>"

# 看 task 狀態
docker compose -f compose.yaml run -T --rm gvm-tools \
  gvm-cli --gmp-username admin --gmp-password admin socket --xml "<get_tasks/>"
```

## 已知問題與處理

### feed 同步期間 config 為空

剛啟動時 feed 需數分鐘同步，期間 `get_configs` 回傳 0 是正常。gvmd 日誌出現 `update_scap`、`Updating CPEs`、`sync_cert` 表示正在同步，等這些訊息收尾後 config 才出現。

### vts schema 遺失導致 gvmd 崩潰

症狀：gvmd 日誌出現 `TRUNCATE vts.all_vts` 失敗、`Received Aborted signal`，`get_configs` 回傳 0，GMP 連不上 socket。

原因：資料庫缺 `vts` schema 及其表格。要依 gvmd 版本定義手動建立 4 張表（`vts.meta`、`vts.all_vts`、`vts.web_application_vts`、`vts.web_application_vt_refs`），再寫入 `vts.meta` 的版本值（此實例為 2），最後重啟 gvmd：

```bash
docker compose -f compose.yaml exec pg-gvm psql -U gvmd -d gvmd <<'EOF'
CREATE TABLE IF NOT EXISTS vts.meta (
  id SERIAL PRIMARY KEY,
  name text UNIQUE,
  value text);

CREATE TABLE IF NOT EXISTS vts.all_vts (
  oid TEXT PRIMARY KEY,
  uuid TEXT UNIQUE,
  name TEXT,
  family TEXT,
  cvss_base TEXT,
  cve TEXT,
  summary TEXT,
  impact TEXT,
  solution_type TEXT,
  solution TEXT,
  detection TEXT,
  insight TEXT,
  affected TEXT,
  tag TEXT,
  type TEXT,
  type_metadata TEXT);

CREATE TABLE IF NOT EXISTS vts.web_application_vts (
  id SERIAL PRIMARY KEY,
  uuid text UNIQUE NOT NULL,
  name text NOT NULL,
  comment text,
  creation_time integer,
  modification_time integer,
  type text,
  description text,
  solution text,
  severity DOUBLE PRECISION DEFAULT 0,
  type_metadata text);

CREATE TABLE IF NOT EXISTS vts.web_application_vt_refs (
  id SERIAL PRIMARY KEY,
  vt_id text NOT NULL,
  type text NOT NULL,
  ref_id text NOT NULL,
  ref_text text);

INSERT INTO vts.meta (name, value) VALUES ('last_web_application_vts_update', 0)
  ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;
INSERT INTO vts.meta (name, value) VALUES ('web_application_vts_database_version', 2)
  ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value;
EOF

docker compose -f compose.yaml restart gvmd
```

表格結構以官方 gvmd 原始碼 `manage_pg.c` 的 `manage_db_init("vts")` 區塊為準。換版本時先查該版本對應的欄位與版本值，不要沿用這份。

### NVT 計數異常或缺漏

`gvmd --rebuild` 會重新掃描 feed、重建 NVT 資料庫並填入 `public.nvts` 與 `vt_severities`，可補救資料庫沒寫入的狀況：

```bash
docker compose -f compose.yaml stop gvmd
docker compose -f compose.yaml run -T --rm --entrypoint gvmd gvmd \
  --rebuild --db-user=gvmd
docker compose -f compose.yaml up -d gvmd
```

rebuild 逐筆寫入 18 萬筆 NVT，耗時約 10 分鐘以上，期間 CPU 使用高是正常現象。

## 掃描腳本

### openvas_batch_scan.gmp.py

批次掃描：讀 targets 檔案，逐台建立 target → task → 啟動 → 輪詢 → 下載 PDF。

```bash
cd "$(dirname "$0")"
OUT=batch_out
mkdir -p "$OUT"
docker compose -f compose.yaml run -T --rm \
  -v "$PWD:/srv" \
  gvm-tools gvm-script --gmp-username admin --gmp-password admin \
  socket /srv/openvas_batch_scan.gmp.py /srv/<targets檔案> /srv/$OUT
```

產出：`batch_out/<ip>.pdf`，每個 IP 一份。

腳本內寫死的 UUID：

- 掃描設定：`8715c877-47a0-438d-98a3-27c7a6ab2196`（Discovery，預設，速度快）；要完整掃描時以第三個引數傳 `daba56c8-73ec-11df-a475-002264764cea`（Full and fast）
- scanner：`08b69003-5fc2-4037-a479-93b440211c73`（OpenVAS Default）
- PDF 報告格式：`c402cc3e-b531-11e1-9163-406186ea4fc5`

這些都是官方預設且本實例已確認一致。回報格式偶爾隨版本異動，可用 `get_report_formats` 對照實際值。

### openvas_smoke_test.gmp.py

冒煙測試，對單一 IP 跑完整的建 target → 掃描 → 取報告流程，確認安裝可用。用於驗證或除錯：

```bash
docker compose -f compose.yaml run -T --rm \
  -v "$PWD:/srv" \
  gvm-tools gvm-script --gmp-username admin --gmp-password admin \
  socket /srv/openvas_smoke_test.gmp.py <ip> /srv/smoke_out
```

### gmp_get_report.gmp.py

通用取稿工具：依 report_id 下載報告檔，或只印掃描起訖時間。

`gvm-cli --xml '<get_report .../>'` 直接手刻 GMP request 會被伺服器回 `400 Bogus command name`，取報告一律用本腳本走 gvm-script 的 gmp API：

```bash
docker compose -f compose.yaml run -T --rm \
  -v "$PWD:/srv" \
  gvm-tools gvm-script --gmp-username admin --gmp-password admin \
  socket /srv/gmp_get_report.gmp.py <report_id> [<format_id>] [<輸出檔>]
```

- 不帶 format_id：印 scan_start / scan_end 等時間欄位。
- 帶 format_id 與輸出檔：把報告內容 base64 解碼存檔。CSV 用 `c1645568-627a-11e3-a660-406186ea4fc5`，PDF 用 `c402cc3e-b531-11e1-9163-406186ea4fc5`。

實例：example.com 冒煙的 report `028edef3-0337-4a6b-88fb-ed3450175ab5` 掃描起訖 18:37:52Z → 18:51:53Z（14 分 01 秒），CSV 已輸出到 `smoke_out/example.com.csv`。

## GMP 腳本慣例

- gvm-script 的 Python 腳本入口是 `if __name__ == "__gmp__": main(gmp, args)`。
- `gmp.get_task()` 回傳整個 `<get_tasks_response>`，要取 `<task>` 子元素再讀 status：`t.find("task").find("status").text`。
- `gmp.create_target()` 必須指定 `port_range`，否則回傳 400。
- 報告下載：gvmd 直接把 base64 內容放在 `<report>` 尾端文字節點、沒有 `<content>` 包裝，要用 regex 取出 `>...base64...</report>` 再 base64 解碼。腳本內已含此處理。
- CSV 報告格式 uuid `9c6f19f8-e665-11e1-b213-406186ea4fc5`（常見於舊文件）在本實例不存在，會回 404；實際 CSV Results 是 `c1645568-627a-11e3-a660-406186ea4fc5`，一律以 `get_report_formats` 查詢為準。

## 本次實測整備驗證（冒煙測試結果）

- 對 127.0.0.1 用 Discovery config 完整跑過：`Requested → Queued → Running → Done`，掃描約 14 秒，3 筆 log 級結果。
- 批次腳本端到端：建 target → task → 輪詢 → 下載 PDF，全部成功，PDF 有效（可被 `file` 判為 PDF 1.7）。
- scanner 與 config UUID 與腳本預設值一致。