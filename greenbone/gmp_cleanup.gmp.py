#!/usr/bin/env python3
# Greenbone 清理工具：依 id 停止 task，或刪除 task / target。
# 用法（在 greenbone/ 目錄執行）：
#   docker compose -f compose.yaml run -T --rm -v "$PWD:/srv" gvm-tools \
#     gvm-script --gmp-username admin --gmp-password admin socket \
#     /srv/gmp_cleanup.gmp.py stop=<task_id> task=<task_id> target=<target_id>
# 用 stop= / task= / target= 前綴辨識，避免與 gvm-script 自己的 --task 等選項衝突。
import sys


def main(gmp, args):
    stop_ids = []
    task_ids = []
    target_ids = []
    for a in args.argv[1:]:
        if a.startswith("stop="):
            stop_ids.append(a[len("stop="):])
        elif a.startswith("task="):
            task_ids.append(a[len("task="):])
        elif a.startswith("target="):
            target_ids.append(a[len("target="):])
        else:
            print(f"無法辨識參數：{a}")
            return 1

    for tid in stop_ids:
        try:
            gmp.stop_task(task_id=tid)
            print(f"stopped task {tid}")
        except Exception as ex:
            print(f"skip stop {tid}: {ex}")

    for tid in task_ids:
        try:
            gmp.delete_task(task_id=tid)
            print(f"deleted task {tid}")
        except Exception as ex:
            print(f"skip task {tid}: {ex}")

    for tid in target_ids:
        try:
            gmp.delete_target(target_id=tid)
            print(f"deleted target {tid}")
        except Exception as ex:
            print(f"skip target {tid}: {ex}")
    return 0


if __name__ == "__gmp__":
    main(gmp, args)