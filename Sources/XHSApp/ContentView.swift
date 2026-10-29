import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XHSCore

// No @State here: in this SDK @State is a macro whose plugin ships only with Xcode.
// View state lives in ObservableObjects, which build with the Command Line Tools.

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.problem.isEmpty {
                Text(model.problem)
                    .font(.callout)
                    .foregroundStyle(Color(Theme.ink))
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(Color(Theme.coral))
            }
            // Agents fill the grid; Runner, the local model server, lives in a strip along the bottom.
            let agents = model.items.filter { $0.kind != .runner }
            if agents.isEmpty {
                VStack(spacing: 14) {
                    EnsoMark().frame(width: 96, height: 96)
                    Wordmark(size: 26)
                    Text("Dojo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(Theme.muted))
                    Text("Press + to add Claude, Codex or pi, here or on another machine.")
                        .font(.callout)
                        .foregroundStyle(Color(Theme.muted))
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneGrid(items: agents)
            }
            if let runner = model.items.first(where: { $0.kind == .runner }) {
                RunnerStrip(item: runner)
            }
        }
        .background(Paper())
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.picking = true } label: { Image(systemName: "plus") }
                    .foregroundStyle(Color(Theme.teal))
                    .help("Add a terminal")
                    .keyboardShortcut("t", modifiers: .command)
            }
        }
        .sheet(isPresented: $model.picking) {
            PickerSheet().environmentObject(model)
        }
    }
}

/// The local model server along the bottom of the window: one line with its state, a chevron that opens
/// its log above the line (open while it starts, closed once it serves) and a close button that stops it.
struct RunnerStrip: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.Item

    var body: some View {
        let info = model.bus.info(item.name)
        VStack(spacing: 0) {
            if model.runnerLogOpen {
                Rectangle().fill(Color(Theme.line)).frame(height: 1)
                TerminalHost(view: item.view).frame(height: 240)
            }
            Rectangle().fill(Color(Theme.line)).frame(height: 1)
            HStack(spacing: 8) {
                EnsoMark().frame(width: 14, height: 14)
                Text("Runner").bold().foregroundStyle(Color(Theme.ink))
                // The phase in capitals and colour, a spinner while it loads: serving must read at a glance.
                let phase = RunnerStrip.phase(info)
                if info?.state == .starting { ProgressView().controlSize(.small) }
                Text(phase.word).font(.system(.caption, design: .rounded)).bold().tracking(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(phase.color).opacity(0.18), in: Capsule())
                    .foregroundStyle(Color(phase.color))
                Text(RunnerStrip.status(info)).foregroundStyle(Color(info?.state == .exited ? Theme.coralInk : Theme.muted))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: model.runnerLogOpen ? "chevron.down" : "chevron.up")
                    .foregroundStyle(Color(Theme.muted))
                    .help(model.runnerLogOpen ? "Hide Runner's log" : "Show Runner's log")
                Button { model.close(item.name) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(Theme.muted))
                    .help("Stop Runner")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Paper(tone: Theme.surface, density: 0.6))
            .contentShape(Rectangle())
            .onTapGesture { model.runnerLogOpen.toggle() }
        }
        .onAppear { model.runnerLogOpen = info?.state != .running }
        .onChange(of: info?.state) { _, state in if state == .running { model.runnerLogOpen = false } }
    }

    /// The phase word and its colour: coral while loading, teal once serving, coral-ink when stopped.
    static func phase(_ info: Bus.Info?) -> (word: String, color: NSColor) {
        switch info?.state {
        case .running: return ("SERVING", Theme.tealInk)
        case .exited: return ("STOPPED", Theme.coralInk)
        default: return ("LOADING", Theme.coral)
        }
    }

    /// One phrase after the phase: what is being picked or fetched, what is served, or where to look.
    static func status(_ info: Bus.Info?) -> String {
        guard let info else { return "" }
        switch info.state {
        case .running: return info.model.isEmpty ? "on 127.0.0.1:8080" : "\(info.model) on 127.0.0.1:8080"
        case .exited: return "open the log to see why"
        default: return info.model.isEmpty ? "picking a model that fits this Mac" : info.model.replacingOccurrences(of: "fetching ", with: "fetching and loading ")
        }
    }
}

/// Panes in a near-square grid.
struct PaneGrid: View {
    let items: [AppModel.Item]

    var body: some View {
        let columns = max(1, Int(Double(items.count).squareRoot().rounded(.up)))
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(spacing: 1) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 1) {
                    ForEach(rows[r]) { item in
                        PaneCell(item: item)
                    }
                }
            }
        }
        .background(Color(Theme.line))
    }
}

/// The name field while a pane is being renamed.
final class RenameForm: ObservableObject {
    @Published var editing = false
    @Published var draft = ""
    @Published var error = ""
}

struct PaneCell: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var rename = RenameForm()
    let item: AppModel.Item

    var body: some View {
        let info = model.bus.info(item.name)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(state: info?.state)
                if rename.editing {
                    TextField("name", text: $rename.draft)
                        .font(.system(.callout, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .onSubmit { commitRename() }
                        .onExitCommand { rename.editing = false }
                    if !rename.error.isEmpty {
                        Text(rename.error).font(.caption).foregroundStyle(Color(Theme.coralInk))
                    }
                } else {
                    Text(item.name).font(.system(.callout, design: .monospaced)).bold().foregroundStyle(Color(Theme.ink))
                        .help("Double-click to rename")
                        .onTapGesture(count: 2) { startRename() }
                        .contextMenu { Button("Rename") { startRename() } }
                }
                Text(info?.kind.title ?? "").foregroundStyle(Color(Theme.muted))
                Text(info?.host.isEmpty == false ? info!.host : "local").foregroundStyle(Color(Theme.muted))
                if !item.directory.isEmpty {
                    Text((item.directory as NSString).lastPathComponent).foregroundStyle(Color(Theme.muted))
                        .lineLimit(1).truncationMode(.middle).help(item.directory)
                }
                if let m = info?.model, !m.isEmpty {
                    Text(m).foregroundStyle(Color(Theme.muted)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let q = info?.queued, q > 0 {
                    Text(info?.draft == true ? "\(q) queued, unsent text here" : "\(q) queued")
                        .font(.caption).foregroundStyle(Color(Theme.coralInk))
                }
                Text(info?.state.rawValue ?? "").font(.caption).foregroundStyle(PaneCell.color(info?.state))
                Button { model.close(item.name) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(Theme.muted))
                    .help("Close \(item.name)")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Paper(tone: Theme.surface, density: 0.6))
            // Drag a header onto another pane and the two swap places.
            .onDrag { NSItemProvider(object: item.name as NSString) }
            TerminalHost(view: item.view)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let dragged = object as? String else { return }
                DispatchQueue.main.async { model.swap(dragged, with: item.name) }
            }
            return true
        }
    }

    private func startRename() {
        rename.draft = item.name
        rename.error = ""
        rename.editing = true
    }

    private func commitRename() {
        if let problem = model.rename(item.name, to: rename.draft) {
            rename.error = problem
        } else {
            rename.editing = false
            DispatchQueue.main.async { item.view.window?.makeFirstResponder(item.view) }
        }
    }

    /// The brand's three accents carry the states: teal idle, blue running, coral at a prompt.
    static func color(_ state: PaneState?) -> Color {
        switch state {
        case .idle: return Color(Theme.tealInk)
        case .running: return Color(Theme.blue)
        case .prompt: return Color(Theme.coral)
        case .exited: return Color(Theme.coralInk)
        case .starting, .none: return Color(Theme.muted)
        }
    }
}

/// A filled dot for a live state, a ring while starting, a hollow ring when exited.
struct StateDot: View {
    let state: PaneState?

    var body: some View {
        let color = PaneCell.color(state)
        ZStack {
            Circle().stroke(color, lineWidth: 1.5).frame(width: 9, height: 9)
            if state == .idle || state == .running || state == .prompt {
                Circle().fill(color).frame(width: 9, height: 9)
            }
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let view: TerminalPane
    func makeNSView(context: Context) -> TerminalPane { view }
    func updateNSView(_ nsView: TerminalPane, context: Context) {}
}

/// The plus button's picker: Claude, Codex or pi, an optional host and an optional name.
final class PickerForm: ObservableObject {
    @Published var host = ""
    @Published var name = ""
    @Published var folder = ""
    @Published var error = ""
}

struct PickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = PickerForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                EnsoMark().frame(width: 22, height: 22)
                Text("New terminal").font(.headline).foregroundStyle(Color(Theme.ink))
            }
            // The coding agents, with where they run: a host, a folder, a name.
            Text("Coding agent").foregroundStyle(.secondary).font(.callout)
            HStack(spacing: 10) {
                ForEach(HarnessKind.pickable, id: \.self) { kind in
                    Button { add(kind) } label: { Text(kind.title).frame(maxWidth: .infinity) }
                        .controlSize(.large)
                        .tint(Color(Theme.teal))
                }
            }
            TextField("Host (empty for this Mac)", text: $form.host)
            if !model.recentHosts.isEmpty {
                HStack(spacing: 6) {
                    Text("Recent").foregroundStyle(.secondary)
                    ForEach(model.recentHosts, id: \.self) { host in
                        Button(host) { form.host = host }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Color(Theme.teal))
                    }
                }
                .font(.callout)
                .lineLimit(1)
            }
            let remote = !form.host.trimmingCharacters(in: .whitespaces).isEmpty
            HStack(spacing: 6) {
                TextField(remote ? "Folder on that host (empty for its home folder)" : "Folder (empty for your home folder)",
                          text: $form.folder)
                // The folder panel and the recent folders are this Mac's; on a host, type the path as it is there.
                Button("Choose") { if let path = AppModel.chooseFolder() { form.folder = path } }
                    .tint(Color(Theme.teal))
                    .disabled(remote)
            }
            if !model.recentFolders.isEmpty, !remote {
                HStack(spacing: 6) {
                    Text("Recent").foregroundStyle(.secondary)
                    ForEach(model.recentFolders, id: \.self) { folder in
                        Button((folder as NSString).lastPathComponent) { form.folder = folder }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Color(Theme.teal))
                            .help(folder)
                    }
                }
                .font(.callout)
                .lineLimit(1)
            }
            TextField("Name (empty for claude-1, codex-1, pi-1 ...)", text: $form.name)
            if !form.error.isEmpty {
                Text(form.error).font(.caption).foregroundStyle(Color(Theme.coralInk))
            }
            Divider()
            // The local model server has a section of its own after the agent's fields: a heading, then the button
            // with Runner's state beside it, then what the last Runner pane found to fit this Mac.
            let runnerPane = model.runnerPane
            let runnerUp = !model.runnerModel.isEmpty || runnerPane != nil
            VStack(alignment: .leading, spacing: 6) {
                Text("Local model").foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 10) {
                    Button { add(.runner) } label: { Text(HarnessKind.runner.title) }
                        .controlSize(.large)
                        .tint(Color(Theme.teal))
                        .disabled(runnerPane != nil)
                    Text(runnerStatus(runnerPane))
                        .font(.caption)
                        .foregroundStyle(Color(runnerUp ? Theme.tealInk : Theme.coralInk))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.runnerFits, id: \.spelling) { fit in
                    let current = fit.spelling == model.runnerChoice || (!model.runnerModel.isEmpty && model.runnerModel.contains(fit.stem))
                    // The whole name on the button, the sizes under it: nothing is cut off.
                    VStack(alignment: .leading, spacing: 2) {
                        Button(fit.id) { model.chooseRunnerModel(fit.spelling); model.picking = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(Color(current ? Theme.coral : Theme.teal))
                            .fixedSize()
                        Text("\(fit.resident) GiB resident, \(fit.flags)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 4)
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { model.picking = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Paper(tone: Theme.surface, density: 0.6))
        .onAppear { model.refreshRunner() }
    }

    /// One line on Runner: starting in a pane, serving (in a pane or started outside), or not running.
    private func runnerStatus(_ pane: Bus.Info?) -> String {
        if let pane, pane.state != .running {
            let what = pane.model.isEmpty ? "picking a model that fits" : pane.model
            return "Runner is starting in \(pane.name): \(what). Follow it there; pi panes can use it once it listens."
        }
        if !model.runnerModel.isEmpty {
            let whereFrom = pane.map { " in \($0.name)" } ?? " (started outside the app)"
            return "Runner is serving \(model.runnerModel)\(whereFrom) for the pi panes."
        }
        if let pane { return "Runner is up in \(pane.name), waiting for it to answer." }
        return "Runner is not running. A Runner pane fetches it if needed, picks a model that fits this Mac and serves it; pi panes use it."
    }

    private func add(_ kind: HarnessKind) {
        if let problem = model.addPane(kind: kind, host: form.host, name: form.name, directory: form.folder) {
            form.error = problem
        } else {
            model.picking = false
        }
    }
}
