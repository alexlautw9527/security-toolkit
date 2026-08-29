#!/usr/bin/env python3
# Greenbone 通用取稿工具：下載指定 report 到檔案，並印出掃描起訖時間。
# 用法（在 greenbone/ 目錄執行）：
#   docker compose -f compose.yaml run -T --rm -v "$PWD:/srv" gvm-tools \
#     gvm-script --gmp-username admin --gmp-password admin socket \
#     /srv/gmp_get_report.gmp.py <report_id> [<format_id>] [<輸出檔路徑>]
# 不帶 format_id 時只印掃描時間資訊；帶 format_id 與輸出檔時下載檔內容。
import base64
import re
from pathlib import Path


def main(gmp, args):
    if len(args.argv) < 2:
        print("用法：gmp_get_report.gmp.py <report_id> [format_id] [out_file]")
        return 1

    report_id = args.argv[1]
    format_id = args.argv[2] if len(args.argv) > 2 else ""
    out = args.argv[3] if len(args.argv) > 3 else ""

    from lxml import etree
    kwargs = {"report_id": report_id}
    if format_id:
        kwargs["report_format_id"] = format_id
    element = gmp.get_report(**kwargs)[0]

    for tag in ("scan_start", "scan_end", "start", "end",
                "creation_time", "modification_time"):
        for el in element.iter():
            if etree.QName(el).localname == tag and el.text:
                print(f"{tag} = {el.text}")

    if format_id and out:
        raw = etree.tostring(element, encoding="unicode")
        match = re.search(r">([A-Za-z0-9+/=]{100,})</report>", raw)
        if not match:
            print("response 中找不到 base64 內容")
            return 1
        data = base64.b64decode(match.group(1))
        Path(out).write_bytes(data)
        print(f"saved {out}")
    return 0


if __name__ == "__gmp__":
    main(gmp, args)