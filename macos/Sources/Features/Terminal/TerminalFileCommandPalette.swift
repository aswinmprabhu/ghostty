import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class TerminalFileCommandPaletteModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var searchText = ""
    @Published private(set) var results: [String] = []
    @Published private(set) var isLoading = false
    @Published var selectedIndex: Int = 0

    private let repositoryRoot: String
    private let onSelect: (String) -> Void
    private let onCancel: () -> Void

    private var allFiles: [String] = []
    private var searchCancellable: AnyCancellable?

    init(
        repositoryRoot: String,
        onSelect: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.repositoryRoot = repositoryRoot
        self.onSelect = onSelect
        self.onCancel = onCancel

        searchCancellable = $searchText
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateResults()
            }

        Task { await loadFiles() }
    }

    private func updateResults() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            results = Array(allFiles.prefix(100))
            selectedIndex = 0
            return
        }

        let files = allFiles
        Task.detached(priority: .userInitiated) { [weak self] in
            var scored: [(index: Int, score: Int)] = []
            scored.reserveCapacity(256)

            for i in 0..<files.count {
                if let score = Self.fuzzyScore(query: query, path: files[i]) {
                    scored.append((i, score))
                }
            }
            scored.sort { $0.score > $1.score }
            let top = scored.prefix(100).map { files[$0.index] }

            await MainActor.run { [weak self] in
                self?.results = top
                self?.selectedIndex = 0
            }
        }
    }

    /// Scores a fuzzy match using UTF-8 bytes for speed. Higher = better. Returns nil if no match.
    nonisolated private static func fuzzyScore(query: String, path: String) -> Int? {
        let pathBytes = Array(path.utf8)
        let lowerBytes = pathBytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
        let queryBytes = Array(query.utf8)

        // Find last slash to identify filename start
        var fileStart = 0
        for i in stride(from: lowerBytes.count - 1, through: 0, by: -1) {
            if lowerBytes[i] == 0x2F { // '/'
                fileStart = i + 1
                break
            }
        }

        // Check if all query chars exist in order
        var positions: [Int] = []
        positions.reserveCapacity(queryBytes.count)
        var searchFrom = 0
        for qb in queryBytes {
            var found = false
            for j in searchFrom..<lowerBytes.count {
                if lowerBytes[j] == qb {
                    positions.append(j)
                    searchFrom = j + 1
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        var score = 0

        // Bonus: exact substring match in filename
        let fileBytes = Array(lowerBytes[fileStart...])
        if containsSubsequence(fileBytes, queryBytes) {
            score += 200
        }

        // Bonus: exact substring match anywhere
        if containsSubsequence(lowerBytes, queryBytes) {
            score += 100
        }

        // Bonus: all match chars are in the filename portion
        if let firstPos = positions.first, firstPos >= fileStart {
            score += 80
        }

        // Bonus: consecutive chars
        var consecutive = 0
        for i in 1..<positions.count {
            if positions[i] == positions[i - 1] + 1 {
                consecutive += 1
            }
        }
        score += consecutive * 10

        // Bonus: matches at word boundaries (after /, _, ., -)
        let boundaries: Set<UInt8> = [0x2F, 0x5F, 0x2E, 0x2D] // / _ . -
        for pos in positions {
            if pos == 0 {
                score += 15
            } else if boundaries.contains(lowerBytes[pos - 1]) {
                score += 15
            }
        }

        // Penalty: match span
        if let first = positions.first, let last = positions.last {
            score -= (last - first)
        }

        // Penalty: longer paths
        score -= pathBytes.count / 10

        return score
    }

    nonisolated private static func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        let limit = haystack.count - needle.count
        outer: for i in 0...limit {
            for j in 0..<needle.count {
                if haystack[i + j] != needle[j] { continue outer }
            }
            return true
        }
        return false
    }

    func loadFiles() async {
        isLoading = true
        defer { isLoading = false }

        let root = repositoryRoot
        let files: [String] = await Task.detached(priority: .userInitiated) {
            guard let gitPath = await TerminalExecutableResolver.shared.resolve(command: "git") else {
                return []
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do { try process.run() } catch { return [] }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(decoding: data, as: UTF8.self)
            return stdout
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }.value

        allFiles = files.sorted()
        results = Array(allFiles.prefix(100))
        selectedIndex = 0
    }

    func selectCurrent() {
        guard !results.isEmpty, selectedIndex >= 0, selectedIndex < results.count else { return }
        onSelect(results[selectedIndex])
    }

    func select(_ path: String) {
        onSelect(path)
    }

    func moveSelection(down: Bool) {
        guard !results.isEmpty else { return }
        if down {
            selectedIndex = min(selectedIndex + 1, results.count - 1)
        } else {
            selectedIndex = max(selectedIndex - 1, 0)
        }
    }

    func cancel() {
        onCancel()
    }
}

struct TerminalFileCommandPalette: View {
    @ObservedObject var model: TerminalFileCommandPaletteModel

    var body: some View {
        VStack(spacing: 0) {
            FileCommandSearchField(
                text: $model.searchText,
                onArrowDown: { model.moveSelection(down: true) },
                onArrowUp: { model.moveSelection(down: false) },
                onReturn: { model.selectCurrent() },
                onEscape: { model.cancel() }
            )
            .padding(12)

            Divider()

            if model.isLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Indexing files…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.results.isEmpty {
                Text(model.searchText.isEmpty ? "No files found." : "No matching files.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.offset) { index, path in
                                FileCommandRow(
                                    path: path,
                                    isSelected: model.selectedIndex == index
                                )
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.select(path)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selectedIndex) { newValue in
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 560, height: 400)
    }
}

private struct FileCommandRow: View {
    let path: String
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForFile(path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.body.monospaced().weight(.medium))
                    .lineLimit(1)

                if !dirName.isEmpty {
                    Text(dirName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }

    private var fileName: String {
        guard let lastSlash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: lastSlash)...])
    }

    private var dirName: String {
        guard let lastSlash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<lastSlash])
    }

    private func iconForFile(_ path: String) -> String {
        guard let dotIdx = path.lastIndex(of: ".") else { return "doc" }
        let ext = String(path[path.index(after: dotIdx)...]).lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "jsx", "tsx": return "j.square"
        case "json", "yaml", "yml", "toml": return "gearshape"
        case "md", "txt", "rst": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "ico": return "photo"
        default: return "doc"
        }
    }
}

private struct FileCommandSearchField: NSViewRepresentable {
    @Binding var text: String
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FileCommandNSTextField()
        field.placeholderString = "Search files by name…"
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.onArrowDown = onArrowDown
        field.onArrowUp = onArrowUp
        field.onReturn = onReturn
        field.onEscape = onEscape
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if let field = nsView as? FileCommandNSTextField {
            field.onArrowDown = onArrowDown
            field.onArrowUp = onArrowUp
            field.onReturn = onReturn
            field.onEscape = onEscape
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}

private class FileCommandNSTextField: NSTextField {
    var onArrowDown: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 125: // down arrow
            onArrowDown?()
            return
        case 126: // up arrow
            onArrowUp?()
            return
        case 36: // return
            onReturn?()
            return
        case 53: // escape
            onEscape?()
            return
        default:
            break
        }
        super.keyUp(with: event)
    }
}
