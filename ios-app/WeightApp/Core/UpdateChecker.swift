import Foundation
import UIKit

/// 更新检测结果
enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, releaseURL: URL?, ipaURL: URL?)
    case failed(message: String)
}

/// 版本更新检测器（抄巢记成熟实现，纯原生 URLSession）。
///
/// 关键点（踩过的坑）：
///   - 并行查两个来源（NAS 清单 + GitHub Releases），取版本号较大者
///   - NAS 清单 ipaUrl 指向自有域名，国内秒下；GitHub 直链仅兜底
///   - 版本号必须是三段语义版本（x.y.z），避免四段/前导零污染比较
enum UpdateChecker {
    static let repo = "hhxxc/weight-app"
    static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases")!

    /// 本机 App 版本号（CFBundleShortVersionString，CI 构建时注入真实版本）
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 清单地址（NAS 自有域名，与巢记共用同一条 *.ipa 无鉴权路由）
    /// manifest-weight.ipa —— 内容是 JSON、后缀 .ipa → 服务端按二进制下发，
    /// 避开原生层对 application/json 的强制解析坑
    static let manifestURLs: [String] = [
        "https://ezbookx.x.ddnsto.com/api/nestkeep/manifest-weight.ipa",
    ]

    private struct Manifest: Decodable {
        let version: String?
        let ipaUrl: String?
        let releaseUrl: String?
    }

    private struct LatestInfo {
        let version: String
        let releaseURL: URL?
        let ipaURL: URL?
    }

    /// 查询最新版本并比对：并行查 NAS 清单 + GitHub，取较大版本
    static func checkAppUpdate() async -> UpdateCheckResult {
        let current = currentAppVersion

        async let backend = queryBackend()
        async let github = queryGitHub()
        let b = await backend
        let g = await github

        let candidates = [b, g].compactMap { $0 }
        guard let best = candidates.max(by: { compareVersion($0.version, $1.version) < 0 }) else {
            return .failed(message: "无法获取版本信息，请稍后重试")
        }

        if compareVersion(best.version, current) > 0 {
            return .updateAvailable(current: current, latest: best.version,
                                    releaseURL: best.releaseURL, ipaURL: best.ipaURL)
        }
        return .upToDate(current: current)
    }

    private static func queryBackend() async -> LatestInfo? {
        for urlStr in manifestURLs {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.timeoutInterval = 15

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                AppLogger.shared.log("更新源失败: \(urlStr.prefix(60))")
                continue
            }
            guard let m = try? JSONDecoder().decode(Manifest.self, from: data),
                  let v = m.version, isSemanticVersion(normalizeVersion(v)) else {
                AppLogger.shared.log("更新源响应无效: \(urlStr.prefix(60)) \(data.count)字节")
                continue
            }
            AppLogger.shared.log("更新源命中: \(urlStr.prefix(60)) → v\(v)")
            return LatestInfo(
                version: normalizeVersion(v),
                releaseURL: m.releaseUrl.flatMap { URL(string: $0) },
                ipaURL: m.ipaUrl.flatMap { URL(string: $0) }
            )
        }
        return nil
    }

    private static func queryGitHub() async -> LatestInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WeightApp", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var best: LatestInfo?
        for r in releases {
            if (r["draft"] as? Bool) == true { continue }
            if (r["prerelease"] as? Bool) == true { continue }
            guard let tag = r["tag_name"] as? String, !tag.isEmpty else { continue }
            let v = normalizeVersion(tag)
            guard isSemanticVersion(v) else { continue }
            let releaseURL = (r["html_url"] as? String).flatMap { URL(string: $0) }
            let ipaURL = ipaAssetURL(from: r)
            let info = LatestInfo(version: v, releaseURL: releaseURL, ipaURL: ipaURL)
            if let cur = best {
                if compareVersion(info.version, cur.version) > 0 { best = info }
            } else {
                best = info
            }
        }
        return best
    }

    private static func ipaAssetURL(from release: [String: Any]) -> URL? {
        guard let assets = release["assets"] as? [[String: Any]] else { return nil }
        for a in assets {
            if let name = a["name"] as? String, name.lowercased().hasSuffix(".ipa"),
               let urlStr = a["browser_download_url"] as? String, let u = URL(string: urlStr) {
                return u
            }
        }
        return nil
    }

    /// 下载候选源，按「国内能不能秒通」排序（手机直连 github 大概率挂死到超时，
    /// 所以 GitHub 永远排最后兜底）：
    ///   1. NAS 公网直链（正常秒下）
    ///   2. 内网镜像（家里 Wi-Fi 直接打 NAS）
    ///   3. 清单给的地址（若来自 GitHub API 就是 github 原链）
    ///   4. GitHub Releases 原链（保底）
    static func downloadCandidates(ipaURL: URL, version: String?) -> [URL] {
        var candidates: [URL] = []
        func push(_ url: URL?) {
            guard let url, !candidates.contains(url) else { return }
            candidates.append(url)
        }

        let fileName = ipaURL.lastPathComponent.isEmpty ? "weight-app.ipa" : ipaURL.lastPathComponent
        push(URL(string: "https://ezbookx.x.ddnsto.com/api/nestkeep/\(fileName)"))
        push(lanMirrorURL(fileName: fileName))
        push(ipaURL)
        if let v = version, !v.isEmpty,
           let gh = URL(string: "https://github.com/\(repo)/releases/download/v\(v)/weight-app.ipa") {
            push(gh)
        }
        return candidates
    }

    /// 内网镜像地址：从内网地址取 host，拼 nestkeep 分发端口 9180
    static func lanMirrorURL(fileName: String) -> URL? {
        guard !fileName.isEmpty else { return nil }
        guard let host = URL(string: AppConfig.defaultBackupServer)?.host, !host.isEmpty else { return nil }
        let isPrivate = host.hasPrefix("192.168.") || host.hasPrefix("10.")
            || host.hasPrefix("172.") || host == "localhost"
        if isPrivate {
            return URL(string: "http://\(host):9180/api/nestkeep/\(fileName)")
        }
        return nil
    }

    /// 下载 IPA：逐个尝试候选源，任一个成功即返回落盘 URL
    static func download(ipaURL: URL, version: String) async throws -> URL {
        let candidates = downloadCandidates(ipaURL: ipaURL, version: version)
        let dest = UpdateFileStore.destinationURL(version: version)
        var lastError: Error?

        for url in candidates {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 20
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      data.count > 1024, data.starts(with: [0x50, 0x4B]) else {
                    throw NSError(domain: "update", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "响应无效"])
                }
                try data.write(to: dest)
                AppLogger.shared.log("IPA 下载成功：\(url.host ?? "") → \(dest.lastPathComponent)")
                return dest
            } catch {
                lastError = error
                AppLogger.shared.log("下载源失败: \(url.host ?? "") \(error.localizedDescription)")
            }
        }
        throw lastError ?? NSError(domain: "update", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "所有下载源均失败"])
    }

    // MARK: - 版本号工具

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// 是否形如 x.y.z 的三段语义版本（无前导零）
    static func isSemanticVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        for p in parts {
            if p.isEmpty || !p.allSatisfy({ $0.isNumber }) { return false }
            if p.count > 1 && p.first == "0" { return false }
        }
        return true
    }

    static func compareVersion(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}

/// 已下载 IPA 的落盘管理（Caches 目录）
enum UpdateFileStore {
    static func destinationURL(version: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("WeightUpdate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Weight-\(version).ipa")
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }
}

/// 弹出系统分享面板，用户选 TrollStore 安装
enum IPAShare {
    static func share(fileURL: URL, title: String) {
        let items: [Any] = [fileURL]
        let avc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(avc, animated: true)
    }
}
