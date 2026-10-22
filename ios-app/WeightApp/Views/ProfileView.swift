import SwiftUI
import UniformTypeIdentifiers

/// 「我的」页：个人资料（身高/目标体重）、数据导入、设置、退出
struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @State private var showImport = false

    private var initial: String {
        let name = state.user?.nickname.isEmpty == false ? state.user!.nickname : state.user?.username ?? "?"
        return String(name.prefix(1))
    }

    var body: some View {
        NavigationView {
            List {
                // 个人资料头部卡片
                Section {
                    NavigationLink(destination: ProfileEditView()) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Theme.brandGradient)
                                    .frame(width: 56, height: 56)
                                Text(initial)
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.user?.nickname.isEmpty == false ? state.user!.nickname : state.user?.username ?? "未登录")
                                    .font(.headline)
                                Text("@\(state.user?.username ?? "")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("数据") {
                    Button { showImport = true } label: {
                        Label("从 Excel 导入体重", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        Label("服务器设置", systemImage: "server.rack")
                    }
                }

                Section("关于") {
                    NavigationLink {
                        UpdateView()
                    } label: {
                        Label("软件更新", systemImage: "arrow.down.circle")
                    }
                    Label("体重记录 v\(UpdateChecker.currentAppVersion)", systemImage: "info.circle")
                        .foregroundColor(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        state.logout()
                    } label: {
                        Text("退出登录")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("我的")
            .sheet(isPresented: $showImport) {
                ImportView()
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 个人资料编辑（昵称/身高/目标体重）
struct ProfileEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var heightText = ""
    @State private var targetText = ""
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("昵称", text: $nickname)
            }
            Section {
                HStack {
                    Text("身高")
                    TextField("cm", text: $heightText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("cm")
                }
                HStack {
                    Text("目标体重")
                    TextField("kg", text: $targetText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("kg")
                }
            } footer: {
                Text("填写身高后自动计算 BMI；填写目标体重后显示减重进度")
            }
            if let error {
                Section { Text(error).foregroundColor(.red) }
            }
        }
        .navigationTitle("个人资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(isBusy)
            }
        }
        .onAppear {
            nickname = state.user?.nickname ?? ""
            heightText = state.user?.height_cm.map { String(format: "%.0f", $0) } ?? ""
            targetText = state.user?.target_kg.map { String(format: "%.1f", $0) } ?? ""
        }
    }

    private func save() {
        let height = Double(heightText)
        let target = Double(targetText)
        if !heightText.isEmpty && (height == nil || height! < 50 || height! > 260) {
            error = "身高需在 50~260cm 之间"
            return
        }
        if !targetText.isEmpty && (target == nil || target! < 10 || target! > 500) {
            error = "目标体重需在 10~500kg 之间"
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let u = try await APIClient.shared.updateMe(nickname: nickname,
                                                             heightCm: height,
                                                             targetKg: target)
                await MainActor.run {
                    state.user = u
                    dismiss()
                }
            } catch let err {
                await MainActor.run { error = err.localizedDescription }
            }
        }
    }
}

/// 服务器设置
struct ServerSettingsView: View {
    @State private var server = APIClient.shared.activeServer
    @State private var backup = AppConfig.defaultBackupServer
    @State private var saved = false

    var body: some View {
        Form {
            Section("主服务器") {
                TextField("地址", text: $server)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section {
                TextField("地址", text: $backup)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("备用服务器")
            } footer: {
                Text("主地址连不上时自动切换备用地址。修改后下次请求生效。")
            }
            if saved {
                Section { Label("已保存", systemImage: "checkmark.circle.fill").foregroundColor(.green) }
            }
        }
        .navigationTitle("服务器设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    let s = server.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { APIClient.shared.setServer(s) }
                    saved = true
                }
            }
        }
    }
}

/// Excel/CSV 导入
struct ImportView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var isPicking = false
    @State private var resultMsg = ""
    @State private var isBusy = false
    @State private var preview: [(date: String, kg: Double, note: String)] = []

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "tablecells")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                Text("支持 .xlsx / .csv 文件")
                    .font(.headline)
                Text("表格需包含「日期」和「体重」两列，日期格式 YYYY-MM-DD，体重单位 kg。\n\n示例表头：日期,体重,备注")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if !preview.isEmpty {
                    VStack(alignment: .leading) {
                        Text("识别到 \(preview.count) 条记录，前 3 条预览：")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(preview.prefix(3), id: \.date) { p in
                            Text("\(p.date)  \(String(format: "%.1f", p.kg)) kg")
                                .font(.caption)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                }

                if !resultMsg.isEmpty {
                    Text(resultMsg)
                        .font(.footnote)
                        .foregroundColor(resultMsg.contains("失败") || resultMsg.contains("错误") ? .red : .green)
                        .multilineTextAlignment(.center)
                }

                Button { isPicking = true } label: {
                    if isBusy {
                        ProgressView()
                    } else {
                        Label("选择文件", systemImage: "doc.badge.plus")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
            .padding()
            .navigationTitle("导入体重")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data, .commaSeparatedText, .plainText]) { result in
                handlePick(result)
            }
        }
    }

    private func handlePick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            parseFile(url)
        case .failure(let e):
            resultMsg = "选择文件失败：\(e.localizedDescription)"
        }
    }

    private func parseFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        do {
            let items: [(date: String, kg: Double, note: String)]
            if ext == "csv" || ext == "txt" {
                items = try parseCSV(url)
            } else {
                items = try parseXLSX(url)
            }
            if items.isEmpty {
                resultMsg = "未识别到有效数据，请检查表头是否有「日期」和「体重」列"
                return
            }
            preview = items
            importItems(items)
        } catch {
            resultMsg = "解析失败：\(error.localizedDescription)"
        }
    }

    private func parseCSV(_ url: URL) throws -> [(date: String, kg: Double, note: String)] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parseCSVString(text)
    }

    private func parseXLSX(_ url: URL) throws -> [(date: String, kg: Double, note: String)] {
        let data = try Data(contentsOf: url)
        // xlsx 是 zip（PK 头）；不是 zip 则按 CSV/纯文本兜底
        if data.starts(with: [0x50, 0x4B]) {
            let rows = try XLSXParser.parseWeights(url)
            return rows.map { ($0.date, $0.kg, $0.note) }
        } else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return try parseCSVString(text)
        }
    }

    private func parseCSVString(_ text: String) throws -> [(date: String, kg: Double, note: String)] {
        let lines = text.components(separatedBy: .newlines)
        guard let header = lines.first else { return [] }
        let cols = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let dateIdx = cols.firstIndex(where: { $0.contains("日期") || $0.lowercased() == "date" }),
              let kgIdx = cols.firstIndex(where: { $0.contains("体重") || $0.lowercased() == "weight" || $0.lowercased() == "kg" }) else {
            return []
        }
        // 单位：表头含「斤」则 ÷2 转 kg
        let factor = cols[kgIdx].contains("斤") ? 0.5 : 1.0
        let noteIdx = cols.firstIndex(where: { $0.contains("备注") || $0.lowercased() == "note" || $0.contains("说明") })
        var out: [(date: String, kg: Double, note: String)] = []
        for line in lines.dropFirst() {
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count > max(dateIdx, kgIdx) else { continue }
            guard let date = normalizeDate(parts[dateIdx]), let raw = Double(parts[kgIdx]), raw > 0 else { continue }
            let kg = raw * factor
            var note = ""
            if let ni = noteIdx, ni < parts.count {
                note = String(parts[ni])
            }
            out.append((date, kg, note))
        }
        return out
    }

    private func normalizeDate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        // 处理 Excel 日期数字（1900 系统，序列号）
        if let serial = Double(t), serial > 20000, serial < 60000 {
            let base = Date(timeIntervalSince1970: 0)
            let days = serial - 25569 // 1970-01-01 对应的 Excel 序列号
            let d = base.addingTimeInterval(days * 86400)
            return WeightRecord.dateFormatter.string(from: d)
        }
        // YYYY-MM-DD 或 YYYY/M/D
        let parts = t.components(separatedBy: CharacterSet(charactersIn: "-/"))
        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        return nil
    }

    private func importItems(_ items: [(date: String, kg: Double, note: String)]) {
        isBusy = true
        let body = items.map { APIClient.ImportItem(date: $0.date, kg: $0.kg, note: $0.note) }
        Task {
            defer { isBusy = false }
            do {
                let n = try await APIClient.shared.importWeights(body)
                await state.refreshWeights()
                await MainActor.run { resultMsg = "成功导入 \(n) 条记录" }
            } catch {
                await MainActor.run { resultMsg = "导入失败：\(error.localizedDescription)" }
            }
        }
    }
}
