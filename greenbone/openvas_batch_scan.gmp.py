#!/usr/bin/env python3
# Greenbone 批次掃描：讀 targets 檔案，逐台建立 target → task →
# 啟動掃描 → 輪詢完成 → 下載 PDF 結果。用 gvm-script 執行。
#
# 用法：
#   gvm-script socket --gmp-username admin --gmp-password <密碼> \
#     openvas_batch_scan.gmp.py targets.txt [輸出目錄] [掃描設定UUID] [port_range] [max_hosts] [max_checks]
# port_range 預設 "1-1024"。可先用 nmap 拿各主機開放埠的聯集縮小範圍，
# 例如 "T:80,443,8080,8443"，讓 NVT 只針對實際開口的服務跑。
# max_hosts/max_checks 對應 task 偏好「同時掃描的主機數」與「每台主機同時執行的 NVT 數」。
#
# 在 Greenbone 所在環境內執行（system socket）。要從 mac 操作則用
#   gvm-script ssh --gmp-username admin --host <gvmd主機> --port 9390 ...
# 或先將 gvmd 的 GMP listener 暴露到 mac 可達的位置。
import datetime
import os
import sys
import time

# 預設用 Discovery 掃描設定（3328 個 NVTs，比 Full and fast 的 18 萬個快很多）。
# 需要完整掃描時，用第三個引數指定 Full and fast 的 UUID：
#   daba56c8-73ec-11df-a475-002264764cea
DEFAULT_CONFIG_ID = "8715c877-47a0-438d-98a3-27c7a6ab2196"
DEFAULT_SCANNER_ID = "08b69003-5fc2-4037-a479-93b440211c73"
PDF_FORMAT_ID = "c402cc3e-b531-11e1-9163-406186ea4fc5"
CSV_FORMAT_ID = "c1645568-627a-11e3-a660-406186ea4fc5"

TERMINAL = {"Done", "Stopped", "Failed"}


def log(msg):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {msg}", flush=True)


def main(gmp, args):
    if len(args.argv) < 2:
        print("用法：openvas_batch_scan.gmp.py targets.txt [輸出目錄] [掃描設定UUID]")
        return 1

    targets_file = args.argv[1]
    out_dir = args.argv[2] if len(args.argv) > 2 else "openvas_results"
    config_id = args.argv[3] if len(args.argv) > 3 else DEFAULT_CONFIG_ID
    port_range = args.argv[4] if len(args.argv) > 4 else "1-1024"
    max_hosts = args.argv[5] if len(args.argv) > 5 else ""
    max_checks = args.argv[6] if len(args.argv) > 6 else ""

    with open(targets_file, encoding="utf-8") as f:
        hosts = [line.strip() for line in f if line.strip()]
    if not hosts:
        print("targets 檔案內沒有主機")
        return 1

    os.makedirs(out_dir, exist_ok=True)
    log(f"共 {len(hosts)} 台，輸出目錄 {out_dir}")

    tasks = []  # [(task_id, report_id, host, task_name)]
    for i, host in enumerate(hosts, 1):
        name = f"host-audit-{host}-{datetime.datetime.now():%Y%m%d%H%M%S}"
        target = gmp.create_target(name=name, hosts=[host], port_range=port_range)
        target_id = target.get("id")
        if not target_id:
            log(f"[{i}/{len(hosts)}] {host} 建立 target 失敗")
            continue

        preferences = {}
        if max_hosts:
            preferences["max_hosts_scan"] = str(max_hosts)
        if max_checks:
            preferences["max_checks_scan"] = str(max_checks)

        task = gmp.create_task(
            name=name,
            config_id=config_id,
            target_id=target_id,
            scanner_id=DEFAULT_SCANNER_ID,
            preferences=preferences or None,
        )
        task_id = task.get("id")
        if not task_id:
            log(f"[{i}/{len(hosts)}] {host} 建立 task 失敗")
            continue

        started = gmp.start_task(task_id)
        report_id = started[0].text if started[0].text else ""
        tasks.append((task_id, report_id, host, name))
        log(f"[{i}/{len(hosts)}] {host} 已啟動，report={report_id}")

    if not tasks:
        print("沒有可輪詢的 task")
        return 1

    _wait_all(gmp, tasks)
    _export_reports(gmp, tasks, out_dir)
    log(f"完成。輸出目錄 {out_dir}")


def _wait_all(gmp, tasks):
    while True:
        remaining = []
        for task_id, report_id, host, name in tasks:
            t = gmp.get_task(task_id=task_id)
            task_el = t.find("task")
            status_el = None
            progress_el = None
            if task_el is not None:
                status_el = task_el.find("status")
                progress_el = task_el.find("progress")
            status = status_el.text if status_el is not None else "?"
            progress = progress_el.text if progress_el is not None else "?"
            if status not in TERMINAL:
                remaining.append((task_id, report_id, host, name))
                log(f"{host} {status} {progress}%")
        if not remaining:
            return
        time.sleep(15)


def _export_reports(gmp, tasks, out_dir):
    for task_id, report_id, host, name in tasks:
        if not report_id:
            log(f"{host} 沒有 report，略過")
            continue
        pdf_file = os.path.join(out_dir, f"{host}.pdf")
        _download(gmp, report_id, PDF_FORMAT_ID, pdf_file)
        log(f"{host} PDF 已存 {pdf_file}")


def _download(gmp, report_id, format_id, out_file):
    from base64 import b64decode
    from pathlib import Path
    import re
    from lxml import etree

    response = gmp.get_report(report_id=report_id, report_format_id=format_id)
    element = response[0]
    raw = etree.tostring(element, encoding="unicode")
    # gvmd 直接把 base64 內容放在 <report> 尾端文字節點，沒有 <content> 包裝。
    # 從整段 XML 中取出像 base64 的長 token。
    match = re.search(r">([A-Za-z0-9+/=]{100,})</report>", raw)
    if not match:
        raise RuntimeError("response 中找不到 base64 內容")
    data = b64decode(match.group(1))
    Path(out_file).write_bytes(data)


if __name__ == "__gmp__":
    main(gmp, args)