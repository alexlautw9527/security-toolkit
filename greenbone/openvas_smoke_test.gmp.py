#!/usr/bin/env python3
# Greenbone 冒煙測試：對目標主機建 target → task → 啟動 → 輪詢 → 取報告。
# 全部在單支腳本內完成，用來驗證安裝是否端到端可用。
import datetime
import os
import time

# 用 Discovery config（版本 20201215），比 Full and fast 快很多。
DISCOVERY_CONFIG_ID = "8715c877-47a0-438d-98a3-27c7a6ab2196"
SCANNER_ID = "08b69003-5fc2-4037-a479-93b440211c73"
CSV_FORMAT_ID = "c1645568-627a-11e3-a660-406186ea4fc5"

TERMINAL = {"Done", "Stopped", "Failed"}


def log(msg):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {msg}", flush=True)


def main(gmp, args):
    host = args.argv[1] if len(args.argv) > 1 else "127.0.0.1"
    out_dir = args.argv[2] if len(args.argv) > 2 else "openvas_smoke_out"
    os.makedirs(out_dir, exist_ok=True)

    name = f"smoke-{host}-{datetime.datetime.now():%Y%m%d%H%M%S}"
    target = gmp.create_target(name=name, hosts=[host], port_range="1-1024")
    target_id = target.get("id")
    log(f"target {target_id} for {host}")

    task = gmp.create_task(
        name=name, config_id=DISCOVERY_CONFIG_ID,
        target_id=target_id, scanner_id=SCANNER_ID,
    )
    task_id = task.get("id")
    log(f"task {task_id}")

    started = gmp.start_task(task_id)
    report_id = started[0].text
    log(f"started, report {report_id}")

    while True:
        t = gmp.get_task(task_id=task_id)
        task_el = t.find("task")
        status_el = None
        progress_el = None
        if task_el is not None:
            status_el = task_el.find("status")
            progress_el = task_el.find("progress")
        status = status_el.text if status_el is not None else "?"
        progress = progress_el.text if progress_el is not None else "?"
        log(f"  task status={status} progress={progress}%")
        if status in TERMINAL:
            break
        time.sleep(10)

    if status != "Done":
        log(f"task not Done ({status}), skip report download")
        return 1

    from base64 import b64decode
    from pathlib import Path

    response = gmp.get_report(report_id=report_id, report_format_id=CSV_FORMAT_ID)
    content = "".join(response[0].itertext())
    out_file = os.path.join(out_dir, f"{host}.csv")
    Path(out_file).write_bytes(b64decode(content.encode("ascii")))
    log(f"report saved to {out_file}")
    return 0


if __name__ == "__gmp__":
    main(gmp, args)