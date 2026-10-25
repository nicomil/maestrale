import MacCleanerCore
import MacCleanerModules
import SwiftUI

/// Interactive map of what takes space: treemap on the left, list on the right.
struct SpaceLensView: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: URL?
    @State private var confirmTrash = false

    private var lens: SpaceLensModel { model.spaceLens }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let current = lens.current {
                breadcrumb
                HSplitView {
                    TreemapView(node: current, hovered: $hovered) { lens.open($0) }
                        .frame(minWidth: 260)
                    childrenList(current).frame(minWidth: 240, idealWidth: 320)
                }
                Divider()
                footer
            } else if lens.isScanning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("\(lens.scannedFiles) file · \(formatBytes(lens.scannedBytes))")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button("Annulla") { lens.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Space Lens", systemImage: "circle.hexagongrid")
                } description: {
                    Text("Guarda cosa occupa spazio, cartella per cartella.")
                } actions: {
                    Button("Analizza la cartella Inizio") {
                        lens.scan(FileManager.default.homeDirectoryForCurrentUser)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Space Lens")
    }

    private var toolbar: some View {
        HStack {
            if let root = lens.root {
                Text("\(formatBytes(root.size)) in \(root.fileCount) file").font(.title2.bold())
            }
            Spacer()
            Button("Scegli cartella…") { chooseFolder() }
            Button("Cartella Inizio") { lens.scan(FileManager.default.homeDirectoryForCurrentUser) }
                .disabled(lens.isScanning)
        }
        .padding()
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let root = lens.root {
                    Button(root.name) { lens.goUp(to: nil) }.buttonStyle(.link)
                }
                ForEach(Array(lens.path.enumerated()), id: \.element.id) { index, node in
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Button(node.name) { lens.goUp(to: index) }.buttonStyle(.link)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func childrenList(_ node: DiskNode) -> some View {
        @Bindable var lens = lens
        return List(node.children, selection: $lens.selection) { child in
            HStack {
                Image(systemName: child.isAggregate ? "doc.on.doc" : child.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(child.isDirectory ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name).lineLimit(1)
                    ProgressView(value: Double(child.size), total: Double(max(node.size, 1)))
                        .progressViewStyle(.linear).tint(color(for: child, in: node))
                }
                Spacer()
                Text(formatBytes(child.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .tag(child.url)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { lens.open(child) }
            .listRowBackground(hovered == child.url ? Color.accentColor.opacity(0.12) : nil)
            .contextMenu {
                if child.isDirectory { Button("Apri") { lens.open(child) } }
                if !child.isAggregate {
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([child.url]) }
                }
            }
            .selectionDisabled(child.isAggregate)
        }
    }

    private var footer: some View {
        @Bindable var model = model
        let selected = lens.selectedNodes()
        let size = selected.reduce(Int64(0)) { $0 + $1.size }
        return HStack {
            RemovalModePicker(mode: $model.removalMode)
            if let summary = lens.lastCleanSummary { Text(summary).foregroundStyle(.secondary) }
            Spacer()
            Text("Doppio clic per entrare in una cartella").font(.caption).foregroundStyle(.tertiary)
            Button("Rimuovi \(formatBytes(size))") { confirmTrash = true }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
                .confirmationDialog("Rimuovere \(selected.count) elementi?", isPresented: $confirmTrash) {
                    Button(model.removalMode == .delete ? "Elimina definitivamente" : "Rimuovi",
                           role: model.removalMode == .delete ? .destructive : nil) {
                        Task { await lens.trashSelected(mode: model.removalMode) }
                    }
                } message: {
                    Text(model.removalMode.confirmation)
                }
        }
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { lens.scan(url) }
    }
}

/// Palette for the map: one hue per top-level child, folders more saturated.
func color(for child: DiskNode, in parent: DiskNode) -> Color {
    if child.isAggregate { return .gray.opacity(0.5) }
    let index = parent.children.firstIndex { $0.id == child.id } ?? 0
    let hues: [Double] = [0.58, 0.08, 0.33, 0.83, 0.13, 0.5, 0.95, 0.70, 0.25, 0.04]
    return Color(hue: hues[index % hues.count], saturation: child.isDirectory ? 0.55 : 0.3,
                 brightness: child.isDirectory ? 0.85 : 0.75)
}

/// Squarified treemap of the children of a node. Click a folder to open it.
struct TreemapView: View {
    let node: DiskNode
    @Binding var hovered: URL?
    let onOpen: (DiskNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let visible = Array(node.children.prefix(150))
            let rects = Treemap.layout(visible.map { Double($0.size) },
                                       in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(visible, rects)), id: \.0.id) { child, rect in
                    tile(child, rect: rect)
                }
            }
        }
        .padding(6)
    }

    private func tile(_ child: DiskNode, rect: CGRect) -> some View {
        let isHovered = hovered == child.url
        return RoundedRectangle(cornerRadius: 4)
            .fill(color(for: child, in: node).opacity(isHovered ? 1 : 0.85))
            .overlay(alignment: .topLeading) {
                if rect.width > 70 && rect.height > 34 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(child.name).font(.caption.bold()).lineLimit(1)
                        Text(formatBytes(child.size)).font(.caption2)
                    }
                    .foregroundStyle(.black.opacity(0.75))
                    .padding(5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(isHovered ? 0.9 : 0.25), lineWidth: 1))
            .frame(width: max(rect.width - 2, 0), height: max(rect.height - 2, 0))
            .offset(x: rect.minX + 1, y: rect.minY + 1)
            .onHover { inside in hovered = inside ? child.url : (hovered == child.url ? nil : hovered) }
            .onTapGesture { onOpen(child) }
            .help("\(child.name) — \(formatBytes(child.size))")
    }
}
