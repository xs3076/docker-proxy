#!/usr/bin/env python3
"""
直接调用阿里云 ACR 个人版 OpenAPI（cr-2016-06-07），绕开 aliyun-cli。

用法:
  aliyun_cr.py GET /repos/<namespace>
  aliyun_cr.py GET '/repos/<namespace>?Page=1&PageSize=100'
  aliyun_cr.py GET /repos/<namespace>/<repo>/tags

环境变量:
  ALIYUN_ACCESS_KEY, ALIYUN_ACCESS_SECRET, ALIYUN_REGION (默认 cn-hangzhou)

输出: 成功时 stdout 输出 JSON; 失败时 stderr 输出错误并退出非零。
"""
import os
import re
import sys
import hmac
import json
import uuid
import base64
import hashlib
import datetime
import pathlib
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


def load_dotenv() -> None:
    """从脚本同级目录或项目根目录的 .env 加载环境变量（不覆盖已有值）"""
    here = pathlib.Path(__file__).resolve().parent
    for candidate in (here / ".env", here.parent / ".env"):
        if not candidate.is_file():
            continue
        for line in candidate.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip().strip('"').strip("'")
            os.environ.setdefault(key, val)


def resolve_region() -> str:
    if region := os.environ.get("ALIYUN_REGION"):
        return region
    if registry := os.environ.get("ALIYUN_REGISTRY"):
        m = re.search(r"\.(cn-[a-z0-9-]+|[a-z]{2}-[a-z]+-\d+)\.", registry)
        if m:
            return m.group(1)
    return "cn-hangzhou"


def call(method: str, raw_path: str) -> dict:
    ak = os.environ["ALIYUN_ACCESS_KEY"]
    sk = os.environ["ALIYUN_ACCESS_SECRET"]
    host = f"cr.{resolve_region()}.aliyuncs.com"

    parts = urlsplit(raw_path)
    path = parts.path
    if parts.query:
        sorted_qs = "&".join(sorted(parts.query.split("&")))
        canon_resource = f"{path}?{sorted_qs}"
    else:
        canon_resource = path

    date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    accept = "application/json"
    headers = {
        "Date": date,
        "Accept": accept,
        "Host": host,
        "x-acs-version": "2016-06-07",
        "x-acs-signature-method": "HMAC-SHA1",
        "x-acs-signature-nonce": str(uuid.uuid4()),
        "x-acs-signature-version": "1.0",
    }

    acs_headers = sorted(
        (k.lower(), v) for k, v in headers.items() if k.lower().startswith("x-acs-")
    )
    canon_headers = "\n".join(f"{k}:{v}" for k, v in acs_headers)

    string_to_sign = "\n".join([method, accept, "", "", date, canon_headers, canon_resource])

    sig = base64.b64encode(
        hmac.new(sk.encode(), string_to_sign.encode(), hashlib.sha1).digest()
    ).decode()
    headers["Authorization"] = f"acs {ak}:{sig}"

    url = f"https://{host}{canon_resource}"
    req = Request(url, method=method, headers=headers)
    try:
        with urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except HTTPError as e:
        body = e.read().decode(errors="replace") if e.fp else ""
        print(f"HTTP {e.code} {e.reason}: {body}", file=sys.stderr)
        sys.exit(1)
    except URLError as e:
        print(f"network error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    load_dotenv()
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    print(json.dumps(call(sys.argv[1].upper(), sys.argv[2])))
