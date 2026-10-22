# 体重记录 App

手机版体重 / 饮食记录应用 —— **SwiftUI 原生 iOS App**（iOS 15.1+）+ **NAS 自建轻量后端**。
多账号注册登录、数据按账号隔离，支持体重记录、BMI 自动计算、趋势图、目标管理、饮食记录、Excel 历史数据导入。

参考 [trilium-mobile](../trilium-mobile) 项目的工程骨架（`gen_pbxproj.py` 生成工程、主备服务器自动互换、token 存 Keychain、连接健壮性）。

## 功能

**体重 / BMI / 趋势（核心）**
- 每日体重录入（同一天重复记录自动覆盖）
- 最新体重 + BMI 概览卡片（中国标准分级：偏瘦/正常/超重/肥胖）
- 目标体重管理 + 减重进度条
- 体重趋势折线图（自绘，兼容 iOS 15，不依赖 Swift Charts）

**饮食记录**
- 按日期记录每餐（早/午/晚/加餐）
- 日期切换器浏览历史

**账号体系**
- 注册 / 登录（JWT token，bcrypt 密码哈希）
- 数据按账号隔离（服务端 SQLite 按 user_id 区分）
- token 存 Keychain（写失败回退 UserDefaults）

**数据导入**
- 从 Excel（.xlsx）或 CSV 导入历史体重
- 自动识别「日期」「体重」「备注」列，支持 Excel 日期序列号和 YYYY-MM-DD

**连接健壮性**
- 主备服务器地址自动互换（公网 ddnsto 穿透 + 内网直连）
- 业务 401 自动清 token 踢回登录

## 工程结构

| 路径 | 说明 |
|---|---|
| `server/` | 后端（Node.js + SQLite + JWT），`src/index.js` 单文件 REST API |
| `ios-app/` | SwiftUI 工程；`gen_pbxproj.py` 生成 `.xcodeproj`，**增删 Swift 文件必须重跑** |
| `scripts/` | `nas_deploy_weight.py` 部署后端到 NAS |

## 后端 API

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/auth/register` | 注册（返回 token + user） |
| POST | `/api/auth/login` | 登录 |
| GET/PUT | `/api/me` | 个人资料（身高/目标体重/昵称） |
| GET/POST | `/api/weights` | 体重列表 / 写入（同日覆盖） |
| DELETE | `/api/weights/:date` | 删除某日体重 |
| POST | `/api/weights/import` | 批量导入 |
| GET/POST | `/api/meals` | 饮食列表 / 新增 |
| DELETE | `/api/meals/:id` | 删除饮食 |

除注册/登录外，所有接口需 `Authorization: Bearer <token>`。

## 本地开发

```bash
# 后端
cd server
npm install
PORT=3000 JWT_SECRET=dev-secret node src/index.js

# iOS（在 Mac 上）
cd ios-app
python3 gen_pbxproj.py          # 生成工程（增删 Swift 文件后必须重跑）
open WeightApp.xcodeproj         # Xcode 打开，选真机运行
```

## 部署到 NAS

后端 Docker 部署（参考 trilium 项目的 paramiko 方式）：

```bash
# 先确认 scripts/nas_config_local.py 有 NAS 凭据（或设 NAS_SSH_* 环境变量）
python scripts/nas_deploy_weight.py
```

默认监听 NAS 的 `18191` 端口，数据持久化在 `/volume2/docker/weight-server/data`。

### 手动部署（不用脚本）

```bash
cd server
docker build -t weight-server .
docker run -d --name weight-server --restart unless-stopped \
  -p 18191:3000 \
  -e JWT_SECRET=换成强随机值 \
  -v /volume2/docker/weight-server/data:/data \
  weight-server
```

## 服务器地址配置

App 登录页可填服务器地址（留空用 `AppConfig.swift` 里的默认值）。默认：

- 主：`https://c2r2t8t4.x.ddnsto.com`（公网穿透，已映射到 NAS 18191 端口）
- 备：`http://192.168.31.198:18191`（内网直连）

主备自动互换：主地址连不上自动切备用，成功后记住。

## 数据导入格式

.xlsx / .csv 需包含表头「日期」「体重」两列（可选「备注」）：

```
日期,体重,备注
2026-10-01,72.5,开始记录
2026-10-02,72.1,
```

日期支持 `YYYY-MM-DD`、`YYYY/M/D`、`YYYY.M.D`，以及 Excel 日期序列号。
