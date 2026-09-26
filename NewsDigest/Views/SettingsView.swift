import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DigestStore

    @State private var url = ""
    @State private var anonKey = ""
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var authError: String?

    @State private var geminiKey = ""
    @AppStorage(GeminiClient.modelDefaultsKey) private var model = GeminiClient.defaultModel
    @AppStorage(Prompts.languageKey) private var language = "en"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch store.authState {
                    case .signedIn:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        LabeledContent("Project", value: URL(string: store.supabaseURL)?.host ?? "")
                        Button("Sign out", role: .destructive) { Task { await store.signOut() } }
                    case .signedOut:
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $password).textContentType(.password)
                        Button {
                            Task { await signIn() }
                        } label: {
                            if signingIn { ProgressView() } else { Text("Sign in") }
                        }
                        .disabled(email.isEmpty || password.isEmpty || signingIn)
                        Button("Change project", role: .destructive) { store.configure(url: "", anonKey: "") }
                    case .unconfigured:
                        TextField("Project URL (https://xxxx.supabase.co)", text: $url)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Anon public key", text: $anonKey)
                        Button("Connect") { store.configure(url: url, anonKey: anonKey) }
                            .disabled(!url.hasPrefix("https://") || anonKey.isEmpty)
                    }
                    if let authError { Text(authError).font(.caption).foregroundStyle(.red) }
                } header: {
                    Text("Daily digest (Supabase)")
                } footer: {
                    Text("Supabase → Project Settings → API gives the URL and the anon key. Sign in with the user you created under Authentication → Users.")
                }

                Section {
                    SecureField("Gemini API key", text: $geminiKey)
                        .onSubmit { Keychain.set(geminiKey, for: GeminiClient.keyName) }
                    Button("Save key") { Keychain.set(geminiKey, for: GeminiClient.keyName) }
                        .disabled(geminiKey.isEmpty)
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Summary language", selection: $language) {
                        Text("English").tag("en")
                        Text("বাংলা").tag("bn")
                        Text("Both").tag("both")
                    }
                } header: {
                    Text("✨ Summarize on this phone")
                } footer: {
                    Text(GeminiClient.hasKey ? "Key saved in Keychain." : "Free key from aistudio.google.com. Used only for the Summarize button in the Papers tab.")
                }

                Section("When a digest fails") {
                    Label("Login expired: check the paper's EMAIL / PASSWORD secrets on GitHub (Settings → Secrets → Actions).", systemImage: "key")
                    Label("Re-run anytime: GitHub → Actions → Daily digest → Run workflow.", systemImage: "arrow.clockwise")
                }
                .font(.footnote)
            }
            .navigationTitle("Settings")
            .onAppear {
                url = store.supabaseURL
                geminiKey = Keychain.get(GeminiClient.keyName) ?? ""
            }
        }
    }

    private func signIn() async {
        signingIn = true
        authError = nil
        defer { signingIn = false }
        do {
            try await store.signIn(email: email, password: password)
            password = ""
        } catch {
            authError = error.localizedDescription
        }
    }
}
