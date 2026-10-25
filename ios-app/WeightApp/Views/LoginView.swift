import SwiftUI

/// 登录视图（注册入口已移除，账号由管理员分配）
struct LoginView: View {
    @EnvironmentObject var state: AppState

    @State private var username = UserDefaults.standard.string(forKey: "login.lastUsername") ?? ""
    @State private var password = ""
    @State private var server = ""
    @State private var isBusy = false
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // 极简头部
                    VStack(spacing: 12) {
                        Image(systemName: "scalemass")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(Theme.ink)
                            .frame(width: 64, height: 64)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Theme.fill)
                            )
                        Text("体重记录")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(Theme.ink)
                        Text("记录每一天，遇见更好的自己")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 64)
                    .padding(.bottom, 32)

                    // 登录表单
                    VStack(spacing: 16) {
                        TextField("用户名", text: $username)
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .username)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill)
                            )
                        SecureField("密码", text: $password)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .password)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill)
                            )
                        TextField("服务器地址（留空用默认）", text: $server)
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.inkSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill)
                            )

                        if let error {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                        }

                        Button(action: submit) {
                            if isBusy {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            } else {
                                Text("登录")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 15)
                            }
                        }
                        .background(Theme.brandGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(isBusy || username.isEmpty || password.isEmpty)
                        .opacity(isBusy || username.isEmpty || password.isEmpty ? 0.6 : 1)

                        Text("账号由管理员分配，如需使用请联系管理员")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.inkTertiary)
                            .padding(.top, 8)
                    }
                    .padding(24)
                }
            }
            .background(Color(UIColor.systemBackground))
            .navigationBarHidden(true)
            .onAppear {
                // 老用户：用户名已记住，直接把光标放到密码框
                if !username.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        focusedField = .password
                    }
                }
            }
        }
    }

    private func submit() {
        guard !isBusy else { return }
        error = nil
        if !server.trimmingCharacters(in: .whitespaces).isEmpty {
            APIClient.shared.setServer(server.trimmingCharacters(in: .whitespaces))
        }
        let name = username.trimmingCharacters(in: .whitespaces)
        isBusy = true
        Task {
            do {
                let resp = try await APIClient.shared.login(username: name, password: password)
                // 记住用户名，下次只需输密码
                UserDefaults.standard.set(name, forKey: "login.lastUsername")
                await MainActor.run {
                    isBusy = false
                    Haptics.success()
                    state.handleAuth(resp)
                }
            } catch let err {
                await MainActor.run {
                    isBusy = false
                    Haptics.error()
                    error = err.localizedDescription
                }
            }
        }
    }
}
