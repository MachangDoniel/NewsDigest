import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: DigestStore

    @State private var url = ""
    @State private var anonKey = ""

    @AppStorage(AI.modelKey) private var model = "auto"
    @AppStorage(AI.languageKey) private var language = "auto"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch store.authState {
                    case .signedIn:
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        LabeledContent("Project", value: URL(string: store.supabaseURL)?.host ?? "")
                        Button("Sign out", role: .destructive) { Task { await store.signOut() } }
                    case .signedOut:
                        SignInForm()
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    case .unconfigured:
                        Text("No digest project set.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Daily digest account")
                } footer: {
                    Text("Sign in with the user from your Supabase project (Authentication → Users). Not your newspaper login.")
                }

                if store.authState != .signedIn {
                    Section {
                        DisclosureGroup("Use a different Supabase project") {
                            TextField("Project URL (https://xxxx.supabase.co)", text: $url)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            SecureField("Publishable (anon) key", text: $anonKey)
                            Button("Connect") { store.configure(url: url, anonKey: anonKey) }
                                .disabled(!url.hasPrefix("https://") || anonKey.isEmpty)
                            if store.usesCustomProject {
                                Button("Use the built-in project") { store.useDefaultProject() }
                            }
                        }
                    } footer: {
                        Text("Only needed if you run your own copy of the server. Supabase → Project Settings → API Keys.")
                    }
                }

                Section {
                    Picker("AI model", selection: $model) {
                        ForEach(AI.models, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Picker("Summary language", selection: $language) {
                        Text("Same as paper").tag("auto")
                        Text("English").tag("en")
                        Text("বাংলা").tag("bn")
                        Text("Both").tag("both")
                    }
                } header: {
                    Text("✨ Summarize")
                } footer: {
                    Text("Uses the Gemini and Groq keys stored in your Supabase project, so no key is needed on this phone. If every key is busy or out of quota, you get the paper's own text for the page instead. If the model you pick is busy, the next one is tried automatically.")
                }

                Section("When a digest fails") {
                    Label("Login expired: check the paper's EMAIL / PASSWORD secrets on GitHub (Settings → Secrets → Actions).", systemImage: "key")
                    Label("Re-run anytime: GitHub → Actions → Daily digest → Run workflow.", systemImage: "arrow.clockwise")
                }
                .font(.footnote)
            }
            .navigationTitle("Settings")
            .onAppear {
                url = store.usesCustomProject ? store.supabaseURL : ""
            }
        }
    }
}
