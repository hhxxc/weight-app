# -*- coding: utf-8 -*-
"""weight-app NAS 侧一次性配置：上传自动同步脚本 + 写入 /etc/crontab（root）。

复用 nas_deploy_weight.py 的 load_config / connect / run（paramiko + sudo）。
本脚本幂等：重复跑只会刷新脚本内容，不会重复追加 crontab。

首次部署后端用 nas_deploy_weight.py（本地打包上传），本脚本只负责把「自动同步」挂上。

用法（须用系统 Python，含 paramiko）：
    C:/Python314/python.exe scripts/nas_setup_weight.py
"""
import base64
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paramiko  # noqa: E402
import nas_deploy_weight as dep  # noqa: E402

EZBK_DIR = "/volume2/docker/ezbk"

# 两个同步脚本（本地路径 → NAS 落地路径）
SYNC_SCRIPTS = {
    "weight_autosync.sh": f"{EZBK_DIR}/weight_autosync.sh",
    "weight_server_autosync.sh": f"{EZBK_DIR}/weight_server_autosync.sh",
}

# /etc/crontab 追加行（群晖用 root 的 /etc/crontab，不是 crontab -e）
CRON_LINES = [
    "*/5\t*\t*\t*\t*\troot\t/bin/sh /volume2/docker/ezbk/weight_autosync.sh > /dev/null 2>&1",
    "*/5\t*\t*\t*\t*\troot\t/bin/sh /volume2/docker/ezbk/weight_server_autosync.sh > /dev/null 2>&1",
]


def read_script(name):
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "nas", name)
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def upload_text(client, text, remote_path):
    """用 base64 把文本（保持 LF）传到 NAS 指定路径。"""
    dep.run(client, "mkdir -p %s" % dep.shq(os.path.dirname(remote_path)))
    b64 = base64.b64encode(text.encode("utf-8")).decode("ascii")
    dep.run(client, ": > /tmp/_w.txt")
    chunk = 8000
    for i in range(0, len(b64), chunk):
        dep.run(client, "echo %s >> /tmp/_w.txt" % dep.shq(b64[i:i + chunk]))
    dep.run(client, "base64 -d /tmp/_w.txt > %s && rm -f /tmp/_w.txt && chmod +x %s" % (dep.shq(remote_path), dep.shq(remote_path)))
    out, _ = dep.run(client, "wc -l %s" % dep.shq(remote_path))
    print("  已上传 %s（%s）" % (remote_path, out.strip()))


def setup_cron(client):
    out, _ = dep.run(client, "cat /etc/crontab 2>/dev/null")
    has_ipa = "weight_autosync.sh" in out
    has_srv = "weight_server_autosync.sh" in out
    if has_ipa and has_srv:
        print("  /etc/crontab 已包含 weight 同步任务，跳过")
        return
    add = []
    if not has_ipa:
        add.append(CRON_LINES[0])
    if not has_srv:
        add.append(CRON_LINES[1])
    for line in add:
        dep.run(client, "printf '%%s\\n' %s >> /etc/crontab" % dep.shq(line))
    print("  已写入 /etc/crontab %d 条" % len(add))


def main():
    user, password, port, hosts = dep.load_config()
    if not password:
        print("缺少 NAS 密码：请设 NAS_SSH_PASS 或 scripts/nas_config_local.py")
        sys.exit(1)
    dep.PASSWORD = password

    client, host = dep.connect(user, password, port, hosts)
    print("已连接 NAS %s" % host)

    try:
        print("== 侦察 ==")
        out, _ = dep.run(client, "docker --version 2>&1 | head -1")
        print("  docker: %s" % out.strip())
        out, _ = dep.run(client, "docker ps -a --filter name=weight-server --format '{{.Names}} {{.Status}} {{.Ports}}' 2>&1")
        print("  weight-server 容器: %s" % (out.strip() or "（无）"))
        out, _ = dep.run(client, "docker ps --filter name=trilium --format '{{.Names}} {{.Ports}}' 2>&1")
        print("  trilium 容器: %s" % (out.strip() or "（无）"))
        out, _ = dep.run(client, "ls -d %s 2>/dev/null && echo OK || echo MISSING" % dep.shq(EZBK_DIR))
        print("  %s: %s" % (EZBK_DIR, out.strip().splitlines()[-1]))

        print("== 上传同步脚本 ==")
        for name, remote in SYNC_SCRIPTS.items():
            upload_text(client, read_script(name), remote)

        print("== 配置 /etc/crontab ==")
        setup_cron(client)

        print("== 验证 ==")
        out, _ = dep.run(client, "grep -c weight_.*autosync /etc/crontab")
        print("  crontab 同步任务条数: %s" % out.strip())
        out, _ = dep.run(client, "ls -l %s/weight_autosync.sh %s/weight_server_autosync.sh 2>&1" % (EZBK_DIR, EZBK_DIR))
        print(out.strip())
    finally:
        client.close()

    print("\n同步脚本已挂上（每 5 分钟）。首次部署后端请跑：")
    print("  C:/Python314/python.exe scripts/nas_deploy_weight.py")


if __name__ == "__main__":
    main()
