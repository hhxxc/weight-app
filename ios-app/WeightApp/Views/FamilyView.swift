import SwiftUI

/// 家庭管理（仅管理员可见）：查看成员、给家人建号、重置密码
struct FamilyView: View {
    @EnvironmentObject var state: AppState

    @State private var members: [APIClient.FamilyMember] = []
    @State private var progress: [APIClient.FamilyProgress] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showAdd = false
    @State private var resetTarget: APIClient.FamilyMember?

    var body: some View {
        Group {
            if loading {
                ProgressView("读取成员…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("重试") {
                        loading = true
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !progress.isEmpty {
                        Section {
                            ForEach(progress) { p in
                                progressRow(p)
                            }
                        } header: {
                            Text("本周进度")
                        } footer: {
                            Text("变更是「本周均值」相对上一周的变化；绿色是下降，橙色是上升。")
                        }
                    }

                    Section {
                        ForEach(members) { m in
                            Button {
                                resetTarget = m
                            } label: {
                                row(m)
                            }
                            .foregroundColor(.primary)
                        }
                    } footer: {
                        Text("每个成员的体重、饮食数据完全独立。点某个成员可重置密码；新成员建好后用他自己的手机登录即可。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("家庭管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Haptics.tap()
                    showAdd = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddMemberView { Task { await load() } }
        }
        .sheet(item: $resetTarget) { m in
            ResetPasswordView(member: m) { Task { await load() } }
        }
        .task { await load() }
    }

    private func progressRow(_ p: APIClient.FamilyProgress) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 34, height: 34)
                Text(initial(name: p.nickname, username: p.username))
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(p.nickname.isEmpty ? p.username : p.nickname)
                    .font(.subheadline.bold())
                Text("体重 \(p.weight_days) 天 · 饮食 \(p.meal_days) 天")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(p.latest_kg.map { String(format: "%.1f kg", $0) } ?? "—")
                    .font(.subheadline)
                    .monospacedDigit()
                Text(deltaText(p.delta_kg))
                    .font(.caption2.bold())
                    .foregroundColor(deltaColor(p.delta_kg))
            }
        }
        .padding(.vertical, 3)
    }

    private func deltaText(_ d: Double?) -> String {
        guard let d = d else { return "暂无对比" }
        if abs(d) < 0.05 { return "基本持平" }
        return String(format: "%+.1f kg", d)
    }

    /// 体重下降算好事：绿；上升提示：橙
    private func deltaColor(_ d: Double?) -> Color {
        guard let d = d, abs(d) >= 0.05 else { return .secondary }
        return d < 0 ? Theme.success : Theme.warning
    }

    private func initial(name: String, username: String) -> String {
        let text = name.isEmpty ? username : name
        return String(text.prefix(1))
    }

    private func row(_ m: APIClient.FamilyMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 40, height: 40)
                Text(initial(m))
                    .font(.headline)
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(m.nickname.isEmpty ? m.username : m.nickname)
                        .font(.subheadline.bold())
                    if m.is_admin == 1 {
                        Text("管理员")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.brandDeep)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.brandBlue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text("@\(m.username) · 体重 \(m.weight_count) 条 · 饮食 \(m.meal_count) 条")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "key.fill")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func initial(_ m: APIClient.FamilyMember) -> String {
        let name = m.nickname.isEmpty ? m.username : m.nickname
        return String(name.prefix(1))
    }

    private func load() async {
        do {
            let list = try await APIClient.shared.fetchFamilyMembers()
            let prog = (try? await APIClient.shared.fetchFamilyProgress()) ?? []
            await MainActor.run {
                members = list
                progress = prog
                loading = false
                error = nil
            }
        } catch let err {
            await MainActor.run {
                loading = false
                error = err.localizedDescription
            }
        }
    }
}

/// 新建家庭成员
struct AddMemberView: View {
    @Environment(\.dismiss) private var dismiss

    var onSaved: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("用户名（登录用）", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("昵称（可选）", text: $nickname)
                    TextField("初始密码（至少 4 位）", text: $password)
                } footer: {
                    Text("账号创建后，让家人用这个用户名和密码登录；数据与你的完全独立。")
                }
                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
            }
            .navigationTitle("新增成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建", action: save)
                        .disabled(busy || username.trimmingCharacters(in: .whitespaces).count < 2 || password.count < 4)
                }
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        let name = username.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await APIClient.shared.createFamilyMember(username: name, password: password, nickname: nickname)
                await MainActor.run {
                    busy = false
                    Haptics.success()
                    onSaved()
                    dismiss()
                }
            } catch let err {
                await MainActor.run {
                    busy = false
                    Haptics.error()
                    error = err.localizedDescription
                }
            }
        }
    }
}

/// 重置某个成员的密码
struct ResetPasswordView: View {
    @Environment(\.dismiss) private var dismiss

    let member: APIClient.FamilyMember
    var onSaved: () -> Void

    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("账号")
                        Spacer()
                        Text(member.username).foregroundColor(.secondary)
                    }
                    TextField("新密码（至少 4 位）", text: $password)
                } footer: {
                    Text("改完后需要告诉他新密码；已登录的设备不会被强制退出。")
                }
                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
            }
            .navigationTitle("重置密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(busy || password.count < 4)
                }
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                try await APIClient.shared.resetPassword(userId: member.id, password: password)
                await MainActor.run {
                    busy = false
                    Haptics.success()
                    onSaved()
                    dismiss()
                }
            } catch let err {
                await MainActor.run {
                    busy = false
                    Haptics.error()
                    error = err.localizedDescription
                }
            }
        }
    }
}
