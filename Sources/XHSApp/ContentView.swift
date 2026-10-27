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
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(.red)
            }
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Text("No terminals yet").font(.title3)
                    Text("Press + to add Claude, Codex or pi, here or on another machine.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneGrid(items: model.items)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.picking = true } label: { Image(systemName: "plus") }
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
        .background(Color(nsColor: .separatorColor))
    }
}

struct PaneCell: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.Item

    var body: some View {
        let info = model.bus.info(item.id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color(info?.state)).frame(width: 9, height: 9)
                Text(item.id).font(.system(.callout, design: .monospaced)).bold()
                Text(info?.kind.title ?? "").foregroundStyle(.secondary)
                Text(info?.host.isEmpty == false ? info!.host : "local").foregroundStyle(.secondary)
                if let m = info?.model, !m.isEmpty {
                    Text(m).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let q = info?.queued, q > 0 {
                    Text("\(q) queued").font(.caption).foregroundStyle(.orange)
                }
                Text(info?.state.rawValue ?? "").font(.caption).foregroundStyle(color(info?.state))
                Button { model.close(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close \(item.id)")
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
            TerminalHost(view: item.view)
        }
    }

    private func color(_ state: PaneState?) -> Color {
        switch state {
        case .idle: return .green
        case .running: return .blue
        case .prompt: return .orange
        case .exited: return .red
        case .starting, .none: return .gray
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
    @Published var error = ""
}

struct PickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var form = PickerForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New terminal").font(.headline)
            HStack(spacing: 10) {
                ForEach(HarnessKind.pickable, id: \.self) { kind in
                    Button { add(kind) } label: { Text(kind.title).frame(maxWidth: .infinity) }
                        .controlSize(.large)
                }
            }
            TextField("Host (empty for this Mac)", text: $form.host)
            TextField("Name (empty for claude-1, codex-1, pi-1 ...)", text: $form.name)
            if !form.error.isEmpty {
                Text(form.error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.picking = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func add(_ kind: HarnessKind) {
        if let problem = model.addPane(kind: kind, host: form.host, name: form.name) {
            form.error = problem
        } else {
            model.picking = false
        }
    }
}
