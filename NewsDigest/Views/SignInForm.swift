import SwiftUI

/// Email + password sign-in for the digest account. Used on Today/Archive and in Settings.
struct SignInForm: View {
    @EnvironmentObject private var store: DigestStore
    @State private var email = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit { Task { await signIn() } }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            Button {
                Task { await signIn() }
            } label: {
                Group {
                    if signingIn { ProgressView().tint(.white) } else { Text("Sign in").fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty || password.isEmpty || signingIn)
            .opacity(email.isEmpty || password.isEmpty ? 0.6 : 1)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }

    private func signIn() async {
        guard !email.isEmpty, !password.isEmpty else { return }
        signingIn = true
        error = nil
        defer { signingIn = false }
        do {
            try await store.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            password = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
