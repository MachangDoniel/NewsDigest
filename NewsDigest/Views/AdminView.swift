import Charts
import SwiftUI

/// Settings → Admin. Only shown to accounts in the server's `admins` table.
struct AdminView: View {
    @EnvironmentObject private var store: DigestStore

    @State private var overview: AdminOverview?
    @State private var error: String?
    @State private var live = false
    @State private var confirmReset = false
    @State private var exportFile: URL?
    @State private var pingResult: String?
    @State private var usageTab = UsageTab.traffic

    @State private var paper: Paper?
    @State private var pastDay = false
    @State private var day = Calendar.dhaka.startOfDay(for: .now)
    @State private var force = false
    @State private var starting = false
    @State private var runMessage: String?

    enum UsageTab: String, CaseIterable, Identifiable {
        case traffic = "Traffic", users = "Who", actions = "Actions", log = "Log"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if let overview {
                cardsSection(overview)
            }
            runSection
            if let overview {
                daysSection(overview.runs)
                if !overview.workflow.isEmpty { workflowSection(overview.workflow) }
                databaseSection(overview)
                usageSection(overview.usage)
                usersSection(overview.users)
            } else if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Toggle(isOn: $live) { Label("Live (every 10 seconds)", systemImage: "dot.radiowaves.left.and.right") }
                    if let exportFile {
                        ShareLink(item: exportFile) { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                    Button(role: .destructive) { confirmReset = true } label: { Label("Reset usage", systemImage: "trash") }
                } label: {
                    Image(systemName: live ? "dot.radiowaves.left.and.right" : "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete the whole usage log?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset usage", role: .destructive) { Task { await resetUsage() } }
        } message: {
            Text("Request counts, the activity log and the traffic chart start again from zero. Digests are not touched.")
        }
        .refreshable { await load() }
        .task { await load() }
        .task(id: live) {
            while live, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { await load() }
            }
        }
    }

    private func load() async {
        do {
            let fresh = try await store.adminOverview()
            overview = fresh
            error = nil
            exportFile = Self.writeExport(fresh)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resetUsage() async {
        do {
            try await store.adminResetUsage()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The overview as a JSON file, for the Export menu item.
    private static func writeExport(_ overview: AdminOverview) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(overview) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("newsdigest-admin-\(DigestDate.string(.now)).json")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    // MARK: - Summary cards

    private func cardsSection(_ o: AdminOverview) -> some View {
        let ai = ["summarize", "chat", "speak", "digest"].reduce(0) { $0 + (o.usage.today[$1] ?? 0) }
        let requests = o.usage.today.filter { $0.key != "digest" }.values.reduce(0, +)
        return Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                card("Database", value: megabytes(o.storage.dbBytes), detail: "of \(megabytes(o.storage.dbLimitBytes)) free plan",
                     used: fraction(o.storage.dbBytes, o.storage.dbLimitBytes))
                card("Saved audio", value: megabytes(o.storage.audioBytes), detail: "\(o.storage.audioFiles ?? 0) files · of \(megabytes(o.storage.audioLimitBytes))",
                     used: fraction(o.storage.audioBytes, o.storage.audioLimitBytes))
                card("AI calls today", value: "\(ai)", detail: "\(o.usage.today["digest"] ?? 0) by the server digest")
                card("App requests today", value: "\(requests)", detail: "\(o.usage.usersToday) user\(o.usage.usersToday == 1 ? "" : "s") · \(o.usage.failedToday) failed")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func card(_ title: String, value: String, detail: String, used: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            if let used {
                ProgressView(value: used).tint(used > 0.8 ? .orange : .accentColor)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func megabytes(_ bytes: Int?) -> String {
        guard let bytes else { return "–" }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb)
    }

    private func fraction(_ bytes: Int?, _ limit: Int) -> Double? {
        bytes.map { min(1, Double($0) / Double(max(limit, 1))) }
    }

    // MARK: - Run a digest

    private var runSection: some View {
        Section {
            Picker("Paper", selection: $paper) {
                Text("Both").tag(Paper?.none)
                ForEach(Paper.allCases) { Text($0.name).tag(Paper?.some($0)) }
            }
            Toggle("A past day", isOn: $pastDay)
            if pastDay {
                DatePicker("Day", selection: $day, in: ...Date.now, displayedComponents: .date)
                    .environment(\.timeZone, .dhaka)
            }
            Toggle("Rebuild if it already exists", isOn: $force)
            Button {
                Task { await startRun() }
            } label: {
                Text(starting ? "Starting…" : "Run digest")
            }
            .disabled(starting)
            if let runMessage {
                Text(runMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Run a digest")
        } footer: {
            Text("Starts the Daily digest workflow on GitHub. A run takes 5–30 minutes; pull down to refresh.")
        }
    }

    private func startRun() async {
        starting = true
        defer { starting = false }
        do {
            let res = try await store.runDigestNow(paper: paper, date: pastDay ? DigestDate.string(day) : nil, force: force)
            runMessage = res.message
        } catch {
            runMessage = error.localizedDescription
        }
    }

    // MARK: - Status

    private func daysSection(_ runs: [AdminOverview.Run]) -> some View {
        Section {
            ForEach(runs) { run in
                Button {
                    // Set the form above up to retry this one.
                    paper = run.paper
                    day = DigestDate.date(run.date)
                    pastDay = !Calendar.dhaka.isDateInToday(day)
                    force = run.state == "ok"
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(run.state))
                            .foregroundStyle(color(run.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(DigestDate.pretty(run.date)) · \(run.paper.name)").font(.subheadline)
                            Text(run.summary).font(.caption).foregroundStyle(.secondary)
                            if let message = run.message, run.state == "error" {
                                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Last 10 days")
        } footer: {
            Text("Tap a row to fill in Run a digest for that paper and day.")
        }
    }

    private func workflowSection(_ runs: [AdminOverview.WorkflowRun]) -> some View {
        Section("Recent runs on GitHub") {
            ForEach(runs) { run in
                HStack {
                    Image(systemName: icon(run.result)).foregroundStyle(color(run.result))
                    Text(run.result.replacingOccurrences(of: "_", with: " ").capitalized)
                    Spacer()
                    Text((run.event == "schedule" ? "Hourly" : "Manual") + " · " + ago(run.at))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    private func databaseSection(_ o: AdminOverview) -> some View {
        let db = o.database
        return Section("Database") {
            Label(db.ok ? "Connected" : (db.message ?? "Not responding"), systemImage: db.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(db.ok ? .green : .red)
            LabeledContent("Project", value: URL(string: store.supabaseURL)?.host ?? "")
            HStack {
                Button("Ping test") { Task { await ping() } }
                Spacer()
                Text(pingResult ?? "\(db.pingMs) ms").foregroundStyle(.secondary)
            }
            LabeledContent("Digests saved", value: "\(db.digests)")
            if let first = db.firstDate, let latest = db.latestDate {
                LabeledContent("Days covered", value: "\(first) to \(latest)")
            }
            if let status = o.storage.statusRows, let usage = o.storage.usageRows {
                LabeledContent("Other rows", value: "\(status) status · \(usage) usage")
            }
        }
    }

    private func ping() async {
        pingResult = "Testing…"
        let ms = try? await store.adminPing()
        pingResult = ms.flatMap { $0 }.map { "\($0) ms" } ?? "No answer"
    }

    // MARK: - Usage

    private static let actions: [(id: String, label: String)] = [
        ("whoami", "App opened"),
        ("summarize", "✨ Summarize"),
        ("chat", "Ask"),
        ("speak", "Read aloud"),
        ("run_digest", "Run digest"),
        ("digest", "Server digest page"),
    ]

    private func label(_ action: String) -> String {
        Self.actions.first { $0.id == action }?.label ?? action
    }

    private func usageSection(_ usage: AdminOverview.Usage) -> some View {
        Section {
            Picker("Show", selection: $usageTab) {
                ForEach(UsageTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch usageTab {
            case .traffic:
                Chart(usage.hourly) { hour in
                    BarMark(x: .value("Hour", date(hour.at) ?? .now, unit: .hour), y: .value("Requests", hour.app))
                        .foregroundStyle(by: .value("From", "App"))
                    BarMark(x: .value("Hour", date(hour.at) ?? .now, unit: .hour), y: .value("Requests", hour.server))
                        .foregroundStyle(by: .value("From", "Server digest"))
                }
                .chartForegroundStyleScale(["App": Color.accentColor, "Server digest": Color.green])
                .environment(\.timeZone, .dhaka)
                .frame(height: 160)
                .padding(.vertical, 6)
                ForEach(Self.actions, id: \.id) { action in
                    LabeledContent(action.label, value: "\(usage.today[action.id] ?? 0) today · \(usage.week[action.id] ?? 0) this week")
                }
            case .users:
                if usage.byUser.isEmpty { Text("Nobody yet.").foregroundStyle(.secondary) }
                ForEach(usage.byUser) { user in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.email == "server" ? "Server digest" : user.email).font(.subheadline)
                        Text("\(user.count) requests · \(user.device ?? "unknown device") · last \(ago(user.last))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .actions:
                if usage.byAction.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(usage.byAction) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(label(action.action)).font(.subheadline)
                            Spacer()
                            Text("\(action.count)").monospacedDigit()
                        }
                        Text("\(action.avgMs.map { "average \(duration($0))" } ?? "not timed") · \(action.failed) failed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .log:
                if usage.recent.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(Array(usage.recent.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(event.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(event.action)).font(.subheadline)
                            Text([event.email == "server" ? "Server" : event.email, event.device, event.latencyMs.map(duration), ago(event.at)]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Last 7 days, counted from when this screen was added. Every number is measured; nothing is estimated. Google doesn't report how much AI quota is left, so only calls made are shown.")
        }
    }

    private func usersSection(_ users: [AdminOverview.User]) -> some View {
        Section {
            ForEach(users) { user in
                let requests = overview?.usage.byUser.first { $0.email == user.email }?.count ?? 0
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(user.email).font(.subheadline)
                        if user.admin {
                            Text("Admin").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    Text("\(requests) requests this week · last sign-in \(user.lastSignIn.map(ago) ?? "never")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Users")
        } footer: {
            Text("Add readers in Supabase → Authentication → Users. To make someone an admin, add their email to the admins table.")
        }
    }

    // MARK: - Helpers

    private func icon(_ state: String) -> String {
        switch state {
        case "ok", "success": "checkmark.circle.fill"
        case "queued", "in_progress": "clock.fill"
        case "not_published", "missing", "cancelled": "minus.circle"
        case "challenge": "hand.raised.fill"
        default: "xmark.octagon.fill"
        }
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "ok", "success": .green
        case "queued", "in_progress": .blue
        case "not_published", "missing", "cancelled": .secondary
        case "challenge": .orange
        default: .red
        }
    }

    /// A server timestamp (with or without fractional seconds).
    private func date(_ iso: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? plain.date(from: iso)
    }

    /// "2 hr ago" from a server timestamp.
    private func ago(_ iso: String) -> String {
        date(iso)?.formatted(.relative(presentation: .named)) ?? iso
    }

    private func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}
