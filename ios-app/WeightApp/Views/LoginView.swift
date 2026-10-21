import SwiftUI

/// 登录 / 注册视图
struct LoginView: View {
    @EnvironmentObject var state: AppState

    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var isRegister = false
    @State private var server = ""
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 图标 + 标题
                    VStack(spacing: 8) {
                        Image(systemName: "scalemass.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.accentColor)
                        Text("体重记录")
                            .font(.largeTitle.bold())
                        Text(isRegister ? "注册新账号" : "登录你的账号")
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 14) {
                        if isRegister {
                            TextField("昵称（可选）", text: $nickname)
                                .textFieldStyle(.roundedBorder)
                                .autocapitalization(.none)
                        }
                        TextField("用户名", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        SecureField("密码", text: $password)
                            .textFieldStyle(.roundedBorder)
                        TextField("服务器地址（留空用默认）", text: $server)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.footnote)
                    }
                    .padding(.horizontal, 24)

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    Button(action: submit) {
                        if isBusy {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        } else {
                            Text(isRegister ? "注册并登录" : "登录")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 24)
                    .disabled(isBusy || username.isEmpty || password.isEmpty)

                    Button(isRegister ? "已有账号？去登录" : "没有账号？去注册") {
                        withAnimation { isRegister.toggle(); error = nil }
                    }
                    .font(.footnote)
                }
            }
            .navigationBarHidden(true)
        }
    }

    private func submit() {
        guard !isBusy else { return }
        error = nil
        if !server.trimmingCharacters(in: .whitespaces).isEmpty {
            APIClient.shared.setServer(server.trimmingCharacters(in: .whitespaces))
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let resp: AuthResponse
                if isRegister {
                    resp = try await APIClient.shared.register(username: username.trimmingCharacters(in: .whitespaces),
                                                               password: password,
                                                               nickname: nickname.trimmingCharacters(in: .whitespaces))
                } else {
                    resp = try await APIClient.shared.login(username: username.trimmingCharacters(in: .whitespaces),
                                                            password: password)
                }
                await MainActor.run { state.handleAuth(resp) }
            } catch {
                await MainActor.run { error = error.localizedDescription }
            }
        }
    }
}
