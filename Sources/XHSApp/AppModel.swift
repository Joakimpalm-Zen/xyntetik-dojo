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
        /// Opened with "Skip permission prompts" ticked (D21.1). `Permissions.unrestricted` says whether
        /// the pane runs without prompts, which pi always does.
        let unrestricted: Bool
        let view: TerminalPane
        /// The start folder as given, empty for the home folder.
        let directory: String
        /// Reopened with no session to resume. The header says so: the harness clears the terminal when it draws.
        var startedFresh = false
    }

    @Published private(set) var items: [Item] = []
    /// The tab shown: nil for the overview (every agent pane in the grid), else one pane filling the window.
    @Published private(set) var selectedTab: ObjectIdentifier?
    /// Problems the owner should see (bus port taken, tools not installed).
    @Published private(set) var problem = ""
    /// Bumped on every bus change so headers redraw.
    @Published private(set) var revision = 0
    /// The plus button's picker is open.
    @Published var picking = false
    /// The Runner log is open above the bottom strip (it opens while Runner starts, closes once it serves).
    @Published var runnerLogOpen = false
    /// Every pane's text size, changed by Cmd-plus, Cmd-minus and Cmd-0.
    @Published private(set) var fontSize: CGFloat = TerminalPane.defaultFont.pointSize
    /// Hosts used for remote panes, latest first (~/.dojo/hosts).
    @Published private(set) var recentHosts: [String] = []
    /// Start folders used before, latest first (~/.dojo/folders).
    @Published private(set) var recentFolders: [String] = []
    /// The harnesses the owner last opened with "Skip permission prompts" ticked (~/.dojo/unrestricted):
    /// the picker starts each that way. None on a fresh install (D21.1).
    @Published private(set) var unrestrictedKinds: Set<HarnessKind> = []
    /// What Runner serves on this Mac, empty when it does not answer; refreshed when the picker opens.
    @Published private(set) var runnerModel = ""
    /// Who answers on Runner's port: Runner, or another server of the owner's (llama-server, for one), which
    /// the pi panes use as it is and a Runner pane steps aside for. Empty when nothing answers.
    @Published private(set) var servedBy = ""
    /// Another server than Runner holds Runner's port.
    var foreignServer: Bool { !runnerModel.isEmpty && servedBy != "Runner" }
    /// The models the last Runner pane found to fit this Mac (~/.dojo/runner/fits), largest first.
    @Published private(set) var runnerFits: [RunnerFit] = []
    /// The model the owner chose for Runner panes (~/.dojo/runner/model), empty for the largest that fits.
    @Published private(set) var runnerChoice = ""

    /// Panes with a prompt or a finished turn the owner has not viewed. The Dock badge counts them.
    @Published private(set) var unseen: Set<ObjectIdentifier> = [] {
        didSet { NSApp.dockTile.badgeLabel = unseen.isEmpty ? nil : String(unseen.count) }
    }
    /// What a smoke would have notified, in place of notifying.
    private var smokeNotified: [String] = []
    private lazy var notifier: Notifier = {
        let notifier = Notifier()
        notifier.onOpen = { [weak self] pane in self?.open(pane) }
        return notifier
    }()
    /// The panes of the last run, for the button in the empty window, until a pane opens in this one.
    @Published private(set) var lastPanes: [SavedPane] = []
    /// Set while quitting: the panes close, and the list of them must outlive that.
    private var keepingList = false
    private var piFlagCheck: Task<Bool, Never>?
    /// The pane that has the keys, nil when none has.
    @Published private(set) var focusedPane: ObjectIdentifier?
    private var focusWatch: NSKeyValueObservation?
    private weak var mainWindow: NSWindow?
    private var restoreWatch: NSObjectProtocol?
    /// The pane that should hold the keys. A move between the grid and a tab drops them, at a moment SwiftUI
    /// picks, so this pane takes them back when it lands.
    private weak var keyPane: TerminalPane? { didSet { dimPanes() } }

    let bus = Bus()
    let port: Int
    let smoke: Bool
    private let loginShell: String
    private var tokens: [String: String] = [:]
    private var remoteShells: [String: RemoteShell] = [:]
    /// Each remote pane's end of its own forward to the bus.
    private var remotePorts: [ObjectIdentifier: Int] = [:]
    /// D12: the port on this Mac where a remote Runner pane's forward brings its host's Runner.
    private var runnerForwards: [ObjectIdentifier: Int] = [:]
    private var server: BusServer?
    private var timer: Timer?

    override init() {
        let env = ProcessInfo.processInfo.environment
        // DOJO_PORT must be a port; anything else is said and the default used.
        let wanted = env["DOJO_PORT"].flatMap { Int($0) }
        port = wanted.flatMap { (1...65535).contains($0) ? $0 : nil } ?? Launcher.defaultPort
        smoke = Headless.isRequested
        loginShell = AppModel.userShell()
        super.init()
        if let wanted, wanted != port { problem = "DOJO_PORT is \(wanted); a port is 1 to 65535. Using \(port)." }
        // The tools (and the move from ~/.xhs) come first, so the recent lists are read from the right folder.
        if !smoke, let trouble = ToolInstall.run() {
            problem = trouble
        }
        recentHosts = RecentHosts.load(AppModel.hostsFile)
        recentFolders = RecentHosts.load(AppModel.foldersFile, valid: RecentHosts.isFolder)
        unrestrictedKinds = Permissions.remembered(AppModel.unrestrictedFile)
        lastPanes = SavedPanes.load(AppModel.panesFile)
        bus.onChange = { [weak self] in self?.revision &+= 1 }
        bus.onSession = { [weak self] in self?.savePanes() }
        bus.onAttention = { [weak self] name, attention in self?.attend(name, attention) }
        startServer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bus.tick()
                self.ticks += 1
                if self.ticks % 5 == 0 { self.fillRunnerHeader() }
            }
        }
    }

    private var ticks = 0

    /// The panes with a tab each, in grid order: every pane but Runner, which has the strip at the bottom.
    var agents: [Item] { items.filter { $0.kind != .runner } }

    /// Shows a pane's tab, or the overview for nil, and gives that pane the keys.
    func show(tab id: ObjectIdentifier?) {
        selectedTab = id.flatMap { id in agents.contains { $0.id == id } ? id : nil }
        let focus = selectedTab.flatMap { id in agents.first { $0.id == id }?.view }
            ?? agents.first { $0.view.window?.firstResponder === $0.view }?.view
        if let focus { give(keys: focus) }
    }

    /// Gives a pane the keys: now if it is in the window, else when it lands there.
    private func give(keys view: TerminalPane) {
        keyPane = view
        view.window?.makeFirstResponder(view)
    }

    /// Every pane but the one with the keys is dimmed. While the keys are in a field for a moment, a rename
    /// say, the pane that had them stays lit, so the grid does not flash.
    private func dimPanes() {
        for item in items { item.view.dimmed = keyPane != nil && item.view !== keyPane }
    }

    /// Keeps `focusedPane` true to the window. SwiftTerm closes its responder methods to subclasses, so the
    /// window is the one to ask.
    func watchFocus(of window: NSWindow) {
        mainWindow = window
        // Restoring a minimized window does not activate the app, which was active all along.
        restoreWatch = NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markSeen() }
        }
        focusWatch = window.observe(\.firstResponder, options: [.initial]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                let pane = window.firstResponder as? TerminalPane
                self?.focusedPane = pane.map(ObjectIdentifier.init)
                if let pane { self?.keyPane = pane }
                self?.markSeen()
            }
        }
    }

    // MARK: what needs the owner

    /// A smoke is never in front, and stands in for an owner who is.
    private var ownerInFront: Bool {
        smoke || Seen.inFront(active: NSApp.isActive, windowOnScreen: mainWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false)
    }

    /// The pane finished a turn the owner has not viewed. A pane at a prompt has the ring instead.
    func finishedUnseen(_ item: Item) -> Bool {
        unseen.contains(item.id) && bus.info(item.name)?.state == .idle
    }

    /// Panes at a prompt, for the count on the All tab.
    var waiting: Int { agents.filter { bus.info($0.name)?.state == .prompt }.count }

    private func attend(_ name: String, _ attention: Attention) {
        guard let item = items.first(where: { $0.name == name }) else { return }
        if !Seen.viewed(active: ownerInFront, keys: focusedPane, pane: item.id) { unseen.insert(item.id) }
        guard Seen.notifies(active: ownerInFront, shown: selectedTab, pane: item.id) else { return }
        if smoke { smokeNotified.append("\(name) \(attention.rawValue)") } else { notifier.post(pane: name, attention) }
    }

    /// The pane with the keys is viewed, once the owner is in front.
    func markSeen() {
        guard ownerInFront, let focusedPane, unseen.contains(focusedPane) else { return }
        unseen.remove(focusedPane)
    }

    /// Starts listening for clicks on notifications, also those from before a relaunch.
    func startNotifying() {
        _ = notifier
    }

    /// A click on a notification: the app in front, on that pane's tab.
    private func open(_ name: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let item = agents.first(where: { $0.name == name }) { show(tab: item.id) }
    }

    /// The next tab (Cmd-Shift-]) or the previous (Cmd-Shift-[), through the overview.
    func stepTab(_ step: Int) {
        let ids = agents.map(\.id)
        show(tab: step > 0 ? TabOrder.next(after: selectedTab, in: ids) : TabOrder.previous(before: selectedTab, in: ids))
    }

    /// This Mac's Runner pane that is starting or serving, if any: the newest, since a stopped one may still be open.
    var runnerPane: Bus.Info? { runnerPane(host: "") }

    /// The Runner pane starting or serving on `host` ("" for this Mac). One a machine (D12).
    func runnerPane(host: String) -> Bus.Info? {
        bus.all.last { $0.kind == .runner && $0.host == host && $0.state != .exited }
    }

    /// Where this Mac reaches a Runner pane's server: its own 8080, or a remote pane's forward (D12).
    func runnerURL(of pane: Bus.Info) -> String? {
        guard !pane.host.isEmpty else { return Launcher.runnerURL }
        guard let item = items.first(where: { $0.name == pane.name }), let port = runnerForwards[item.id] else { return nil }
        return Launcher.runnerURL(forward: port)
    }

    /// A Runner pane shows the model it serves once its server answers, each at its own URL.
    private func fillRunnerHeader() {
        let waiting = bus.all.filter { $0.kind == .runner && $0.state == .running && ($0.model.isEmpty || $0.model.hasPrefix("fetching ")) }
        guard !waiting.isEmpty else { return }
        for pane in waiting {
            guard let url = runnerURL(of: pane) else { continue }
            Task {
                guard let served = await Launcher.fetchServed(at: url) else { return }
                bus.setModel(pane.name, served.model)
                if pane.host.isEmpty {
                    runnerModel = served.model
                    servedBy = served.serverName
                }
            }
        }
    }

    /// The Runner a pi pane on this Mac uses: this Mac's own when it answers, else a remote Runner pane that
    /// serves, through its forward (D12). nil: no Runner answers.
    private func runnerForLocalPi() async -> (url: String, model: String)? {
        if let model = await Launcher.fetchRunnerModel() { return (Launcher.runnerURL, model) }
        for pane in bus.all.reversed() where pane.kind == .runner && !pane.host.isEmpty && pane.state == .running {
            guard let url = runnerURL(of: pane), let model = await Launcher.fetchRunnerModel(at: url) else { continue }
            return (url, model)
        }
        return nil
    }

    static let runnerHome = Headless.state().appendingPathComponent("runner")

    /// Asks Runner what it serves and reads what the start script found to fit, for the picker.
    func refreshRunner() {
        runnerFits = RunnerFit.parse((try? String(contentsOf: AppModel.runnerHome.appendingPathComponent("fits"), encoding: .utf8)) ?? "")
        runnerChoice = ((try? String(contentsOf: AppModel.runnerHome.appendingPathComponent("model"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let served = await Launcher.fetchServed()
            runnerModel = served?.model ?? ""
            servedBy = served?.serverName ?? ""
        }
    }

    /// Serves `spelling` in a Runner pane from now on: remembers it, replaces the Runner pane that is up.
    func chooseRunnerModel(_ spelling: String) {
        try? FileManager.default.createDirectory(at: AppModel.runnerHome, withIntermediateDirectories: true)
        try? (spelling + "\n").write(to: AppModel.runnerHome.appendingPathComponent("model"), atomically: true, encoding: .utf8)
        runnerChoice = spelling
        if let pane = runnerPane { close(pane.name) }
        addPane(kind: .runner, host: "", name: "")
    }

    // MARK: panes

    /// Adds a pane and starts its harness. Returns a message for the picker when the input is not usable.
    /// `directory` is the start folder: on this Mac it must exist (~ is expanded); on a host it is passed as typed.
    @discardableResult
    func addPane(kind: HarnessKind, host rawHost: String, name rawName: String, directory rawDirectory: String = "", unrestricted: Bool = false,
                 session: String? = nil, reopened: Bool = false) -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty, !Hosts.isValid(host) {
            return "Host is an ssh destination such as box or user@box."
        }
        if kind == .runner, let pane = runnerPane(host: host) {
            return "Runner is already \(pane.state == .running ? "serving" : "starting") in \(pane.name)"
                + (host.isEmpty ? "." : " on \(host).")
        }
        if kind == .runner, host.isEmpty, foreignServer {
            return "\(servedBy) is serving \(runnerModel) on 127.0.0.1:8080; the pi panes use it. Stop it to let Runner serve."
        }
        // A stopped Runner pane gives way to the new one.
        if kind == .runner {
            for stopped in items where stopped.kind == .runner && bus.info(stopped.name)?.state == .exited
                && bus.info(stopped.name)?.host == host { close(stopped.name) }
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
        if fontSize != TerminalPane.defaultFont.pointSize { view.setTextSize(fontSize) }
        view.onExit = { [weak self, weak view] _ in if let view { self?.bus.setState(view.paneName, .exited) } }
        view.onLanded = { [weak self, weak view] in
            // It may land before the pane it replaces has left. A rename field that has the keys keeps them.
            guard let view, self?.keyPane === view, let window = view.window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(view)
        }
        // The bus holds relayed messages while the owner types in the pane and while unsent text sits there.
        view.onOwnerInput = { [weak self, weak view] key in if let view { self?.bus.noteOwnerInput(view.paneName, key) } }
        let token = bus.add(name: name, kind: kind, host: host, io: view)
        tokens[name] = token
        if !host.isEmpty { recentHosts = RecentHosts.remember(host, in: AppModel.hostsFile) }
        if !directory.isEmpty { recentFolders = RecentHosts.remember(directory, in: AppModel.foldersFile, valid: RecentHosts.isFolder) }
        items.append(Item(name: name, kind: kind, unrestricted: unrestricted, view: view, directory: directory))
        if let session { bus.setSession(name, session) }
        lastPanes = []
        savePanes()
        Task { await launch(view, kind: kind, host: host, token: token, directory: directory, unrestricted: unrestricted, saved: session, reopened: reopened) }
        give(keys: view)
        return nil
    }

    private func launch(_ view: TerminalPane, kind: HarnessKind, host: String, token: String, directory: String, unrestricted: Bool,
                        saved: String?, reopened: Bool) async {
        var session = saved
        if kind == .pi {
            // Claude Code and Codex report their session through hooks; a pi that can take one is given it.
            let listed = host.isEmpty ? await piListsSession() : false
            guard items.contains(where: { $0.view === view }) else { return }
            session = Launcher.piSession(saved: saved, host: host, listed: listed, newId: UUID().uuidString.lowercased())
            bus.setSession(view.paneName, session)
            savePanes()
        }
        if Launcher.startsFresh(kind: kind, reopened: reopened, saved: saved, session: session),
           let index = items.firstIndex(where: { $0.view === view }) {
            items[index].startedFresh = true
        }
        // A smoke starts no coding agent: what it checks of these panes is their header.
        if smoke, HarnessKind.pickable.contains(kind) { return }
        var model: String?
        var piRunnerURL: String?
        if kind == .pi, host.isEmpty {
            let runner = await runnerForLocalPi()
            guard items.contains(where: { $0.view === view }) else { return }
            guard let runner else {
                bus.setModel(view.paneName, "Runner offline")
                start(view, Launcher.runnerOfflinePlan())
                return
            }
            model = runner.model
            // this Mac's own Runner needs no variable; a remote one is named by its forward
            if runner.url != Launcher.runnerURL { piRunnerURL = runner.url }
            bus.setModel(view.paneName, runner.model)
        }
        // A pi pane on a host with a Dojo Runner pane uses that Runner, on Dojo's port there (D12); without
        // one it uses the host's own 8080, as before.
        if kind == .pi, !host.isEmpty, runnerPane(host: host) != nil { piRunnerURL = Launcher.hostRunnerURL }
        // A remote host is asked which shell it runs commands in: cmd.exe (Windows) or a POSIX shell.
        var remoteShell = RemoteShell.posix
        var msysBash: String?
        var note: String?
        if !host.isEmpty {
            (remoteShell, msysBash, note) = await Launcher.probeRemoteShell(host: host)
            remoteShells[view.paneName] = remoteShell
        }
        guard items.contains(where: { $0.view === view }) else { return }
        var remotePort: Int?
        if !host.isEmpty {
            remotePort = Launcher.remotePort(taken: Set(remotePorts.values))
            remotePorts[ObjectIdentifier(view)] = remotePort
        }
        var runnerForward: Int?
        if kind == .runner, !host.isEmpty {
            guard let free = Launcher.runnerForwardPort(taken: Set(runnerForwards.values)) else {
                view.feed(text: "No port in \(Launcher.runnerForwardPorts) is free on this Mac for this host's Runner.\r\n")
                return
            }
            runnerForward = free
            runnerForwards[ObjectIdentifier(view)] = free
        }
        if let note { view.feed(text: note + "\r\n\r\n") }
        start(view, Launcher.plan(kind: kind, paneName: view.paneName, host: host.isEmpty ? nil : host, port: port,
                                  token: token, runnerModel: model, loginShell: loginShell, remoteShell: remoteShell,
                                  directory: directory, unrestricted: unrestricted, remotePort: remotePort, session: session,
                                  runnerForward: runnerForward, runnerURL: piRunnerURL, msysBash: msysBash))
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
        savePanes()
        return nil
    }

    /// Changes every pane's text size by `step` points, within 8 and 24; nil resets to the default.
    func zoom(_ step: CGFloat?) {
        fontSize = step.map { min(24, max(8, fontSize + $0)) } ?? TerminalPane.defaultFont.pointSize
        for item in items { item.view.setTextSize(fontSize) }
    }

    /// Swaps two panes' places in the grid.
    func swap(_ a: String, with b: String) {
        guard a != b, let i = items.firstIndex(where: { $0.name == a }), let j = items.firstIndex(where: { $0.name == b }) else { return }
        // Re-parenting drops the first responder; give it back to the pane that had it.
        let focused = items.first { $0.view.window?.firstResponder === $0.view }?.view
        items.swapAt(i, j)
        if let focused { give(keys: focused) }
    }

    func close(_ name: String) {
        guard let item = items.first(where: { $0.name == name }) else { return }
        // Re-parenting the grid drops the first responder; give it back to the pane that had it.
        var focused = items.first { $0.view !== item.view && $0.view.window?.firstResponder === $0.view }?.view
        let hadKeys = item.view.window?.firstResponder === item.view
        let place = agents.firstIndex { $0.id == item.id }
        item.view.onExit = nil
        item.view.terminate()
        bus.remove(name)
        unseen.remove(item.id)
        remotePorts[item.id] = nil
        runnerForwards[item.id] = nil
        tokens[name] = nil
        remoteShells[name] = nil
        items.removeAll { $0.name == name }
        // Its tab goes with it; the overview shows what is left.
        if selectedTab == item.id { selectedTab = nil }
        // The keys go to the pane in its place, or the next key would reach no pane at all.
        if hadKeys, let place, let heir = TabOrder.heir(of: place, among: agents.count) { focused = agents[heir].view }
        if let focused { give(keys: focused) }
        savePanes()
    }

    /// Panes whose harness is still running, for the quit confirmation.
    var livePanes: Int {
        items.filter { bus.info($0.name)?.state != .exited }.count
    }

    /// Quitting, and the end of a smoke. The list stays: this is what the next launch offers to reopen.
    func closeAll() {
        keepingList = true
        for item in items { close(item.name) }
        keepingList = false
    }

    // MARK: reopening

    /// Whether the local pi knows --session-id, asked once per run.
    private func piListsSession() async -> Bool {
        let shell = loginShell
        let check = piFlagCheck ?? Task { await Launcher.helpLists("--session-id", command: "pi --help", loginShell: shell) }
        piFlagCheck = check
        return await check.value
    }

    private func savePanes() {
        guard !keepingList else { return }
        SavedPanes.save(items.map { item in
            SavedPane(kind: item.kind, host: bus.info(item.name)?.host ?? "", directory: item.directory, name: item.name,
                      unrestricted: item.unrestricted, session: bus.sessionId(item.name))
        }, to: AppModel.panesFile)
    }

    /// The button in the empty window. Nothing reopens by itself.
    func reopenLast() {
        for pane in lastPanes {
            if let trouble = addPane(kind: pane.kind, host: pane.host, name: pane.name, directory: pane.directory, unrestricted: pane.unrestricted,
                                     session: pane.session, reopened: true) {
                problem = "\(pane.name): \(trouble)"
            }
        }
    }

    /// A remote pane whose connection dropped can come back, if it has a session to come back to.
    func canReopen(_ item: Item) -> Bool {
        guard let info = bus.info(item.name) else { return false }
        return info.state == .exited && !info.host.isEmpty && bus.sessionId(item.name) != nil
    }

    func reopen(_ item: Item) {
        guard canReopen(item), let session = bus.sessionId(item.name) else { return }
        let host = bus.info(item.name)?.host ?? ""
        close(item.name)
        if let trouble = addPane(kind: item.kind, host: host, name: item.name, directory: item.directory, unrestricted: item.unrestricted,
                                 session: session, reopened: true) {
            problem = "\(item.name): \(trouble)"
        }
    }

    // MARK: bus server

    /// Listens on the bus port. A copy that was just quit may still hold the port for a moment (make run
    /// right after a quit), so a refused port is tried again for five seconds before it is a problem.
    private func startServer(attempt: Int = 0) {
        do {
            let bus = self.bus
            let server = try BusServer(port: UInt16(port)) { path, token, body in
                bus.handle(path: path, token: token, body: body)
            }
            bus.relayConfig = AppModel.relayFile
            server.deferred = { path, token, body, reply in bus.relay(path: path, token: token, body: body, reply: reply) }
            self.server = server
            let port = self.port
            server.start { [weak self] error in
                guard let self, let error else { return }
                self.server = nil
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startServer(attempt: attempt + 1) }
                } else {
                    self.problem = "The bus could not listen on 127.0.0.1:\(port) (\(error)). Is another copy running?"
                }
            }
        } catch {
            problem = "The bus could not start on 127.0.0.1:\(port): \(error)"
        }
    }

    // MARK: smoke test

    /// DOJO_SMOKE=1: open one pane running `echo ok` (locally, or on DOJO_SMOKE_HOST over ssh), check its screen
    /// and the bus, then quit.
    func runSmoke() {
        let name = "shell-1"
        let host = ProcessInfo.processInfo.environment["DOJO_SMOKE_HOST"] ?? ""
        if let problem = addPane(kind: .shell, host: host, name: name) {
            print("DOJO_SMOKE failed: \(problem)")
            exit(1)
        }
        let deadline = Date().addingTimeInterval(15)
        // A local pane gets a line typed in through the view, as keys, after it has had a second to start.
        let typed = host.isEmpty ? "typed" : ""
        let expected = host.isEmpty ? "ok typed" : "ok"
        if host.isEmpty {
            // A second pane, swapped with the first as a drag would do it, then the first shown in its own tab:
            // re-parented twice, it must still take keys.
            addPane(kind: .shell, host: "", name: "shell-2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.swap(name, with: "shell-2") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self else { return }
                self.show(tab: self.items.first(where: { $0.name == name })?.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let view = self?.items.first(where: { $0.name == name })?.view else { return }
                // Focus comes from the click, not from the model, as in the window.
                view.window?.makeFirstResponder(nil)
                view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                                        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                view.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                                      windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!)
                guard view.window?.firstResponder === view else { print("DOJO_SMOKE failed: a click did not focus the pane"); exit(1) }
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
                self.failIfSeen()
                let screen = self.items.first(where: { $0.name == name })?.view.screenText() ?? ""
                if self.bus.info(name)?.state == .exited, screen.contains(expected), self.problem.isEmpty {
                    timer.invalidate()
                    Task { await self.finishSmoke(name) }
                } else if Date() > deadline {
                    timer.invalidate()
                    print("DOJO_SMOKE failed: state \(self.bus.info(name)?.state.rawValue ?? "none"), screen \(screen.debugDescription), problem \(self.problem.debugDescription)")
                    exit(1)
                }
            }
        }
    }

    /// A smoke that reached the owner's screen or keyboard ends there, saying what did.
    private func failIfSeen() {
        let problems = Headless.problems
        guard !problems.isEmpty else { return }
        for problem in problems { print("DOJO_SMOKE failed: \(problem)") }
        closeAll()
        exit(1)
    }

    /// What a pane is given, and what a login shell finds, as a pane runs it: the throwaway home, and no way to
    /// the owner's. A login shell reads the owner's profile, so it is the one to ask, not this process.
    private func proveContained() async {
        let home = Headless.state().deletingLastPathComponent().path
        let real = Headless.realHome
        let pane = Launcher.paneEnvironment(from: ProcessInfo.processInfo.environment, adding: [:])
        let shell = #"printf '<%s>' "$HOME""#
        let script = #"test -e "$HOME/.dojo/runner-start.sh" && echo script-found"#
        let contained = await Launcher.helpLists("<\(home)>", command: shell, loginShell: loginShell)
        let owners = await Launcher.helpLists("<\(real)>", command: shell, loginShell: loginShell)
        let script0 = await Launcher.helpLists("script-found", command: script, loginShell: loginShell)
        guard pane["HOME"] == home, contained, !owners, !script0 else {
            print("DOJO_SMOKE failed: a pane's home is \(pane["HOME"] ?? "unset"), in a login shell contained \(contained), the owner's \(owners), Runner's script found \(script0)")
            exit(1)
        }
    }

    /// The cue on the pane header follows the keys: after a click, to a tab, to the overview, and to the pane
    /// that takes the place of one closed.
    private func proveFocus(_ name: String) async {
        func expect(_ pane: String, after step: String) async {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let id = items.first(where: { $0.name == pane })?.id, focusedPane == id else {
                let actual = items.first { $0.id == focusedPane }?.name ?? "no pane"
                print("DOJO_SMOKE failed: after \(step) the cue is on \(actual), not \(pane)")
                exit(1)
            }
            expectLit(pane, after: step)
        }
        await expect(name, after: "a click")
        // Dimming follows a click, a digit on the Tabs menu, and stays put while the keys are in no pane.
        if let other = items.first(where: { $0.name != name }) {
            show(tab: nil)
            await expect(name, after: "the overview")
            click(other.view)
            await expect(other.name, after: "a click on the other pane")
            other.view.window?.makeFirstResponder(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            expectLit(other.name, after: "the keys leaving every pane")
            var last = other.name
            for (i, agent) in agents.prefix(8).enumerated() {
                press(digit: i + 2)
                await expect(agent.name, after: "Cmd-\(i + 2)")
                last = agent.name
            }
            press(digit: 1)
            await expect(last, after: "Cmd-1")
            click(items.first { $0.name == name }!.view)
            await expect(name, after: "a click back")
        }
        addPane(kind: .shell, host: "", name: "shell-3")
        show(tab: items.last?.id)
        await expect("shell-3", after: "showing a tab")
        show(tab: nil)
        await expect("shell-3", after: "showing the overview")
        close("shell-3")
        await expect(name, after: "closing the pane with the keys")
    }

    private func expectLit(_ pane: String, after step: String) {
        let lit = items.filter { !$0.view.dimmed }.map(\.name)
        guard lit == [pane] else {
            print("DOJO_SMOKE failed: after \(step) the lit panes are \(lit), not \(pane)")
            exit(1)
        }
    }

    private func click(_ view: TerminalPane) {
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                      windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                    windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        if let down, let up {
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }
    }

    /// Cmd and a digit, through the menu bar as a key press goes.
    private func press(digit: Int) {
        let key = String(digit)
        // SwiftUI fills a menu's ForEach when the menu is about to show, and an app that is never in front
        // does not get that far by itself.
        if let tabs = NSApp.mainMenu?.items.first(where: { $0.title == "Tabs" })?.submenu { tabs.delegate?.menuNeedsUpdate?(tabs) }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: mainWindow?.windowNumber ?? 0,
                                           context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0),
              NSApp.mainMenu?.performKeyEquivalent(with: event) == true else {
            print("DOJO_SMOKE failed: Cmd-\(digit) did nothing")
            exit(1)
        }
    }

    /// Sends a pane the hook events a harness would.
    private func smokeHooks(_ pane: String, _ events: [[String: Any]]) {
        for event in events {
            _ = bus.handle(path: "/hook", token: tokens[pane], body: (try? JSONSerialization.data(withJSONObject: event)) ?? Data())
        }
    }

    /// The whole path from a hook to what the owner sees, on the second pane: a prompt behind another tab,
    /// reported twice as Claude Code does, then answered, then a finished turn.
    private func proveAttention(_ name: String) async {
        guard let first = items.first(where: { $0.name == name }), let second = items.first(where: { $0.name != name }) else { return }
        func expect(_ step: String, waiting wanted: Int, unseen seen: Bool, notified: [String]) async {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let badge = NSApp.dockTile.badgeLabel
            guard waiting == wanted, unseen.contains(second.id) == seen, smokeNotified == notified, (badge != nil) == !unseen.isEmpty else {
                print("DOJO_SMOKE failed: after \(step): waiting \(waiting), unseen \(unseen.count), badge \(badge ?? "none"), notified \(smokeNotified)")
                exit(1)
            }
        }
        let prompt = "\(second.name) prompt", finished = "\(second.name) finished"
        show(tab: first.id)
        try? await Task.sleep(nanoseconds: 300_000_000)
        smokeHooks(second.name, [["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "PermissionRequest"],
                                 ["hook_event_name": "Notification", "notification_type": "permission_prompt"]])
        await expect("a prompt behind a tab", waiting: 1, unseen: true, notified: [prompt])
        show(tab: second.id)
        await expect("viewing it", waiting: 1, unseen: false, notified: [prompt])
        smokeHooks(second.name, [["hook_event_name": "PostToolUse"]])
        await expect("answering it", waiting: 0, unseen: false, notified: [prompt])
        show(tab: first.id)
        try? await Task.sleep(nanoseconds: 300_000_000)
        smokeHooks(second.name, [["hook_event_name": "Stop"], ["hook_event_name": "Stop"]])
        await expect("a finish behind a tab", waiting: 0, unseen: true, notified: [prompt, finished])
        show(tab: nil)
        await expect("the overview, which is not viewing it", waiting: 0, unseen: true, notified: [prompt, finished])
        show(tab: second.id)
        await expect("opening its tab", waiting: 0, unseen: false, notified: [prompt, finished])
        show(tab: first.id)
        try? await Task.sleep(nanoseconds: 300_000_000)
        show(tab: nil)
    }

    private func finishSmoke(_ name: String) async {
        if bus.info(name)?.host.isEmpty == true {
            await proveContained()
            await proveFocus(name)
            await proveAttention(name)
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/panes")!)
        request.httpMethod = "POST"
        request.setValue(tokens[name], forHTTPHeaderField: "X-Dojo-Token")
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["you"] as? String == name else {
            print("DOJO_SMOKE failed: the bus did not answer on 127.0.0.1:\(port)")
            exit(1)
        }
        let host = bus.info(name)?.host ?? ""
        let location = host.isEmpty ? "locally" : "on \(host) (\(remoteShells[name] == .windows ? "Windows" : "POSIX") shell)"
        let dims = items.first(where: { $0.name == name })?.view.terminalDimensions
        let font = items.first(where: { $0.name == name })?.view.font
        failIfSeen()
        let tab = selectedTab == nil ? "the overview" : "its own tab"
        print("DOJO_SMOKE ok: pane \(name) echoed the typed line \(location) in \(tab), the bus answered on 127.0.0.1:\(port), terminal \(dims?.cols ?? 0)x\(dims?.rows ?? 0), font \(font?.fontName ?? "none") \(font?.pointSize ?? 0)")
        // DOJO_SMOKE_SHOT=<file.png>: a picture of the overview with both panes, for a look at the chrome.
        if let shot = ProcessInfo.processInfo.environment["DOJO_SMOKE_SHOT"], !shot.isEmpty {
            let window = items.first(where: { $0.name == name })?.view.window
            items.first { $0.name != name }?.view.show(Array(AppModel.sample.utf8))
            // One pane in each state a smoke does not reach by itself. No hook reports starting.
            for pane in ["shell-3", "shell-4", "shell-5"] { addPane(kind: .shell, host: "", name: pane) }
            show(tab: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.bus.setState("shell-5", .starting)
                self.smokeHooks("shell-3", [["hook_event_name": "UserPromptSubmit"]])
                self.smokeHooks("shell-4", [["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "PermissionRequest"]])
                self.smokeHooks("shell-2", [["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "Stop"]])
                self.failIfSeen()
                self.write(shot: shot, of: window)
                // DOJO_SMOKE_SHOT_PICKER=<file.png>: the picker as well, drawn in the window.
                guard let picker = ProcessInfo.processInfo.environment["DOJO_SMOKE_SHOT_PICKER"], !picker.isEmpty else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Task { await self.endSmoke() } }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.picking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.failIfSeen()
                        self.write(shot: picker, of: window)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Task { await self.endSmoke() } }
                    }
                }
            }
            return
        }
        await endSmoke()
    }

    /// Quits as the app quits, then proves the next launch's offer: the panes outlive the quit, with their
    /// session, and the button brings them back. DOJO_SMOKE_SHOT_EMPTY=<file.png>: the empty window with it.
    private func endSmoke() async {
        let window = items.first?.view.window
        let names = items.map(\.name)
        let local = items.allSatisfy { bus.info($0.name)?.host.isEmpty == true }
        picking = false
        // A made-up id, on a pane that has had a turn.
        if local, let pane = names.first {
            smokeHooks(pane, [["hook_event_name": "UserPromptSubmit", "session_id": "11111111-2222-3333-4444-555555555555"]])
        }
        closeAll()
        if local {
            lastPanes = SavedPanes.load(AppModel.panesFile)
            guard lastPanes.map(\.name) == names, lastPanes.contains(where: { $0.session != nil }) else {
                print("DOJO_SMOKE failed: after quitting, the list holds \(lastPanes.map(\.name)), not \(names), or no session")
                exit(1)
            }
            if let shot = ProcessInfo.processInfo.environment["DOJO_SMOKE_SHOT_EMPTY"], !shot.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
                failIfSeen()
                write(shot: shot, of: window)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            reopenLast()
            guard items.map(\.name) == names, lastPanes.isEmpty, problem.isEmpty else {
                print("DOJO_SMOKE failed: reopening gave \(items.map(\.name)), not \(names); \(problem)")
                exit(1)
            }
            closeAll()
            await smokeFreshHeader(in: window)
        }
        try? FileManager.default.removeItem(at: Headless.state())
        exit(0)
    }

    /// Two reopened agent panes, one with a session to resume: only the other says it started fresh.
    /// DOJO_SMOKE_SHOT_REOPENED=<file.png>: a picture of the two headers.
    private func smokeFreshHeader(in window: NSWindow?) async {
        addPane(kind: .claude, host: "", name: "resumed", session: "11111111-2222-3333-4444-555555555555", reopened: true)
        addPane(kind: .claude, host: "", name: "fresh", reopened: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let marked = items.filter(\.startedFresh).map(\.name)
        guard items.count == 2, marked == ["fresh"] else {
            print("DOJO_SMOKE failed: of \(items.map(\.name)) the header says started fresh on \(marked), not on fresh alone")
            exit(1)
        }
        if let shot = ProcessInfo.processInfo.environment["DOJO_SMOKE_SHOT_REOPENED"], !shot.isEmpty {
            failIfSeen()
            write(shot: shot, of: window)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        closeAll()
    }

    /// The sixteen terminal colours, one to a line, and a relayed message, for the smoke's picture.
    private static let sample = "[from: shell-1] a relayed message\r\n" + ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"].enumerated().map { i, colour in
        "\u{1b}[\(30 + i)m\(colour) MMMM\u{1b}[0m  \u{1b}[\(90 + i)mbright \(colour) MMMM\u{1b}[0m\r\n"
    }.joined() + "regular MMMM  \u{1b}[1mbold MMMM\u{1b}[0m  \u{1b}[3mitalic MMMM\u{1b}[0m  \u{1b}[2mdim MMMM\u{1b}[0m\r\n"

    /// Writes a window to a PNG, for the smoke's pictures: the window server's own image of it, title bar
    /// included, because the panes draw on the GPU and a view's cached drawing leaves them blank. An app
    /// needs no permission for its own windows. The window stays parked, and is only made opaque for this.
    private func write(shot: String, of window: NSWindow?) {
        guard let window else {
            print("DOJO_SMOKE shot failed: no window for \(shot)")
            exit(1)
        }
        window.alphaValue = 1
        for item in items { item.view.drawMetalFrameNow() }
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: shot))) != nil else {
                print("DOJO_SMOKE shot failed: the window server gave no picture for \(shot)")
                exit(1)
            }
            print("DOJO_SMOKE shot: \(shot) \(image.width)x\(image.height)")
        }
    }

    static let hostsFile = Headless.state().appendingPathComponent("hosts")
    static let foldersFile = Headless.state().appendingPathComponent("folders")
    static let panesFile = Headless.state().appendingPathComponent("panes.json")
    static let unrestrictedFile = Headless.state().appendingPathComponent("unrestricted")

    /// The picker opened a pane of `kind` with the tick as given: the next one starts the same way.
    func rememberTick(_ kind: HarnessKind, _ ticked: Bool) {
        unrestrictedKinds = Permissions.remember(kind, ticked: ticked, in: AppModel.unrestrictedFile)
    }
    static let relayFile = Headless.state().appendingPathComponent("relay")

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
