# HANDOFF — 体重记录 App 交接说明

给「切会话后继续」的 AI 同事看的当前状态与下一步。

## 项目状态（2026-10-21）

✅ 已完成，代码可交付：
- **后端** `server/`：Node.js + better-sqlite3 + JWT，单文件 `src/index.js`，已本地实测注册/登录/体重/导入/饮食/鉴权全部通过
- **iOS App** `ios-app/WeightApp/`：18 个 Swift 文件，功能齐全（登录、体重列表+概览+BMI、趋势图、饮食、我的/资料/目标、导入）
- **工程生成器** `ios-app/gen_pbxproj.py`：单 target 精简版，已跑通（18 swift 文件）
- **部署脚本** `scripts/nas_deploy_weight.py` + README

## ⚠️ 未完成 / 待办

1. **iOS 未编译验证**：Windows 上无 Swift 工具链，代码只做了人工自查，**未在 Xcode 上编译过**。首次在 Mac 上打开需重点核对：
   - `XLSXParser.swift` 的 `Compression` 框架 `compression_decode_buffer` 签名（raw deflate 用 `COMPRESSION_ZLIB`）
   - `@MainActor final class AppState` 的 static let 单例隔离
   - `UniformTypeIdentifiers` 的 `.xlsx` UTType（可能需自定义，见下）
   - `TrendChartView` 的 `ForEach(Array(pts.enumerated()), id: \.offset)`

2. **UTType .xlsx 可能不存在**：iOS 的 `UTType.xlsx` 是 iOS 14+ 才有的类型，若编译报错，改用 `UTType(filenameExtension: "xlsx")` 或 `UTType.commaSeparatedText` 兜底。见 `ProfileView.swift` 的 `fileImporter` 调用处。

3. **xlsx 解析器的列对齐**：当前靠 `<c>` 出现顺序对齐，未用 `r="A1"` 引用号定位。对紧凑表格（日期/体重/备注连续无空洞）够用；若用户的真实表格有空单元格可能错位。用户有真实文件 `F:\ThinkbookUserData\Downloads\每日体重记录.xlsx`（本次会话被安全策略拦截，**未能读取其真实列结构**）——下次建议先读该文件确认真实表头/列顺序再校准。

4. **服务器地址**：`AppConfig.swift` 里的 `defaultServer`（ddnsto 公网）和 `defaultBackupServer`（内网 18190）是占位，需按实际 NAS 配置填。ddnsto 映射尚未配置。

5. **App 图标**：`Assets.xcassets` 是空壳，缺 AppIcon 图片。

## 关键决策（已与用户确认）

- 数据存储：**NAS 自建后端，账号区分**（多用户隔离）
- 工程位置：`D:/weight-app`（独立，与 trilium-mobile 平级）
- 功能范围：饮食记录 + 体重/BMI/趋势 + 目标管理 + 数据导入（全选）

## 复用的 trilium-mobile 骨架

- `gen_pbxproj.py` 思路 → 精简为单 target 版
- 主备地址互换（`APIClient.candidateServers`）
- token 存 Keychain 失败回退 UserDefaults（`Keychain.swift`）
- `AppLogger` / `AppState` 单例模式
- iOS 15 兼容红线：禁 NavigationStack、禁 TextField(axis:)、热区≥44pt、工具栏 segmented Picker 不放 toolbar（本项目 Picker 放在 Form 里 OK）

## 后端技术要点

- `better-sqlite3` 是原生模块，Docker 里需 `node:20-slim` 编译（Dockerfile 已处理）
- 体重同日唯一约束 `UNIQUE(user_id, date)` + `ON CONFLICT DO UPDATE`（覆盖）
- JWT 90 天有效期，`JWT_SECRET` 生产必改
- 导入接口 `/api/weights/import` 收 `{items:[{date,kg,note}]}`，客户端先解析再批量提交

## 下一步建议顺序

1. 读真实 xlsx 文件结构（换路径或让用户确认放行）
2. Mac 上 `python3 gen_pbxproj.py` + Xcode 编译，修编译错误
3. 配 NAS 部署 + ddnsto 公网映射
4. 补 App 图标
