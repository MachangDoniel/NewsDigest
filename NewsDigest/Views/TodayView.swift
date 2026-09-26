import SwiftUI

/// "Today" tab. Starts on today and can step or swipe back through previous days.
struct TodayView: View {
    @EnvironmentObject private var store: DigestStore
    @State private var date = Calendar.dhaka.startOfDay(for: .now)
    @State private var showCalendar = false

    private var isToday: Bool { Calendar.dhaka.isDateInToday(date) }

    var body: some View {
        NavigationStack {
            Group {
                if store.authState == .signedIn {
                    DayDigestView(date: DigestDate.string(date))
                        .id(DigestDate.string(date))
                        .transition(.opacity)
                        .gesture(
                            DragGesture(minimumDistance: 40).onEnded { v in
                                guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                                step(v.translation.width < 0 ? 1 : -1)
                            }
                        )
                } else {
                    ConnectPrompt()
                }
            }
            .navigationTitle(DigestDate.pretty(DigestDate.string(date)))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if store.authState == .signedIn {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    Button { showCalendar = true } label: { Image(systemName: "calendar") }
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(isToday)
                }
                if !isToday {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") { withAnimation { date = Calendar.dhaka.startOfDay(for: .now) } }
                    }
                }
                }
            }
            .sheet(isPresented: $showCalendar) {
                NavigationStack {
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.timeZone, .dhaka)
                        .padding()
                        .navigationTitle("Jump to date")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { showCalendar = false } }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func step(_ days: Int) {
        guard let next = Calendar.dhaka.date(byAdding: .day, value: days, to: date), next <= .now else { return }
        withAnimation(.easeInOut(duration: 0.2)) { date = next }
    }
}

struct ConnectPrompt: View {
    @EnvironmentObject private var store: DigestStore

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 40)
                VStack(spacing: 6) {
                    Text("Sign in to see your digests").font(.title2.weight(.bold))
                    Text("Use the NewsDigest account from your Supabase project. The Papers tab works without it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if store.authState == .unconfigured {
                    Text("No digest project is set. Add one in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else {
                    SignInForm()
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
