import SwiftUI

/// 「软件更新」页：检查更新 → 下载 IPA → 交给 TrollStore 安装
struct UpdateView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var message = ""
    @State private var latestVersion: String?
    @State private var readyURL: URL?

    enum Phase {
        case idle
        case checking
        case downloading
        case ready
        case failed
    }

    private var currentVersion: String { UpdateChecker.currentAppVersion }
    private var busy: Bool { phase == .checking || phase == .downloading }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("体重记录").font(.headline)
                        Text("当前版本 v\(currentVersion)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                switch phase {
                case .idle:
                    Label("点击下方按钮检查更新", systemImage: "arrow.clockwise")
                        .foregroundColor(.secondary)
                case .checking:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在检查更新…").foregroundColor(.secondary)
                    }
                case .downloading:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在下载安装包…").foregroundColor(.secondary)
                    }
                case .ready:
                    VStack(alignment: .leading, spacing: 10) {
                        Label("v\(latestVersion ?? "") 安装包已就绪", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Button {
                            install()
                        } label: {
                            Text("安装 v\(latestVersion ?? "")")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 2)
                case .failed:
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    Task { await checkAndDownload() }
                } label: {
                    Text(busy ? "请稍候…" : "检查更新")
                        .frame(maxWidth: .infinity)
                }
                .disabled(busy)
            } footer: {
                Text("安装包从 NAS 自有域名下载（国内直连快）；源连不上会自动换内网或 GitHub 兜底。下载后点「安装」选 TrollStore 覆盖安装，数据保留。")
            }
        }
        .navigationTitle("软件更新")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private func checkAndDownload() async {
        phase = .checking
        let result = await UpdateChecker.checkAppUpdate()
        switch result {
        case .upToDate:
            phase = .idle
            message = "已是最新版本"
        case .failed(let m):
            phase = .failed
            message = m
        case .updateAvailable(_, let latest, _, let ipaURL):
            latestVersion = latest
            guard let url = ipaURL else {
                phase = .failed
                message = "无可用下载地址"
                return
            }
            phase = .downloading
            do {
                let file = try await UpdateChecker.download(ipaURL: url, version: latest)
                readyURL = file
                phase = .ready
            } catch {
                phase = .failed
                message = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    private func install() {
        guard let url = readyURL else { return }
        IPAShare.share(fileURL: url, title: "体重记录 v\(latestVersion ?? "")")
    }
}
