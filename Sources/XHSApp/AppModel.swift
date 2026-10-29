import AppKit
import SwiftTerm
import XHSCore

/// The window's state: the panes, the bus and its HTTP server.
@MainActor
final class AppModel: NSObject, ObservableObject {
    static let shared = AppModel()

    struct Item: Identifiable {
        /// The pane's identity for the grid: the terminal view, which outlives a rename.
        var id: ObjectIdentifier { ObjectIdentifier(view) }
        var name: String
        let kind: HarnessKind
        let view: TerminalPane
        /// The start folder as given, empty for the home folder.
        let directory: String
    }

    @Published private(set) var items: [Item] = []
    /// Problems the owner should see (bus port taken, tools not installed).
    @Published private(set) var problem = ""
    /// Bumped on every bus change so headers redraw.
    @Published private(set) var revision = 0
    /// The plus button's picker is open.
    @Published var picking = false
    /// The Runner log is open above the bottom strip (it opens while Runner starts, closes once it serves).
    @Published var runnerLogOpen = false
    /// Hosts used for remote panes, latest first (~/.xhs/hosts).
    @Published private(set) var recentHosts: [String] = []
    /// Start folders used before, latest first (~/.xhs/folders).
    @Published private(set) var recentFolders: [String] = []
    /// What Runner serves on this Mac, empty when it does not answer; refreshed when the picker opens.
    @Published private(set) var runnerModel = ""
    /// The models the last Runner pane found to fit this Mac (~/.xhs/runner/fits), largest first.
    @Published private(set) var runnerFits: [RunnerFit] = []
    /// The model the owner chose for Runner panes (~/.xhs/runner/model), empty for the largest that fits.
    @Published private(set) var runnerChoice = ""

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
        recentFolders = RecentHosts.load(AppModel.foldersFile, valid: RecentHosts.isFolder)
        bus.onChange = { [weak self] in self?.revision &+= 1 }
        startServer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bus.tick()
                self.ticks += 1
                if self.ticks % 5 == 0 { self.fillRunnerHeader() }
            }
        }
        // The bus holds relayed messages while the owner types in that pane and while unsent text sits there.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let pane = event.window?.firstResponder as? TerminalPane {
                self?.bus.noteOwnerInput(pane.paneName, AppModel.ownerKey(event))
            }
            return event
        }
        if !smoke, let trouble = ToolInstall.run() {
            problem = trouble
        }
    }

    private var ticks = 0

    /// The Runner pane that is starting or serving, if any.
    var runnerPane: Bus.Info? {
        bus.all.first { $0.kind == .runner && $0.state != .exited }
    }

    /// A Runner pane shows the model it serves once the server answers.
    private func fillRunnerHeader() {
        let waiting = bus.all.filter { $0.kind == .runner && $0.state == .running && ($0.model.isEmpty || $0.model.hasPrefix("fetching ")) }.map(\.name)
        guard !waiting.isEmpty else { return }
        Task {
            guard let model = await Launcher.fetchRunnerModel() else { return }
            for name in waiting { bus.setModel(name, model) }
            runnerModel = model
        }
    }

    static let runnerHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xhs/runner")

    /// Asks Runner what it serves and reads what the start script found to fit, for the picker.
    func refreshRunner() {
        runnerFits = RunnerFit.parse((try? String(contentsOf: AppModel.runnerHome.appendingPathComponent("fits"), encoding: .utf8)) ?? "")
        runnerChoice = ((try? String(contentsOf: AppModel.runnerHome.appendingPathComponent("model"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task { runnerModel = await Launcher.fetchRunnerModel() ?? "" }
    }

    /// Serves `spelling` in a Runner pane from now on: remembers it, replaces the Runner pane that is up.
    func chooseRunnerModel(_ spelling: String) {
        try? FileManager.default.createDirectory(at: AppModel.runnerHome, withIntermediateDirectories: true)
        try? (spelling + "\n").write(to: AppModel.runnerHome.appendingPathComponent("model"), atomically: true, encoding: .utf8)
        runnerChoice = spelling
        if let pane = runnerPane { close(pane.name) }
        addPane(kind: .runner, host: "", name: "")
    }

    /// What a keystroke does to a harness composer: Enter sends it, Ctrl-C and Ctrl-U empty it, Delete
    /// removes a character, printable keys and a paste add text; the rest moves around.
    static func ownerKey(_ event: NSEvent) -> Bus.OwnerKey {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: return flags.isDisjoint(with: [.shift, .option]) ? .clear : .text
        case 51, 117: return .delete
        default: break
        }
        if flags.contains(.control), let c = event.charactersIgnoringModifiers, c == "c" || c == "u" { return .clear }
        if flags.contains(.command) { return event.charactersIgnoringModifiers == "v" ? .text : .other }
        guard let chars = event.characters, let first = chars.unicodeScalars.first else { return .other }
        return first.value >= 0x20 && first.value != 0x7F && !(0xF700...0xF8FF).contains(first.value) ? .text : .other
    }

    // MARK: panes

    /// Adds a pane and starts its harness. Returns a message for the picker when the input is not usable.
    /// `directory` is the start folder: on this Mac it must exist (~ is expanded); on a host it is passed as typed.
    @discardableResult
    func addPane(kind: HarnessKind, host rawHost: String, name rawName: String, directory rawDirectory: String = "") -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty, !Hosts.isValid(host) {
            return "Host is an ssh destination such as box or user@box."
        }
        if kind == .runner, !host.isEmpty {
            return "A Runner pane serves on this Mac; leave the host empty."
        }
        if kind == .runner, let pane = runnerPane {
            return "Runner is already \(pane.state == .running ? "serving" : "starting") in \(pane.name)."
        }
        var directory = rawDirectory.trimmingCharacters(in: .whitespaces)
        if host.isEmpty, !directory.isEmpty {
            directory = (directory as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
                return "No folder at \(directory)."
            }
        }
        var name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty {
            name = PaneNames.next(for: kind, taken: Set(bus.names))
        } else if !PaneNames.isValid(name) {
            return PaneNames.rule
        } else if bus.names.contains(name) {
            return "\(name) is already open."
        }
        let view = TerminalPane(name: name)
        view.onExit = { [weak self, weak view] _ in if let view { self?.bus.setState(view.paneName, .exited) } }
        let token = bus.add(name: name, kind: kind, host: host, io: view)
        tokens[name] = token
        if !host.isEmpty { recentHosts = RecentHosts.remember(host, in: AppModel.hostsFile) }
        if !directory.isEmpty { recentFolders = RecentHosts.remember(directory, in: AppModel.foldersFile, valid: RecentHosts.isFolder) }
        items.append(Item(name: name, kind: kind, view: view, directory: directory))
        Task { await launch(view, kind: kind, host: host, token: token, directory: directory) }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return nil
    }

    private func launch(_ view: TerminalPane, kind: HarnessKind, host: String, token: String, directory: String) async {
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
        guard items.contains(where: { $0.view === view }) else { return }
        start(view, Launcher.plan(kind: kind, paneName: view.paneName, host: host.isEmpty ? nil : host, port: port,
                                  token: token, runnerModel: model, loginShell: loginShell, remoteShell: remoteShell,
                                  directory: directory))
    }

    private func start(_ view: TerminalPane, _ plan: LaunchPlan) {
        let env = Launcher.paneEnvironment(from: ProcessInfo.processInfo.environment, adding: plan.environment)
        view.startProcess(executable: plan.executable, args: plan.args,
                          environment: env.map { "\($0.key)=\($0.value)" }.sorted(),
                          execName: nil, currentDirectory: plan.directory ?? NSHomeDirectory())
    }

    /// Renames a pane. Returns a message for the header when the name is not usable.
    func rename(_ name: String, to rawNew: String) -> String? {
        let new = rawNew.trimmingCharacters(in: .whitespaces).lowercased()
        guard let index = items.firstIndex(where: { $0.name == name }) else { return "no pane named '\(name)'" }
        if let problem = bus.rename(name, to: new) { return problem }
        tokens[new] = tokens.removeValue(forKey: name)
        remoteShells[new] = remoteShells.removeValue(forKey: name)
        items[index].name = new
        items[index].view.paneName = new
        return nil
    }

    /// Swaps two panes' places in the grid.
    func swap(_ a: String, with b: String) {
        guard a != b, let i = items.firstIndex(where: { $0.name == a }), let j = items.firstIndex(where: { $0.name == b }) else { return }
        // Re-parenting drops the first responder; give it back to the pane that had it.
        let focused = items.first { $0.view.window?.firstResponder === $0.view }?.view
        items.swapAt(i, j)
        if let focused { DispatchQueue.main.async { focused.window?.makeFirstResponder(focused) } }
    }

    func close(_ name: String) {
        guard let item = items.first(where: { $0.name == name }) else { return }
        item.view.onExit = nil
        item.view.terminate()
        bus.remove(name)
        tokens[name] = nil
        remoteShells[name] = nil
        items.removeAll { $0.name == name }
    }

    func closeAll() {
        for item in items { close(item.name) }
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
        // A local pane gets a line typed in through the view, as keys, after it has had a second to start.
        let typed = host.isEmpty ? "typed" : ""
        let expected = host.isEmpty ? "ok typed" : "ok"
        if host.isEmpty {
            // A second pane, swapped with the first as a drag would do it: the first must still take keys.
            addPane(kind: .shell, host: "", name: "shell-2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.swap(name, with: "shell-2") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let view = self?.items.first(where: { $0.name == name })?.view else { return }
                // Focus comes from the click, not from the model, as in the window.
                view.window?.makeFirstResponder(nil)
                view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                                        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                                      windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
                guard view.window?.firstResponder === view else { print("XHS_SMOKE failed: a click did not focus the pane"); exit(1) }
                for character in typed + "\r" {
                    let c = String(character)
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                                    characters: c, charactersIgnoringModifiers: c, isARepeat: false,
                                                    keyCode: character == "\r" ? 36 : 0) {
                        view.keyDown(with: event)
                    }
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                let screen = self.items.first(where: { $0.name == name })?.view.screenText() ?? ""
                if self.bus.info(name)?.state == .exited, screen.contains(expected), self.problem.isEmpty {
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
        let dims = items.first?.view.terminalDimensions
        print("XHS_SMOKE ok: pane \(name) echoed the typed line \(location), the bus answered on 127.0.0.1:\(port), terminal \(dims?.cols ?? 0)x\(dims?.rows ?? 0)")
        closeAll()
        exit(0)
    }

    static let hostsFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xhs/hosts")
    static let foldersFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xhs/folders")

    /// A folder picker for the New terminal sheet; nil when cancelled.
    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }
}
