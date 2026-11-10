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
            let agents = model.agents
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
                    if !model.lastPanes.isEmpty {
                        Button("Reopen the last panes (\(model.lastPanes.count))") { model.reopenLast() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The overview tab is the grid; every pane has a tab of its own that fills the window.
                TabStrip(agents: agents)
                if let selected = agents.first(where: { $0.id == model.selectedTab }) {
                    PaneCell(item: selected).id(selected.id)
                } else {
                    PaneGrid(items: agents)
                }
            }
            // One strip per Runner pane: this Mac's, and one per host that runs one (D12). Each has its own
            // identity, so a replacement Runner gets a fresh strip (and its log open).
            ForEach(model.items.filter { $0.kind == .runner }, id: \.id) { runner in
                RunnerStrip(item: runner).id(runner.id)
            }
        }
        .background(Paper())
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            if #available(macOS 26.0, *) {
                titleItem.sharedBackgroundVisibility(.hidden)
                // Without it the toolbar sets the plus right after the centred title.
                ToolbarSpacer(.flexible)
            } else {
                titleItem
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.picking = true } label: { Image(systemName: "plus") }
                    .foregroundStyle(Color(Theme.tealInk))
                    .help("Add a terminal")
                    .keyboardShortcut("t", modifiers: .command)
            }
        }
        // AppKit pulls a window onto a screen to show a sheet, so a smoke draws the picker in the window.
        .sheet(isPresented: model.smoke ? .constant(false) : $model.picking) {
            PickerSheet().environmentObject(model)
        }
        .overlay {
            if model.smoke, model.picking { PickerSheet().environmentObject(model).background(Color(Theme.surface)) }
        }
    }

    private var titleItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                EnsoMark().frame(width: 20, height: 20).accessibilityHidden(true)
                Text("Xyntetik Dojo")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(Theme.brand))
            }
            .fixedSize()
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
            // The rule parts the strip from the panes; with the log open it sits above the log, and a
            // hairline parts the log from the line below.
            Rectangle().fill(Color(Theme.rule)).frame(height: Theme.ruleWidth)
            if model.runnerLogOpen {
                TerminalHost(view: item.view).frame(height: 240)
                Rectangle().fill(Color(Theme.line)).frame(height: 1)
            }
            HStack(spacing: 8) {
                EnsoMark().frame(width: 14, height: 14)
                Text("Runner").bold().foregroundStyle(Color(Theme.ink))
                // The phase in capitals and colour, a spinner while it loads: serving must read at a glance.
                let phase = RunnerStrip.phase(info?.state)
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
                if model.canReopen(item) {
                    Button("Reopen") { model.reopen(item) }.controlSize(.small).help("Connect again and resume this session")
                }
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

    /// The phase word and its colour: coral-ink while loading and when stopped, teal once serving.
    static func phase(_ state: PaneState?) -> (word: String, color: NSColor) {
        switch state {
        case .running: return ("SERVING", Theme.tealInk)
        case .exited: return ("STOPPED", Theme.coralInk)
        default: return ("LOADING", Theme.coralInk)
        }
    }

    /// One phrase after the phase: what is being picked or fetched, what is served, or where to look.
    static func status(_ info: Bus.Info?) -> String {
        guard let info else { return "" }
        switch info.state {
        case .running:
            let place = info.host.isEmpty ? "127.0.0.1:8080" : info.host
            return info.model.isEmpty ? "on \(place)" : "\(info.model) on \(place)"
        case .exited: return "open the log to see why"
        default: return info.model.isEmpty ? "picking a model that fits \(info.host.isEmpty ? "this Mac" : info.host)"
                                           : info.model.replacingOccurrences(of: "fetching ", with: "fetching and loading ")
        }
    }
}

/// The tabs above the panes: All (the grid, with the pane count) and one per pane with its state dot and name.
struct TabStrip: View {
    @EnvironmentObject private var model: AppModel
    let agents: [AppModel.Item]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                TabButton(selected: model.selectedTab == nil, action: { model.show(tab: nil) }) {
                    EnsoMark().frame(width: 12, height: 12)
                    Text("All").bold()
                    Text("\(agents.count)").foregroundStyle(Color(Theme.muted))
                    if model.waiting > 0 {
                        Text("\(model.waiting)").bold().foregroundStyle(Color(Theme.ink))
                            .padding(.horizontal, 6).background(Capsule().fill(Color(Theme.coral)))
                            .help("Panes waiting for you")
                    }
                }
                ForEach(agents) { item in
                    let selected = model.selectedTab == item.id
                    TabButton(selected: selected, action: { model.show(tab: item.id) }) {
                        StateDot(state: model.bus.info(item.name)?.state)
                        Text(item.name).font(.system(.callout, design: .monospaced)).fontWeight(selected ? .bold : .regular)
                        if model.finishedUnseen(item) { UnseenMark() }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .font(.callout)
        .background(Paper(tone: Theme.bg, density: 0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Theme.rule)).frame(height: Theme.ruleWidth) }
    }
}

/// Whether the pointer is over a tab. An object, not @State: see the note at the top of the file.
final class HoverFlag: ObservableObject {
    @Published var on = false
}

/// A tab as a button: a rounded sheet with a hairline edge, the selected one lifted on the lightest paper
/// in ink with a teal line along its foot, the others muted on the surface and brighter under the pointer.
struct TabButton<Content: View>: View {
    @StateObject private var hover = HoverFlag()
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        HStack(spacing: 6, content: content)
            .foregroundStyle(Color(selected ? Theme.ink : Theme.muted))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(shape.fill(Color(selected ? Theme.paper : hover.on ? Theme.surface : Theme.bg)))
            .overlay(shape.stroke(Color(selected ? Theme.rule : Theme.line), lineWidth: 1))
            .overlay(alignment: .bottom) {
                Capsule().fill(Color(selected ? Theme.teal : .clear)).frame(height: 2).padding(.horizontal, 8).padding(.bottom, 1)
            }
            .shadow(color: Color(Theme.ink).opacity(selected ? 0.12 : 0), radius: 1.5, y: 1)
            .contentShape(shape)
            .onHover { hover.on = $0 }
            .onTapGesture(perform: action)
    }
}

/// Panes in a near-square grid.
struct PaneGrid: View {
    let items: [AppModel.Item]

    var body: some View {
        let columns = max(1, Int(Double(items.count).squareRoot().rounded(.up)))
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        VStack(spacing: Theme.ruleWidth) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: Theme.ruleWidth) {
                    ForEach(rows[r]) { item in
                        PaneCell(item: item)
                    }
                }
            }
        }
        .background(Color(Theme.rule))
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
                if Permissions.unrestricted(item.kind, ticked: item.unrestricted) {
                    // D21.1: a pane that acts without the harness asking first says so
                    Text("unrestricted").foregroundStyle(Color(Theme.coralInk)).fixedSize()
                        .help(item.kind == .pi ? "pi has no permission prompts: it runs its tools without asking"
                                               : "Opened with Skip permission prompts: the agent acts without asking first")
                }
                if item.startedFresh {
                    Text("started fresh").foregroundStyle(Color(Theme.coralInk)).fixedSize()
                        .help("There was no session to resume, so this pane started a new conversation")
                }
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
                if model.finishedUnseen(item) { UnseenMark() }
                Text(model.finishedUnseen(item) ? "finished" : info?.state.rawValue ?? "").font(.caption).foregroundStyle(Color(PaneCell.tone(info?.state)))
                Button { model.close(item.name) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(Theme.muted))
                    .help("Close \(item.name)")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // The pane with the keys looks like the selected tab: the lightest paper, a teal line along its foot.
            .background(Paper(tone: model.focusedPane == item.id ? Theme.paper : Theme.surface, density: 0.6))
            .overlay(alignment: .bottom) {
                let focused = model.focusedPane == item.id
                Rectangle().fill(Color(focused ? Theme.teal : Theme.line)).frame(height: focused ? Theme.ruleWidth : 1)
            }
            // Drag a header onto another pane and the two swap places.
            .onDrag { NSItemProvider(object: item.name as NSString) }
            TerminalHost(view: item.view)
        }
        // Coral around the whole pane while it waits for the owner.
        .overlay {
            if info?.state == .prompt {
                Rectangle().strokeBorder(Color(Theme.coral), lineWidth: 3).allowsHitTesting(false)
            }
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

    /// The state word: the brand's three accents, in the tones that read as text.
    static func tone(_ state: PaneState?) -> NSColor {
        switch state {
        case .idle: return Theme.tealInk
        case .running: return Theme.blue
        case .prompt, .exited: return Theme.coralInk
        case .starting, .none: return Theme.muted
        }
    }

    /// The state dot: teal idle, blue running, coral at a prompt. A fill, so it keeps the brighter tones.
    static func fill(_ state: PaneState?) -> NSColor {
        switch state {
        case .idle: return Theme.stateIdle
        case .running: return Theme.stateRunning
        case .prompt: return Theme.coral
        case .exited: return Theme.stateExited
        case .starting, .none: return Theme.muted
        }
    }
}

/// The state as a shape, so it reads without the colour: a dot idle, a triangle running, a mark on a coral
/// disc at a prompt, a dashed ring while starting, a hollow ring when exited. The pointer names it.
struct StateDot: View {
    let state: PaneState?

    var body: some View {
        let color = Color(PaneCell.fill(state))
        Group {
            switch state {
            case .idle:
                Circle().fill(color).frame(width: 9, height: 9)
            case .running:
                Triangle().fill(color).frame(width: 9, height: 10)
            case .prompt:
                ZStack {
                    Circle().fill(color)
                    Text("!").font(.system(size: 10, weight: .black)).foregroundStyle(Color(Theme.ink))
                }
                .frame(width: 12, height: 12)
            case .exited:
                Circle().stroke(color, lineWidth: 1.5).frame(width: 9, height: 9)
            case .starting, .none:
                Circle().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 9, height: 9)
            }
        }
        .frame(width: 12, height: 12)
        .help(state?.rawValue ?? "")
    }
}

/// A turn that finished and has not been viewed.
struct UnseenMark: View {
    var body: some View {
        Circle().fill(Color(Theme.tealInk)).frame(width: 6, height: 6).help("Finished, not yet seen")
    }
}

/// A triangle pointing right, as on a play button.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
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
    /// The agent chosen in the segmented control; Open starts it.
    @Published var kind: HarnessKind = .claude
    /// "Skip permission prompts" (D21.1): the agent acts without asking. Unticked on a fresh install; the
    /// picker starts each harness with the tick the owner last opened it with.
    @Published var unrestricted = false
    @Published var host = ""
    @Published var name = ""
    @Published var folder = ""
    @Published var error = ""
}

/// A section of the picker: a rounded sheet of the lightest paper with a hairline edge, as System Settings
/// groups its rows.
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color(Theme.paper)))
            .overlay(shape.stroke(Color(Theme.line), lineWidth: 1))
    }
}

/// A field with the values used before behind a clock at its right edge (hosts, folders): typed once.
struct RecentField: View {
    let prompt: String
    @Binding var text: String
    let recents: [String]
    var shown: (String) -> String = { $0 }

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if !recents.isEmpty {
                    Menu {
                        ForEach(recents, id: \.self) { value in Button(shown(value)) { text = value } }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color(Theme.muted))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.trailing, 4)
                    .help("Used before")
                }
            }
    }
}

struct PickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = PickerForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                EnsoMark().frame(width: 22, height: 22)
                Text("New terminal").font(.headline).foregroundStyle(Color(Theme.ink))
            }
            // The coding agent and where it runs, with Open and Cancel in the same card: they act on this, not on Runner.
            Card {
                Picker("Coding agent", selection: $form.kind) {
                    ForEach(HarnessKind.pickable, id: \.self) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                let remote = !form.host.trimmingCharacters(in: .whitespaces).isEmpty
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        label("Host")
                        RecentField(prompt: "This Mac", text: $form.host, recents: model.recentHosts)
                    }
                    GridRow {
                        label("Folder")
                        HStack(spacing: 6) {
                            // The folder panel and the recent folders are this Mac's; on a host, type the path as it is there.
                            RecentField(prompt: remote ? "Its home folder on that host" : "Your home folder", text: $form.folder,
                                        recents: remote ? [] : model.recentFolders, shown: { ($0 as NSString).lastPathComponent })
                            Button("Choose") { if let path = AppModel.chooseFolder() { form.folder = path } }
                                .disabled(remote)
                        }
                    }
                    GridRow {
                        label("Name")
                        TextField("\(form.kind.rawValue)-1", text: $form.name).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes(.vertical)
                        // pi has no prompts to skip: the box shows how it runs and cannot be changed
                        Toggle("Skip permission prompts",
                               isOn: Permissions.canAsk(form.kind) ? $form.unrestricted : .constant(true))
                            .toggleStyle(.checkbox)
                            .disabled(!Permissions.canAsk(form.kind))
                    }
                }
                // what the tickbox does, in plain words; below the grid, where wrapped text measures right
                Text(PickerSheet.permissionNote(form.kind))
                    .font(.caption).foregroundStyle(Color(Theme.muted))
                    .fixedSize(horizontal: false, vertical: true)
                if !form.error.isEmpty {
                    Text(form.error).font(.caption).foregroundStyle(Color(Theme.coralInk))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.picking = false }.keyboardShortcut(.cancelAction)
                    Button("Open") { add(form.kind) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(Theme.tealInk))
                        .keyboardShortcut(.defaultAction)
                }
            }
            // The local model server: its state, a button to start it, and a popup for the model it serves.
            let runnerPane = model.runnerPane
            Card {
                Text("Local model").font(.headline).foregroundStyle(Color(Theme.ink))
                Text(runnerStatus(runnerPane))
                    .font(.callout)
                    .foregroundStyle(Color(model.foreignServer || runnerPane?.state == .exited ? Theme.coralInk : Theme.muted))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    // With a host in the form, the button starts Runner there (D12); the card is about this Mac.
                    let host = form.host.trimmingCharacters(in: .whitespaces)
                    if host.isEmpty {
                        Button(runnerPane == nil && model.runnerModel.isEmpty ? "Start Runner" : "Runner") { add(.runner) }
                            .disabled(runnerPane != nil || model.foreignServer)
                    } else {
                        Button("Start Runner on \(host)") { add(.runner) }
                            .disabled(model.runnerPane(host: host) != nil)
                    }
                    if !model.runnerFits.isEmpty {
                        Text("Serve").foregroundStyle(Color(Theme.muted))
                        // Picking another model replaces the Runner pane with one serving it.
                        Picker("Serve", selection: Binding(get: { chosenSpelling }, set: { model.chooseRunnerModel($0); model.picking = false })) {
                            ForEach(model.runnerFits, id: \.spelling) { fit in
                                Text("\(fit.id)  \(fit.resident) GiB").tag(fit.spelling)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                    }
                }
                if let fit = model.runnerFits.first(where: { $0.spelling == chosenSpelling }) {
                    Text("\(fit.resident) GiB resident, \(fit.flags)")
                        .font(.caption)
                        .foregroundStyle(Color(Theme.muted))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 540)
        .background(Paper(tone: Theme.surface, density: 0.6))
        .onAppear {
            model.refreshRunner()
            form.unrestricted = model.unrestrictedKinds.contains(form.kind)
        }
        // each agent starts with the tick it was last opened with (D21.1)
        .onChange(of: form.kind) { _, kind in form.unrestricted = model.unrestrictedKinds.contains(kind) }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(Color(Theme.muted)).gridColumnAlignment(.trailing)
    }

    /// The popup's selection: the model chosen for Runner, else the one serving, else the largest that fits.
    private var chosenSpelling: String {
        let fits = model.runnerFits
        if fits.contains(where: { $0.spelling == model.runnerChoice }) { return model.runnerChoice }
        if !model.runnerModel.isEmpty, let serving = fits.first(where: { model.runnerModel.contains($0.stem) }) { return serving.spelling }
        return fits.first?.spelling ?? ""
    }

    /// One line on Runner: starting in a pane, serving (in a pane or started outside), or not running.
    private func runnerStatus(_ pane: Bus.Info?) -> String {
        if let pane, pane.state == .exited {
            return "Runner stopped in \(pane.name); its log says why."
        }
        if let pane, pane.state != .running {
            let what = pane.model.isEmpty ? "picking a model that fits" : pane.model
            return "Starting in \(pane.name): \(what). pi panes can use it once it listens."
        }
        if model.foreignServer {
            return "\(model.servedBy) is serving \(model.runnerModel) on 127.0.0.1:8080, started outside the app; pi panes use it as it is. Stop it to let Runner serve."
        }
        if !model.runnerModel.isEmpty {
            let whereFrom = pane.map { " in \($0.name)" } ?? ", started outside the app"
            return "Serving \(model.runnerModel)\(whereFrom), for the pi panes."
        }
        if let pane { return "Up in \(pane.name), waiting for it to answer." }
        return "Not running. A Runner pane fetches Runner if needed and serves a model that fits this Mac, for the pi panes."
    }

    private func add(_ kind: HarnessKind) {
        let ticked = Permissions.canAsk(kind) && form.unrestricted
        if let problem = model.addPane(kind: kind, host: form.host, name: form.name, directory: form.folder, unrestricted: ticked) {
            form.error = problem
        } else {
            if Permissions.canAsk(kind) { model.rememberTick(kind, ticked) }
            model.picking = false
        }
    }

    /// What the tickbox does, in plain words, for the agent chosen.
    static func permissionNote(_ kind: HarnessKind) -> String {
        switch kind {
        case .claude:
            return "Unticked, Claude asks before it runs a command or edits a file. Ticked, it acts without asking. "
                + "Remembered for Claude."
        case .codex:
            return "Unticked, Codex keeps its approvals and its sandbox. Ticked, it acts without asking, outside the "
                + "sandbox. Remembered for Codex."
        case .pi:
            return "pi has no permission prompts: it runs its tools without asking, ticked or not."
        case .runner, .shell:
            return ""
        }
    }
}
