# -*- coding: utf-8 -*-
"""把 weight-server 后端部署到 NAS 上的 Docker。

复用 trilium 项目的 NAS SSH 部署方式（paramiko + sudo），把 server 目录
上传到 NAS，然后 docker build + run。

⚠️ 凭据不写进仓库，按顺序取：
  1. 环境变量 NAS_SSH_PASS / NAS_SSH_USER / NAS_SSH_PORT / NAS_HOSTS / NAS_CRED_FILE
  2. NAS_CRED_FILE 指向的文件（一行：IP 端口 用户 密码）
  3. scripts/nas_config_local.py 里定义的同名变量

用法：
  python nas_deploy_weight.py
"""
import argparse
import base64
import os
import sys
import tarfile
import tempfile
import io

import paramiko

# NAS 上后端数据目录（宿主机挂载，重启不丢数据）
NAS_APP_DIR = os.environ.get("WEIGHT_APP_DIR", "/volume2/docker/weight-server")
CONTAINER_NAME = "weight-server"
HOST_PORT = os.environ.get("WEIGHT_PORT", "18191")
DEFAULT_HOSTS = ["100.95.218.4", "192.168.188.2", "192.168.31.198"]

# 上传 server 目录哪些文件（排除 node_modules/data）
INCLUDE_NAMES = {"package.json", "Dockerfile", ".env.example"}
INCLUDE_DIRS = {"src"}

CHUNK = 16000
PASSWORD = ""


def load_config():
    user = os.environ.get("NAS_SSH_USER", "")
    password = os.environ.get("NAS_SSH_PASS", "")
    port = int(os.environ.get("NAS_SSH_PORT", "8122") or 8122)
    hosts = [h for h in os.environ.get("NAS_HOSTS", "").split(",") if h]
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import nas_config_local as local  # noqa: F401
        user = getattr(local, "NAS_SSH_USER", user) or user
        password = getattr(local, "NAS_SSH_PASS", password) or password
        port = getattr(local, "NAS_SSH_PORT", port) or port
        hosts = getattr(local, "NAS_HOSTS", hosts) or hosts
    except ImportError:
        pass
    cred_file = os.environ.get("NAS_CRED_FILE", "")
    if cred_file and os.path.isfile(cred_file):
        with open(cred_file, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 4 and not line.strip().startswith("#"):
                    hosts = hosts or [parts[0]]
                    port = int(parts[1])
                    user = user or parts[2]
                    password = password or parts[3]
                    break
    return user, password, port, hosts or DEFAULT_HOSTS


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run(client, cmd, timeout=900):
    # 群晖 docker 在 /usr/local/bin（sudo 的 PATH 不含），先补 PATH 再执行
    full = "export PATH=/usr/local/bin:/usr/local/sbin:/usr/syno/bin:$PATH; " + cmd
    chan = client.exec_command(
        "echo '%s' | sudo -S -p '' bash -c %s" % (PASSWORD, shq(full)), timeout=timeout)
    out = chan[1].read().decode("utf-8", "replace")
    err = chan[2].read().decode("utf-8", "replace")
    return out, err


def connect(user, password, port, hosts):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    for h in hosts:
        try:
            client.connect(h, port=port, username=user, password=password, timeout=12,
                           allow_agent=False, look_for_keys=False)
            print("已连接 %s" % h, flush=True)
            return client, h
        except Exception as e:
            print("  [%s] %s" % (h, e), flush=True)
    print("__FAIL__ 连不上 NAS")
    sys.exit(2)


def make_tarball(server_dir):
    """把 server 目录打包成 tar.gz 字节流（排除 node_modules/data/.env）。"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for root, dirs, files in os.walk(server_dir):
            dirs[:] = [d for d in dirs if d not in ("node_modules", "data", ".git")]
            rel_root = os.path.relpath(root, server_dir)
            for f in files:
                if f in (".env", "*.db"):
                    continue
                full = os.path.join(root, f)
                arc = os.path.join("server", rel_root, f).replace("\\", "/")
                tar.add(full, arcname=arc)
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server"),
                    help="后端 server 目录路径")
    args = ap.parse_args()

    server_dir = os.path.abspath(args.server_dir)
    if not os.path.isfile(os.path.join(server_dir, "package.json")):
        print("找不到 package.json: %s" % server_dir)
        sys.exit(1)

    global PASSWORD
    user, PASSWORD, port, hosts = load_config()
    if not PASSWORD:
        print("缺少 NAS 密码：请设 NAS_SSH_PASS 或 NAS_CRED_FILE / scripts/nas_config_local.py")
        sys.exit(1)

    # JWT_SECRET：环境变量 > nas_config_local.WEIGHT_JWT_SECRET > 默认
    jwt_secret = os.environ.get("JWT_SECRET", "")
    if not jwt_secret:
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import nas_config_local as _lc
            jwt_secret = getattr(_lc, "WEIGHT_JWT_SECRET", "")
        except ImportError:
            pass
    if not jwt_secret:
        jwt_secret = "change-me-in-production"

    client, _ = connect(user, PASSWORD, port, hosts)
    try:
        print("拉取 ghcr.io 镜像…")
        image = "ghcr.io/hhxxc/weight-server:latest"
        out, err = run(client, "docker pull %s" % image, timeout=900)
        print(out.strip())
        if err.strip():
            print("[stderr] %s" % err.strip()[:300])

        print("启动容器…")
        run_cmd = (
            "docker rm -f %s 2>/dev/null; "
            "docker run -d --name %s --restart unless-stopped "
            "-p %s:3000 "
            "-e JWT_SECRET=%s "
            "-v %s/data:/data "
            "-v /volume2/docker/giliconcloude_key.txt:/data/giliconcloude_key.txt:ro "
            "%s"
            % (CONTAINER_NAME, CONTAINER_NAME, HOST_PORT, shq(jwt_secret), shq(NAS_APP_DIR), image)
        )
        out, err = run(client, run_cmd, timeout=120)
        print(out.strip())
        if err.strip():
            print("[stderr] %s" % err.strip()[:300])

        print("容器状态：")
        out, _ = run(client, "docker ps --filter name=%s --format '{{.Names}} {{.Status}} {{.Ports}}'" % CONTAINER_NAME)
        print(out.strip())
    finally:
        client.close()

    print("\n部署完成。后端地址：")
    print("  内网：http://<NAS_IP>:%s" % HOST_PORT)
    print("  公网：https://<你的 ddnsto 域名>")
    print("下一步：在 iOS App 登录页填服务器地址（或改 AppConfig.swift 默认值）")


if __name__ == "__main__":
    main()
