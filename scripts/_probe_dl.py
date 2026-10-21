import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paramiko, nas_deploy_weight as dep
user, password, port, hosts = dep.load_config()
dep.PASSWORD = password
client, host = dep.connect(user, password, port, hosts)
def r(cmd):
    out, err = dep.run(client, cmd, timeout=180)
    return out.strip(), err.strip()
tok = sys.argv[1]
url = "https://api.github.com/repos/hhxxc/weight-app/releases/assets/662646302"
out, err = r("curl -s -m 90 -o /dev/null -w '%%{http_code} %%{size_download}' -L -H 'Authorization: token %s' -H 'Accept: application/octet-stream' '%s' 2>&1" % (tok, url))
print("=== API 下载状态码+大小 ===")
print(out or err or "(空)")
client.close()
