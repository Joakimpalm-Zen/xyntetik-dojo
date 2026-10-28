import AppKit
import SwiftTerm
import XHSCore

/// The window's state: the panes, the bus and its HTTP server.
@MainActor
final class AppModel: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = AppModel()

    struct Item: Identifiable {
        let id: String
        let view: TerminalPane
    }

    @Published private(set) var items: [Item] = []
    /// Problems the owner should see (bus port taken, tools not installed).
    @Published private(set) var problem = ""
    /// Bumped on every bus change so headers redraw.
    @Published private(set) var revision = 0
    /// The plus button's picker is open.
    @Published var picking = false
    /// Hosts used for remote panes, latest first (~/.xhs/hosts).
    @Published private(set) var recentHosts: [String] = []

    let bus = Bus()
    let port: Int
    let smoke: Bool
    private let loginShell: String
    private var tokens: [String: String] = [:]
    private var remoteShells: [String: RemoteShell] = [:]
    private var server: BusServer?
    private var timer: Timer?
    private var keyMonitor: Any?

    override init() {
        let env = ProcessInfo.processInfo.environment
        port = Int(env["XHS_PORT"] ?? "") ?? Launcher.defaultPort
        smoke = env["XHS_SMOKE"] == "1"
        loginShell = AppModel.userShell()
        super.init()
        recentHosts = RecentHosts.load(AppModel.hostsFile)
        bus.onChange = { [weak self] in self?.revision &+= 1 }
        startServer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.bus.tick() }
        }
        // The bus holds relayed messages while the owner types in that pane.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let pane = event.window?.firstResponder as? TerminalPane {
                self?.bus.noteOwnerInput(pane.paneName)
            }
            return event
        }
        if !smoke, let trouble = ToolInstall.run() {
            problem = trouble
        }
    }

    // MARK: panes

    /// Adds a pane and starts its harness. Returns a message for the picker when the input is not usable.
    @discardableResult
    func addPane(kind: HarnessKind, host rawHost: String, name rawName: String) -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty, !Hosts.isValid(host) {
            return "Host is an ssh destination such as box or user@box."
        }
        var name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty {
            name = PaneNames.next(for: kind, taken: Set(bus.names))
        } else if !PaneNames.isValid(name) {
            return "A name uses a-z, 0-9, '-', '_' or '.', up to 24 characters."
        } else if bus.names.contains(name) {
            return "\(name) is already open."
        }
        let view = TerminalPane(name: name)
        view.processDelegate = self
        let token = bus.add(name: name, kind: kind, host: host, io: view)
        tokens[name] = token
        if !host.isEmpty { recentHosts = RecentHosts.remember(host, in: AppModel.hostsFile) }
        items.append(Item(id: name, view: view))
        Task { await launch(view, kind: kind, host: host, token: token) }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return nil
    }

    private func launch(_ view: TerminalPane, kind: HarnessKind, host: String, token: String) async {
        var model: String?
        if kind == .pi, host.isEmpty {
            model = await Launcher.fetchRunnerModel()
            guard let model else {
                bus.setModel(view.paneName, "Runner offline")
                start(view, Launcher.runnerOfflinePlan())
                return
            }
            bus.setModel(view.paneName, model)
        }
        // A remote host is asked which shell it runs commands in: cmd.exe (Windows) or a POSIX shell.
        var remoteShell = RemoteShell.posix
        if !host.isEmpty {
            remoteShell = await Launcher.probeRemoteShell(host: host)
            remoteShells[view.paneName] = remoteShell
        }
        guard items.contains(where: { $0.id == view.paneName }) else { return }
        start(view, Launcher.plan(kind: kind, paneName: view.paneName, host: host.isEmpty ? nil : host, port: port,
                                  token: token, runnerModel: model, loginShell: loginShell, remoteShell: remoteShell))
    }

    private func start(_ view: TerminalPane, _ plan: LaunchPlan) {
        let env = Launcher.paneEnvironment(from: ProcessInfo.processInfo.environment, adding: plan.environment)
        view.startProcess(executable: plan.executable, args: plan.args,
                          environment: env.map { "\($0.key)=\($0.value)" }.sorted(),
                          execName: nil, currentDirectory: NSHomeDirectory())
    }

    func close(_ name: String) {
        guard let item = items.first(where: { $0.id == name }) else { return }
        item.view.processDelegate = nil
        item.view.terminate()
        bus.remove(name)
        tokens[name] = nil
        remoteShells[name] = nil
        items.removeAll { $0.id == name }
    }

    func closeAll() {
        for item in items { close(item.id) }
    }

    // MARK: bus server

    private func startServer() {
        do {
            let bus = self.bus
            let server = try BusServer(port: UInt16(port)) { path, token, body in
                bus.handle(path: path, token: token, body: body)
            }
            self.server = server
            let port = self.port
            server.start { [weak self] error in
                if let error {
                    self?.problem = "The bus could not listen on 127.0.0.1:\(port) (\(error)). Is another copy running?"
                }
            }
        } catch {
            problem = "The bus could not start on 127.0.0.1:\(port): \(error)"
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let pane = source as? TerminalPane else { return }
        bus.setState(pane.paneName, .exited)
    }

    // MARK: smoke test

    /// XHS_SMOKE=1: open one pane running `echo ok` (locally, or on XHS_SMOKE_HOST over ssh), check its screen
    /// and the bus, then quit.
    func runSmoke() {
        let name = "shell-1"
        let host = ProcessInfo.processInfo.environment["XHS_SMOKE_HOST"] ?? ""
        if let problem = addPane(kind: .shell, host: host, name: name) {
            print("XHS_SMOKE failed: \(problem)")
            exit(1)
        }
        let deadline = Date().addingTimeInterval(15)
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screen = self.items.first?.view.screenText() ?? ""
                if self.bus.info(name)?.state == .exited, screen.contains("ok"), self.problem.isEmpty {
                    timer.invalidate()
                    Task { await self.finishSmoke(name) }
                } else if Date() > deadline {
                    timer.invalidate()
                    print("XHS_SMOKE failed: state \(self.bus.info(name)?.state.rawValue ?? "none"), screen \(screen.debugDescription), problem \(self.problem.debugDescription)")
                    exit(1)
                }
            }
        }
    }

    private func finishSmoke(_ name: String) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/panes")!)
        request.httpMethod = "POST"
        request.setValue(tokens[name], forHTTPHeaderField: "X-XHS-Token")
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["you"] as? String == name else {
            print("XHS_SMOKE failed: the bus did not answer on 127.0.0.1:\(port)")
            exit(1)
        }
        let host = bus.info(name)?.host ?? ""
        let location = host.isEmpty ? "locally" : "on \(host) (\(remoteShells[name] == .windows ? "Windows" : "POSIX") shell)"
        print("XHS_SMOKE ok: pane \(name) printed ok \(location), the bus answered on 127.0.0.1:\(port)")
        closeAll()
        exit(0)
    }

    static let hostsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xhs/hosts")

    private static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}
