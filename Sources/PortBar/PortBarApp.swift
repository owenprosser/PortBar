import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// MARK: - App

@main
struct PortBarApp: App {
    @StateObject private var monitor = ServerMonitor()
    @StateObject private var launchAtLogin = LaunchAtLogin()

    var body: some Scene {
        MenuBarExtra {
            ServerListView(monitor: monitor, launchAtLogin: launchAtLogin)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Settings

enum DefaultsKey {
    static let showAll = "showAll"
    static let devPrefixes = "devPrefixes"
    static let notify = "notifyOnChange"
    static let showCount = "showCountInMenuBar"
}

/// The menu bar item: the server-rack icon, with the running-server count beside it when enabled.
struct MenuBarLabel: View {
    @ObservedObject var monitor: ServerMonitor
    @AppStorage(DefaultsKey.showCount) private var showCount = false

    var body: some View {
        if showCount {
            Text("\(Image(systemName: "server.rack")) \(monitor.servers.count)")
        } else {
            Image(systemName: "server.rack")
        }
    }
}

/// Process-name prefixes treated as dev servers. Stored as a JSON string so `@AppStorage` can hold it.
struct PrefixList: RawRepresentable, Equatable, Sendable {
    var items: [String]

    init(_ items: [String]) { self.items = items }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        self.items = items
    }

    var rawValue: String {
        (try? JSONEncoder().encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static let defaults = PrefixList([
        "node", "python", "ruby", "java", "php", "deno", "bun", "go",
        "beam", "postgres", "redis", "mysqld", "mongod", "com.docker", "vite", "esbuild",
    ])
}

/// Everything a scan depends on, read from UserDefaults so the views' `@AppStorage` and the
/// monitor stay in agreement without sharing an object.
struct ScanConfig: Equatable, Sendable {
    var showAll: Bool
    var prefixes: [String]

    static func current() -> ScanConfig {
        let defaults = UserDefaults.standard
        let list = defaults.string(forKey: DefaultsKey.devPrefixes).flatMap(PrefixList.init(rawValue:)) ?? .defaults
        return ScanConfig(showAll: defaults.bool(forKey: DefaultsKey.showAll), prefixes: list.items)
    }
}

// MARK: - Model

struct DevServer: Identifiable, Hashable, Sendable {
    let pid: Int32
    let command: String
    let port: Int
    let project: String
    var id: String { "\(pid)-\(port)" }
}

/// Where a server is in the stop flow. Absent from the monitor's map means "running normally".
enum StopState: Equatable, Sendable {
    case stopping       // a signal was sent; waiting to see whether the process exits
    case unresponsive   // still alive after the grace period, so offer Force Quit
}

@MainActor
final class ServerMonitor: ObservableObject {
    @Published var servers: [DevServer] = []
    /// Servers we've sent a signal to and that are still running, keyed by `DevServer.id`.
    @Published private(set) var stopStates: [String: StopState] = [:]
    private var pollTask: Task<Void, Never>?
    private var isScanning = false
    private var rescanRequested = false
    private var appliedConfig = ScanConfig.current()
    private var defaultsObserver: NSObjectProtocol?
    /// The previous applied scan, by port, and the settings it was taken under. Used to tell what
    /// started or stopped between scans.
    private var lastByPort: [Int: DevServer]?
    private var lastScanConfig: ScanConfig?

    init() {
        refresh()
        // One cancellable loop instead of a Timer that hops back into a Task. It ends by itself
        // if the monitor goes away.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                refresh()
            }
        }
        // Re-scan right away when the show-all toggle or the process list changes. The
        // notification fires for every defaults write, so only react to ones that matter.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ScanConfig.current() != self.appliedConfig else { return }
                self.refresh()
            }
        }
    }

    /// Scan for servers. Scans never overlap, so results can't arrive out of order: a request made
    /// while one is running schedules exactly one more scan afterwards, with the latest settings.
    func refresh() {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        Task {   // inherits the main actor; the blocking work hops off it inside `scan`
            defer { isScanning = false }
            repeat {
                rescanRequested = false
                let config = ScanConfig.current()
                appliedConfig = config
                let result = await Self.scan(config: config)
                // If another scan is already queued, this result is stale: skip it.
                if !rescanRequested { apply(result, config: config) }
            } while rescanRequested
        }
    }

    private func apply(_ result: [DevServer], config: ScanConfig) {
        notifyOfChanges(to: result, config: config)   // before stopStates is pruned below
        servers = result
        let live = Set(result.map(\.id))
        stopStates = stopStates.filter { live.contains($0.key) }   // gone => done
    }

    // MARK: Notifications

    /// Posts a notification for servers that started or stopped since the last scan.
    private func notifyOfChanges(to result: [DevServer], config: ScanConfig) {
        // Keyed by port so a server restarting on the same port (nodemon, hot reload) isn't noise.
        let current = Dictionary(result.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })
        defer {
            lastByPort = current
            lastScanConfig = config
        }
        // The first scan, or one under different settings, only sets the baseline: changing what
        // we watch isn't a server starting or stopping.
        guard let previous = lastByPort, lastScanConfig == config,
              UserDefaults.standard.bool(forKey: DefaultsKey.notify) else { return }

        let started = current.filter { previous[$0.key] == nil }.map(\.value)
        // A server you stopped from PortBar yourself doesn't need announcing.
        let stopped = previous.filter { current[$0.key] == nil && stopStates[$0.value.id] == nil }.map(\.value)
        Notifier.shared.post(started, verb: "started")
        Notifier.shared.post(stopped, verb: "stopped")
    }

    /// Politely ask the process to exit (SIGTERM).
    func stop(_ server: DevServer) { send(SIGTERM, to: server) }

    /// Kill it outright (SIGKILL). Only offered after `stop` has failed to work.
    func forceStop(_ server: DevServer) { send(SIGKILL, to: server) }

    private func send(_ signal: Int32, to server: DevServer) {
        guard kill(server.pid, signal) == 0 else { return }   // e.g. EPERM: nothing to show
        stopStates[server.id] = .stopping
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
            // Still alive after a grace period? Offer Force Quit rather than reverting silently.
            try? await Task.sleep(for: .seconds(2.5))
            if stopStates[server.id] == .stopping { stopStates[server.id] = .unresponsive }
        }
    }

    func open(_ server: DevServer) {
        if let url = URL(string: "http://localhost:\(server.port)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Scanning

    nonisolated private static func isDev(_ command: String, prefixes: [String]) -> Bool {
        let c = command.lowercased()
        return prefixes.contains { c.hasPrefix($0.lowercased()) }
    }

    nonisolated private static func lsof(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A friendly project name for a process: the `name` from the nearest package.json at or above
    /// its working directory, else the working directory's folder name (e.g. "my-app").
    nonisolated private static func projectName(for pid: Int32) -> String {
        let out = lsof(["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("n") }) else { return "" }
        let path = String(line.dropFirst())
        guard path != "/" else { return "" }
        let cwd = URL(fileURLWithPath: path)
        return packageName(from: cwd) ?? cwd.lastPathComponent
    }

    /// Nearest package.json "name", walking up from `start` because dev servers are often launched
    /// from a subfolder (e.g. apps/web in a monorepo). Stops at the home directory so a stray
    /// ~/package.json is never picked up. Blank names and unreadable files are skipped.
    nonisolated private static func packageName(from start: URL) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = start.standardizedFileURL
        for _ in 0..<6 {
            if dir.path == home || dir.path == "/" { return nil }
            if let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    /// Runs `lsof` (blocking), so it is explicitly moved off the main actor.
    @concurrent
    static func scan(config: ScanConfig) async -> [DevServer] {
        // -F pcn gives machine-readable lines: p<pid>, c<command>, n<address:port>
        let out = lsof(["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        var pid: Int32 = 0
        var command = ""
        var seen = Set<String>()
        var projects: [Int32: String] = [:]
        var results: [DevServer] = []

        for line in out.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let portText = value.split(separator: ":").last,
                      let port = Int(portText),
                      config.showAll || isDev(command, prefixes: config.prefixes),
                      seen.insert("\(pid)-\(port)").inserted   // skips IPv4/IPv6 duplicates
                else { continue }
                let project = projects[pid] ?? projectName(for: pid)
                projects[pid] = project
                results.append(DevServer(pid: pid, command: command, port: port, project: project))
            default: break
            }
        }
        return results.sorted { $0.port < $1.port }
    }
}

// MARK: - Launch at login

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    init() { status = SMAppService.mainApp.status }

    /// On while registered, or registered-but-awaiting the user's approval in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// A one-line explanation shown under the toggle when something needs the user's attention.
    var footnote: String? {
        if let errorMessage { return errorMessage }
        if status == .requiresApproval { return "Approve PortBar in System Settings › General › Login Items." }
        return nil
    }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Couldn't change login item: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Notifications

/// A menu bar app is often the "active" app, and macOS hides banners for the active app unless
/// the delegate asks for them.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner] }
}

@MainActor
final class Notifier {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private let delegate = NotificationDelegate()

    private init() { center.delegate = delegate }

    /// Asks macOS for permission (it prompts only the first time). Returns whether we may post.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    /// Posts one notification per server, or a single summary when there are many.
    func post(_ servers: [DevServer], verb: String) {
        let servers = servers.sorted { $0.port < $1.port }
        guard !servers.isEmpty else { return }
        if servers.count <= 3 {
            for server in servers {
                let name = server.project.isEmpty ? server.command : server.project
                send(title: "Server \(verb)", body: ":\(server.port) · \(name)", id: "portbar.\(verb).\(server.port)")
            }
        } else {
            let ports = servers.map { ":\($0.port)" }.joined(separator: " ")
            send(title: "\(servers.count) servers \(verb)", body: ports, id: "portbar.\(verb).batch")
        }
    }

    private func send(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request)
    }
}

// MARK: - Views

private enum Metrics {
    static let panelWidth: CGFloat = 300
    /// Fixed so the list's total height is simply rows x this (a List has no intrinsic height).
    static let rowHeight: CGFloat = 40
}

struct ServerListView: View {
    @ObservedObject var monitor: ServerMonitor
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        ServerListContent(monitor: monitor, launchAtLogin: launchAtLogin)
            // Top-aligned so content doesn't drift while the panel animates between sizes.
            .frame(maxHeight: .infinity, alignment: .top)
            // MenuBarExtra's .window panel grows with its content but never shrinks back, so we
            // resize it ourselves whenever the row count changes.
            .background(PanelSizer(serverCount: monitor.servers.count,
                                   content: ServerListContent(monitor: monitor, launchAtLogin: launchAtLogin)))
    }
}

struct ServerListContent: View {
    @ObservedObject var monitor: ServerMonitor
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @AppStorage(DefaultsKey.showAll) private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if monitor.servers.isEmpty {
                Text("No dev servers running")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                // A real List so we get the system's swipe actions: on macOS 27 the capsule, its
                // stretch and icon snap, the haptic, and full-swipe all come from the OS.
                List {
                    ForEach(monitor.servers) { server in
                        let state = monitor.stopStates[server.id]
                        ServerRow(
                            server: server,
                            state: state,
                            onOpen: { monitor.open(server) },
                            onStop: { monitor.stop(server) },
                            onForceStop: { monitor.forceStop(server) }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if state == nil {
                                Button(role: .destructive) { monitor.stop(server) } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                }
                            } else if state == .unresponsive {
                                Button(role: .destructive) { monitor.forceStop(server) } label: {
                                    Label("Force Quit", systemImage: "xmark.octagon")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(monitor.servers.count) * Metrics.rowHeight)
            }

            Divider().padding(.vertical, 6)

            HStack(spacing: 12) {
                Toggle("Show all listening ports", isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { monitor.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                Button { SettingsWindow.shared.show(launchAtLogin: launchAtLogin) } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings…")
                .accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit PortBar")
                    .accessibilityLabel("Quit")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .frame(width: Metrics.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Resizes the hosting panel to fit `content`, keeping its top edge fixed under the menu bar.
///
/// The panel's own hosting view reports no usable size (fittingSize is 0 and SwiftUI pins
/// contentMinSize to the largest size it has been), so we measure a standalone NSHostingView of
/// the same content instead.
private struct PanelSizer<Content: View>: NSViewRepresentable {
    let serverCount: Int     // changes whenever rows appear/disappear, which re-triggers a fit
    let content: Content

    /// The height the user last saw. When growing, SwiftUI has already snapped the panel to the
    /// new size by the time we run, so we need this to rewind and animate forward from it.
    final class Coordinator { var lastHeight: CGFloat? }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    /// Something re-centres the panel under the icon after a resize, which reads as a sideways
    /// jump. Put it back.
    @MainActor private static func restoreX(of window: NSWindow, to x: CGFloat) {
        guard abs(window.frame.origin.x - x) > 0.5 else { return }
        window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
    }

    func updateNSView(_ view: NSView, context: Context) {
        let content = content
        let coordinator = context.coordinator
        // Defer a tick: the view may not be in a window yet, and layout is in flight.
        DispatchQueue.main.async { MainActor.assumeIsolated {
            guard let window = view.window else { return }
            let measured = NSHostingView(rootView: content).fittingSize.height
            guard measured > 0 else { return }

            let width = window.frame.width
            let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: measured)).height
            window.contentMinSize = .zero

            let topEdge = window.frame.maxY
            let originalX = window.frame.origin.x
            func frame(height: CGFloat) -> NSRect {
                NSRect(x: originalX, y: topEdge - height, width: width, height: height)
            }
            let previous = coordinator.lastHeight
            coordinator.lastHeight = target

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if window.isVisible, !reduceMotion, let previous, abs(previous - target) > 0.5 {
                // Growing: SwiftUI already snapped to `target`; rewind so there is something to animate.
                if abs(window.frame.height - target) < 0.5 {
                    window.setFrame(frame(height: previous), display: false)
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    window.animator().setFrame(frame(height: target), display: true)
                } completionHandler: {
                    MainActor.assumeIsolated { Self.restoreX(of: window, to: originalX) }
                }
            } else {
                guard abs(window.frame.height - target) > 0.5 else { return }
                window.setFrame(frame(height: target), display: true)
                Self.restoreX(of: window, to: originalX)
                Task { @MainActor in Self.restoreX(of: window, to: originalX) }
            }
        } }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @AppStorage(DefaultsKey.devPrefixes) private var prefixes = PrefixList.defaults
    @AppStorage(DefaultsKey.notify) private var notify = false
    @AppStorage(DefaultsKey.showCount) private var showCount = false
    @State private var notifyNote: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin.isOn },
                        set: { launchAtLogin.set($0) }
                    ))
                    Toggle("Show server count in menu bar", isOn: $showCount)
                    Toggle("Notify when a server starts or stops", isOn: Binding(
                        get: { notify },
                        set: { setNotify($0) }
                    ))
                } footer: {
                    if launchAtLogin.footnote != nil || notifyNote != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let note = launchAtLogin.footnote { Text(note) }
                            if let notifyNote { Text(notifyNote) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            .multilineTextAlignment(.leading)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            // Outside the Form so the control isn't boxed inside a second grouped card.
            VStack(alignment: .leading, spacing: 8) {
                Text("Dev server process names")
                    .font(.headline)
                    .padding(.leading, 10)
                ProcessListEditor(items: Binding(
                    get: { prefixes.items },
                    set: { prefixes.items = $0 }
                ))
                .frame(height: 194)
                Text("These process names will be categorised as dev servers")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setNotify(_ enabled: Bool) {
        notify = enabled
        notifyNote = nil
        guard enabled else { return }
        Task {
            // Prompts the first time; if macOS says no, don't leave the toggle claiming otherwise.
            if await !Notifier.shared.requestAuthorization() {
                notify = false
                notifyNote = "PortBar isn't allowed to send notifications. Allow it in System Settings › Notifications."
            }
        }
    }
}

// MARK: - Process list editor (AppKit)

/// The standard Mac "list with a + / − strip": an `NSTableView` over an `NSSegmentedControl` bar.
/// SwiftUI has no equivalent control, so this wraps the AppKit pieces. + adds a row in edit mode,
/// double-click renames, − or Delete removes.
private struct ProcessListEditor: NSViewRepresentable {
    @Binding var items: [String]

    func makeCoordinator() -> Coordinator { Coordinator(items: $items) }

    func makeNSView(context: Context) -> EditorView {
        let view = EditorView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: EditorView, context: Context) {
        context.coordinator.items = $items
        context.coordinator.refresh()
    }

    /// A flat fill that follows the appearance (`labelColor` at a low alpha reads as a light grey
    /// in light mode and a lighter grey in dark mode, like the stock list's rows and bar).
    final class Tint: NSView {
        private let alpha: CGFloat
        init(alpha: CGFloat) {
            self.alpha = alpha
            super.init(frame: .zero)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            }
        }
    }

    /// Container with the stock look: one rounded, borderless card, a lighter list area over a
    /// slightly darker button bar, a hairline between them.
    final class EditorView: NSView {
        let table = DeletableTable()
        let scroll = NSScrollView()
        let add = NSButton()
        let remove = NSButton()
        let more = NSButton()
        let listTint = Tint(alpha: 0.035)
        let barTint = Tint(alpha: 0.035)

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 10   // macOS 26 and earlier; macOS 27 takes it from the system below
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }
        required init?(coder: NSCoder) { fatalError() }

        // macOS 27+: ask the system for a radius concentric with the window's corners (never below 12pt),
        // so the card follows the current rounded style rather than a hard-coded value.
        @available(macOS 27, *)
        override var cornerConfiguration: NSViewCornerConfiguration? {
            .corners(radius: .containerConcentric(12))
        }

        @available(macOS 27, *)
        override func viewDidChangeEffectiveCornerRadii() {
            super.viewDidChangeEffectiveCornerRadii()
            if let radii = effectiveCornerRadii { layer?.cornerRadius = radii.topLeft }
        }
    }

    final class DeletableTable: NSTableView {
        var onDelete: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var items: Binding<[String]>
        private weak var view: EditorView?
        /// True while the blank row for a name being added is shown after the real rows.
        private var adding = false
        private var shown: [String] = []

        init(items: Binding<[String]>) { self.items = items }

        func attach(to view: EditorView) {
            self.view = view
            let table = view.table
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .fullWidth
            table.rowHeight = 24
            table.backgroundColor = .clear
            table.usesAlternatingRowBackgroundColors = false
            table.allowsEmptySelection = true
            table.dataSource = self
            table.delegate = self
            table.onDelete = { [weak self] in self?.removeSelected() }

            view.scroll.documentView = table
            view.scroll.hasVerticalScroller = true
            view.scroll.drawsBackground = false
            view.scroll.autohidesScrollers = true

            func style(_ button: NSButton, symbol: String, tip: String, action: Selector) {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.toolTip = tip
                button.target = self
                button.action = action
            }
            style(view.add, symbol: "plus", tip: "Add a process name", action: #selector(addClicked))
            style(view.remove, symbol: "minus", tip: "Remove the selected name", action: #selector(removeClicked))
            style(view.more, symbol: "ellipsis", tip: "More", action: #selector(moreClicked(_:)))

            let hairline = NSBox(); hairline.boxType = .separator
            let divider = NSBox(); divider.boxType = .separator

            for sub in [view.listTint, view.scroll, view.barTint, hairline, view.add, divider, view.remove, view.more] as [NSView] {
                sub.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(sub)
            }
            let barHeight: CGFloat = 24
            NSLayoutConstraint.activate([
                view.listTint.topAnchor.constraint(equalTo: view.topAnchor),
                view.listTint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                view.listTint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                view.listTint.bottomAnchor.constraint(equalTo: view.barTint.topAnchor),

                view.scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                view.scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                view.scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                view.scroll.bottomAnchor.constraint(equalTo: view.barTint.topAnchor),

                view.barTint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                view.barTint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                view.barTint.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                view.barTint.heightAnchor.constraint(equalToConstant: barHeight),

                hairline.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hairline.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hairline.bottomAnchor.constraint(equalTo: view.barTint.topAnchor),

                view.add.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                view.add.widthAnchor.constraint(equalToConstant: 26),
                view.add.heightAnchor.constraint(equalToConstant: barHeight),
                view.add.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                divider.leadingAnchor.constraint(equalTo: view.add.trailingAnchor),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.heightAnchor.constraint(equalToConstant: 14),
                divider.centerYAnchor.constraint(equalTo: view.add.centerYAnchor),
                view.remove.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
                view.remove.widthAnchor.constraint(equalToConstant: 26),
                view.remove.heightAnchor.constraint(equalToConstant: barHeight),
                view.remove.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                view.more.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                view.more.widthAnchor.constraint(equalToConstant: 26),
                view.more.heightAnchor.constraint(equalToConstant: barHeight),
                view.more.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            refresh()
        }

        /// Pulls the latest items from SwiftUI; leaves the table alone mid-edit.
        func refresh() {
            guard let view else { return }
            if !adding, shown != items.wrappedValue {
                shown = items.wrappedValue
                view.table.reloadData()
            }
            view.add.isEnabled = !adding
            view.remove.isEnabled = !adding && view.table.selectedRow >= 0
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count + (adding ? 1 : 0) }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let f = NSTextField()
                f.isEditable = true
                f.isBordered = false
                f.drawsBackground = false
                f.focusRingType = .none
                f.lineBreakMode = .byTruncatingTail
                f.font = .systemFont(ofSize: NSFont.systemFontSize)
                f.placeholderString = "process name"
                f.delegate = self
                f.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(f)
                cell.textField = f
                NSLayoutConstraint.activate([
                    f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                    f.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    f.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = row < shown.count ? shown[row] : ""
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) { refresh() }

        // MARK: Editing

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let table = view?.table else { return }
            let row = table.row(for: field)
            let name = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            var list = items.wrappedValue
            let isNew = adding && row == shown.count
            adding = false
            let clash = list.enumerated().contains { $0.element == name && $0.offset != row }
            if isNew {
                if !name.isEmpty, !clash { list.append(name) }
            } else if row >= 0, row < list.count, !name.isEmpty, !clash {
                list[row] = name
            }
            items.wrappedValue = list
            shown = list
            table.reloadData()
            if let i = list.firstIndex(of: name) { table.selectRowIndexes([i], byExtendingSelection: false) }
            refresh()
        }

        // MARK: Actions

        @objc func addClicked() { beginAdd() }
        @objc func removeClicked() { removeSelected() }

        @objc func moreClicked(_ sender: NSButton) {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "Reset to Defaults", action: #selector(resetClicked), keyEquivalent: "")
            item.target = self
            item.isEnabled = items.wrappedValue != PrefixList.defaults.items
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
        }

        private func beginAdd() {
            guard let table = view?.table, !adding else { return }
            adding = true
            table.reloadData()
            let row = shown.count
            table.scrollRowToVisible(row)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.editColumn(0, row: row, with: nil, select: true)
            refresh()
        }

        private func removeSelected() {
            guard let table = view?.table, !adding else { return }
            let row = table.selectedRow
            guard row >= 0, row < items.wrappedValue.count else { return }
            items.wrappedValue.remove(at: row)
            shown = items.wrappedValue
            table.reloadData()
            refresh()
        }

        @objc func resetClicked() {
            items.wrappedValue = PrefixList.defaults.items
            refresh()
        }
    }
}

/// A plain AppKit-managed window. SwiftUI's `Settings` scene is unreliable to open from a
/// menu-bar-only app (it tends to appear behind other windows), so we own the window ourselves.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(launchAtLogin: LaunchAtLogin) {
        launchAtLogin.refresh()   // the user may have changed it in System Settings
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(launchAtLogin: launchAtLogin)))
            window.title = "PortBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ServerRow: View {
    let server: DevServer
    let state: StopState?
    let onOpen: () -> Void
    let onStop: () -> Void
    let onForceStop: () -> Void

    /// Two-step Force Quit for mouse users: the first click arms the button, the second fires it.
    @State private var confirmingForce = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStopping: Bool { state == .stopping }

    var body: some View {
        HStack(spacing: 10) {
            Text(":\(server.port)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.project.isEmpty ? server.command : server.project)
                    .lineLimit(1)
                subtitle
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onOpen) { Image(systemName: "safari") }
                .help("Open in browser")
            if state == .unresponsive {
                forceQuitControl
            } else {
                Button(action: onStop) { Image(systemName: "stop.circle") }
                    .help("Stop server")
                    .accessibilityLabel("Stop")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .disabled(isStopping)
        // State change, not movement: a quick fade confirms the click landed. Kept under
        // Reduce Motion because nothing moves.
        .opacity(isStopping ? 0.5 : 1)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.15), value: isStopping)
        .task(id: confirmingForce) {
            // Don't leave a destructive button armed indefinitely.
            guard confirmingForce else { return }
            try? await Task.sleep(for: .seconds(4))
            confirmingForce = false
        }
    }

    /// Force Quit for a row that ignored SIGTERM. The swipe action does the same job for trackpad
    /// users; this is the click path, with a confirming second click instead of a dialog (alerts
    /// fight a menu bar panel for focus).
    private var forceQuitControl: some View {
        Group {
            if confirmingForce {
                Button {
                    confirmingForce = false
                    onForceStop()
                } label: {
                    Text("Force Quit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()   // never truncate or wrap the label
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.red))
                }
                .buttonStyle(.plain)
                .fixedSize()           // take the natural width…
                .layoutPriority(1)     // …and let the project name give way, not the capsule
                .help("Click to force quit (SIGKILL). This reverts in a few seconds.")
                .transition(swap)
            } else {
                Button { confirmingForce = true } label: { Image(systemName: "xmark.octagon") }
                    .foregroundStyle(.red)
                    .help("Didn't stop. Force quit…")
                    .accessibilityLabel("Force quit")
                    .transition(swap)
            }
        }
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.15), value: confirmingForce)
    }

    /// A fade, with a slight scale from the trailing edge unless Reduce Motion is on.
    private var swap: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .trailing))
    }

    @ViewBuilder private var subtitle: some View {
        if isStopping {
            Text("Stopping…").foregroundStyle(.secondary)
        } else if state == .unresponsive {
            Text("Didn't stop · PID \(server.pid)").foregroundStyle(.orange)
        } else {
            Text("\(server.command) · PID \(server.pid)").foregroundStyle(.secondary)
        }
    }
}
