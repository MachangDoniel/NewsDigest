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
    /// Daily AI allowance for the ring on the Gemini card. Google doesn't report one, so it starts
    /// at the free tier's usual 1,500 a day and the admin can change it.
    @AppStorage("adminAIDailyLimit") private var aiDailyLimit = 1500

    @State private var paper: Paper?
    @State private var pastDay = false
    @State private var day = Calendar.dhaka.startOfDay(for: .now)
    @State private var force = false
    @State private var starting = false
    @State private var runMessage: String?

    enum UsageTab: String, CaseIterable, Identifiable {
        case traffic = "Traffic Trend", users = "Who Is Accessing", actions = "Endpoint Heatmap", log = "Live Audit Log"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .traffic: "waveform.path.ecg"
            case .users: "person.2"
            case .actions: "square.stack.3d.up"
            case .log: "clock"
            }
        }
    }
    @State private var logFilter = ""

    var body: some View {
        List {
            if let overview {
                cardsSection(overview)
                usageSection(overview.usage)
            }
            runSection
            if let overview {
                historySection(overview.runs)
                daysSection(overview.runs)
                if !overview.workflow.isEmpty { workflowSection(overview.workflow) }
                databaseSection(overview)
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

    private static let aiActions = ["summarize", "chat", "speak", "digest"]

    private func cardsSection(_ o: AdminOverview) -> some View {
        let ai = Self.aiActions.reduce(0) { $0 + (o.usage.today[$1] ?? 0) }
        let requests = o.usage.today.filter { $0.key != "digest" }.values.reduce(0, +)
        let dbFree = o.storage.dbBytes.map { max(0, o.storage.dbLimitBytes - $0) }
        return Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                card("Supabase monthly quota", value: "\(max(0, o.usage.monthLimit - o.usage.monthCalls).formatted())", unit: "requests left this month",
                     detail: "Used \(o.usage.monthCalls.formatted()) of \(o.usage.monthLimit.formatted())",
                     used: Double(o.usage.monthCalls) / Double(max(o.usage.monthLimit, 1)), tint: .green)
                card("Gemini AI daily quota", value: aiDailyLimit > 0 ? "\(max(0, aiDailyLimit - ai).formatted())" : "\(ai)", unit: aiDailyLimit > 0 ? "AI calls left today" : "AI calls made today",
                     detail: aiDailyLimit > 0 ? "Used \(ai) of \(aiDailyLimit.formatted()) (limit set below)" : "Set a daily limit below to see what's left",
                     used: aiDailyLimit > 0 ? Double(ai) / Double(aiDailyLimit) : nil, tint: .purple)
                card("Database storage", value: megabytes(o.storage.dbBytes), unit: "",
                     detail: "\(megabytes(dbFree)) free of \(megabytes(o.storage.dbLimitBytes)) · \(o.database.digests) digests",
                     used: fraction(o.storage.dbBytes, o.storage.dbLimitBytes), tint: .blue)
                card("Saved audio", value: megabytes(o.storage.audioBytes), unit: "",
                     detail: "\(o.storage.audioFiles ?? 0) files · of \(megabytes(o.storage.audioLimitBytes))",
                     used: fraction(o.storage.audioBytes, o.storage.audioLimitBytes), tint: .orange)
                card("Server & traffic", value: "\(requests)", unit: "requests handled today",
                     detail: "\(o.usage.usersToday) client\(o.usage.usersToday == 1 ? "" : "s") · \(o.usage.failedToday) failed")
                card("Response time", value: o.usage.avgMsToday.map(duration) ?? "–", unit: "",
                     detail: "Average today · database ping \(o.database.pingMs) ms")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    /// A stat tile; with `used` (0…1) it also shows a ring of how much of a limit is used up.
    private func card(_ title: String, value: String, unit: String, detail: String, used: Double? = nil, tint: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.title3.weight(.bold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                if let used {
                    ring(used, tint: tint)
                }
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func ring(_ used: Double, tint: Color) -> some View {
        let used = min(1, max(0, used))
        // Under 1% would be invisible; keep a sliver so the ring reads as "started".
        let shown = used > 0 ? max(used, 0.02) : 0
        return ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 5)
            Circle().trim(from: 0, to: shown)
                .stroke(used > 0.8 ? Color.orange : tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(used < 0.01 && used > 0 ? "<1%" : "\(Int((used * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
        }
        .frame(width: 42, height: 42)
    }

    private func megabytes(_ bytes: Int?) -> String {
        guard let bytes else { return "–" }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb)
    }

    private func fraction(_ bytes: Int?, _ limit: Int) -> Double? {
        bytes.map { min(1, Double($0) / Double(max(limit, 1))) }
    }

    // MARK: - Digest history

    /// Pages built per paper for each of the last 10 days; a gap is a day that wasn't built.
    private func historySection(_ runs: [AdminOverview.Run]) -> some View {
        let built = runs.filter { $0.state == "ok" }.count
        return Section {
            Chart(runs) { run in
                BarMark(x: .value("Day", DigestDate.date(run.date), unit: .day), y: .value("Pages", run.pages ?? 0))
                    .foregroundStyle(by: .value("Paper", run.paper.name))
                    .position(by: .value("Paper", run.paper.name))
            }
            .chartForegroundStyleScale(domain: Paper.allCases.map(\.name), range: [Color.accentColor, Color.red.opacity(0.75)])
            .environment(\.timeZone, .dhaka)
            .frame(height: 150)
            .padding(.vertical, 6)
            HStack(spacing: 10) {
                tile("Built", "\(built) of \(runs.count)")
                tile("Missed", "\(runs.count - built)")
                tile("Pages", "\(runs.compactMap(\.pages).reduce(0, +))")
            }
        } header: {
            Text("Digests built, last 10 days")
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                ForEach(UsageTab.allCases) { tab in
                    let count: Int? = switch tab {
                    case .traffic: nil
                    case .users: usage.byUser.count
                    case .actions: usage.byAction.count
                    case .log: usage.recent.count
                    }
                    Button { usageTab = tab } label: {
                        Label(tab.rawValue + (count.map { " (\($0))" } ?? ""), systemImage: tab.icon)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(usageTab == tab ? Color.white : Color.primary)
                            .background(usageTab == tab ? Color.accentColor : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            switch usageTab {
            case .traffic: trafficTab(usage)
            case .users: usersTab(usage)
            case .actions: actionsTab(usage)
            case .log: logTab(usage)
            }
            HStack {
                Text("Gemini daily limit")
                Spacer()
                TextField("none", value: $aiDailyLimit, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
        } header: {
            Text("Live telemetry")
        } footer: {
            Text("Last 7 days, counted from when this screen was added. Every number is measured. Google doesn't report how much AI quota is left, so the Gemini ring uses the daily limit set here: 1,500 to start, change it to match your keys (0 hides the ring).")
        }
    }

    @ViewBuilder private func trafficTab(_ usage: AdminOverview.Usage) -> some View {
        let peak = usage.hourly.max { $0.app + $0.server + $0.web < $1.app + $1.server + $1.web }
        let total = usage.hourly.reduce(0) { $0 + $1.app + $1.server + $1.web }
        let ai = Self.aiActions.reduce(0) { $0 + (usage.today[$1] ?? 0) }
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 24 hours").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(usage.hourly) { hour in
                BarMark(x: .value("Hour", date(hour.at) ?? .now, unit: .hour), y: .value("Requests", hour.app))
                    .foregroundStyle(by: .value("From", "App"))
                BarMark(x: .value("Hour", date(hour.at) ?? .now, unit: .hour), y: .value("Requests", hour.web))
                    .foregroundStyle(by: .value("From", "Web"))
                BarMark(x: .value("Hour", date(hour.at) ?? .now, unit: .hour), y: .value("Requests", hour.server))
                    .foregroundStyle(by: .value("From", "Server digest"))
            }
            .chartForegroundStyleScale(["App": Color.accentColor, "Web": Color.orange, "Server digest": Color.green])
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .environment(\.timeZone, .dhaka)
            .frame(height: 160)
        }
        .padding(.vertical, 6)
        HStack(spacing: 10) {
            tile("Peak hour", peak.flatMap { p in p.app + p.server + p.web > 0 ? date(p.at).map { "\($0.formatted(.dateTime.hour())) (\(p.app + p.server + p.web))" } : nil } ?? "–")
            tile("Last 24 h", "\(total)")
            tile("AI today", "\(ai)")
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 7 days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(usage.daily) { day in
                BarMark(x: .value("Day", DigestDate.date(day.date), unit: .day), y: .value("Requests", day.app))
                    .foregroundStyle(by: .value("From", "App"))
                BarMark(x: .value("Day", DigestDate.date(day.date), unit: .day), y: .value("Requests", day.web))
                    .foregroundStyle(by: .value("From", "Web"))
                BarMark(x: .value("Day", DigestDate.date(day.date), unit: .day), y: .value("Requests", day.server))
                    .foregroundStyle(by: .value("From", "Server digest"))
                if day.failed > 0 {
                    PointMark(x: .value("Day", DigestDate.date(day.date), unit: .day), y: .value("Requests", day.failed))
                        .foregroundStyle(by: .value("From", "Failed"))
                }
            }
            .chartForegroundStyleScale(["App": Color.accentColor, "Web": Color.orange, "Server digest": Color.green, "Failed": Color.red])
            .environment(\.timeZone, .dhaka)
            .frame(height: 140)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func usersTab(_ usage: AdminOverview.Usage) -> some View {
        if usage.byUser.isEmpty {
            Text("Nobody yet.").foregroundStyle(.secondary)
        } else {
            Chart(usage.byUser) { user in
                BarMark(x: .value("Requests", user.count), y: .value("User", user.email == "web" ? (user.ip ?? "Web") : name(user.email)))
                    .foregroundStyle(user.email == "server" ? Color.green : user.email == "web" ? Color.orange : Color.accentColor)
                    .annotation(position: .trailing) { Text("\(user.count)").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(height: CGFloat(max(1, usage.byUser.count)) * 36 + 30)
            .padding(.vertical, 6)
        }
        let total = max(1, usage.byUser.reduce(0) { $0 + $1.count })
        ForEach(usage.byUser) { user in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text(user.ip ?? (user.email == "server" ? "GitHub runner" : "unknown address")).font(.subheadline.monospaced().weight(.semibold))
                    Spacer()
                    Text("\(user.count)").font(.subheadline.weight(.bold)).monospacedDigit()
                }
                Text(user.email == "server" ? "Server digest" : user.email == "web" ? "Web app visitor" : user.email).font(.caption)
                Label(user.device ?? "Unknown device", systemImage: user.device == "iPad" || user.device == "Tablet" ? "ipad" : user.device == "iPhone" || user.device == "Mobile" ? "iphone" : "laptopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
                if let agent = user.userAgent {
                    Text(agent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: Double(user.count) / Double(total))
                Text("\(Int((Double(user.count) / Double(total) * 100).rounded()))% of requests · last seen \(ago(user.last))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private func actionsTab(_ usage: AdminOverview.Usage) -> some View {
        if usage.byAction.isEmpty {
            Text("Nothing yet.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share of requests").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart(usage.byAction) { action in
                    SectorMark(angle: .value("Requests", action.count), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(by: .value("Action", label(action.action)))
                }
                .frame(height: 170)
            }
            .padding(.vertical, 6)
            let timed = usage.byAction.filter { $0.avgMs != nil }
            if !timed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Average response time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Chart(timed) { action in
                        BarMark(x: .value("Seconds", Double(action.avgMs ?? 0) / 1000), y: .value("Action", label(action.action)))
                            .annotation(position: .trailing) { Text(duration(action.avgMs ?? 0)).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .frame(height: CGFloat(timed.count) * 36 + 30)
                }
                .padding(.vertical, 6)
            }
        }
        ForEach(usage.byAction) { action in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        badge(method(action.action), .blue)
                        Text(path(action.action)).font(.subheadline.monospaced().weight(.semibold)).lineLimit(1)
                    }
                    Text("\(label(action.action)) · total requests: \(action.count) · \(action.failed) failed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let ms = action.avgMs { badge("\(duration(ms)) avg", ms > 2000 ? .red : .green) }
            }
        }
    }

    @ViewBuilder private func logTab(_ usage: AdminOverview.Usage) -> some View {
        let query = logFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let events = usage.recent.filter { event in
            query.isEmpty || [event.action, label(event.action), event.email ?? "", event.ip ?? "", event.status.map(String.init) ?? "", event.device ?? ""]
                .contains { $0.lowercased().contains(query) }
        }
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter action, user, IP, status…", text: $logFilter)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        if events.isEmpty { Text(usage.recent.isEmpty ? "Nothing yet." : "No matches.").foregroundStyle(.secondary) }
        ForEach(Array(events.enumerated()), id: \.offset) { _, event in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(date(event.at)?.formatted(date: .omitted, time: .standard) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    badge(method(event.action), .blue)
                    Text(path(event.action)).font(.subheadline.monospaced().weight(.semibold)).lineLimit(1)
                    Spacer()
                    badge(event.status.map(String.init) ?? (event.ok ? "OK" : "FAIL"), event.ok && (event.status ?? 200) < 400 ? .green : .red)
                }
                Text([event.latencyMs.map(duration), event.ip, event.email == "server" ? "Server digest" : event.email == "web" ? "Web app" : event.email, event.device]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Web visits are logged as "GET /api/digests"; the app's own requests are all POSTs to one function.
    private func method(_ action: String) -> String {
        action.contains(" ") ? String(action.split(separator: " ")[0]) : "POST"
    }

    private func path(_ action: String) -> String {
        action.contains(" ") ? action.split(separator: " ").dropFirst().joined(separator: " ") : action
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.monospaced().weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }

    /// Short name for a chart axis: the part of an email before the @.
    private func name(_ email: String) -> String {
        email == "server" ? "Server" : String(email.split(separator: "@").first ?? Substring(email))
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
