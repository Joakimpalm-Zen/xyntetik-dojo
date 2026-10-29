import AppKit
import SwiftUI
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
            if model.items.isEmpty {
                VStack(spacing: 14) {
                    EnsoMark().frame(width: 96, height: 96)
                    Wordmark(size: 26)
                    Text("Harness Supervisor")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(Theme.muted))
                    Text("Press + to add Claude, Codex or pi, here or on another machine.")
                        .font(.callout)
                        .foregroundStyle(Color(Theme.muted))
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneGrid(items: model.items)
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

struct PaneCell: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.Item

    var body: some View {
        let info = model.bus.info(item.id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StateDot(state: info?.state)
                Text(item.id).font(.system(.callout, design: .monospaced)).bold().foregroundStyle(Color(Theme.ink))
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
                    Text("\(q) queued").font(.caption).foregroundStyle(Color(Theme.coralInk))
                }
                Text(info?.state.rawValue ?? "").font(.caption).foregroundStyle(PaneCell.color(info?.state))
                Button { model.close(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(Theme.muted))
                    .help("Close \(item.id)")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Paper(tone: Theme.surface, density: 0.6))
            TerminalHost(view: item.view)
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
            HStack {
                Spacer()
                Button("Cancel") { model.picking = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Paper(tone: Theme.surface, density: 0.6))
    }

    private func add(_ kind: HarnessKind) {
        if let problem = model.addPane(kind: kind, host: form.host, name: form.name, directory: form.folder) {
            form.error = problem
        } else {
            model.picking = false
        }
    }
}
