import AppKit
import Foundation
import SwiftUI

@MainActor
final class TerminalPRReviewSheetModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var searchText = ""
    @Published private(set) var pullRequests: [TerminalOpenPullRequest] = []
    @Published private(set) var isLoading = false
    @Published var isOpening = false
    @Published var errorMessage: String?
    @Published var selectedPRNumber: Int?

    /// The resolved git root (set after fetching PRs successfully).
    private(set) var resolvedRepositoryRoot: String?

    private let repositoryService: TerminalRepositoryService
    private let repositoryRoot: String
    private let onSelect: (TerminalOpenPullRequest, String) -> Void
    private let onCancel: () -> Void

    init(
        repositoryService: TerminalRepositoryService,
        repositoryRoot: String,
        onSelect: @escaping (TerminalOpenPullRequest, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.repositoryService = repositoryService
        self.repositoryRoot = repositoryRoot
        self.onSelect = onSelect
        self.onCancel = onCancel

        Task { await loadPullRequests() }
    }

    var filteredPullRequests: [TerminalOpenPullRequest] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return pullRequests }

        return pullRequests.filter { pr in
            pr.title.lowercased().contains(query)
                || pr.headRefName.lowercased().contains(query)
                || pr.authorLogin.lowercased().contains(query)
                || "#\(pr.number)".contains(query)
                || "\(pr.number)".contains(query)
        }
    }

    func loadPullRequests() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Resolve git root first
            let root = try await resolveGitRoot()
            resolvedRepositoryRoot = root

            pullRequests = try await repositoryService.fetchOpenPullRequests(
                repositoryRoot: root
            )
            // Pre-select first item
            selectedPRNumber = pullRequests.first?.number
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectCurrent() {
        guard let selectedPRNumber,
              let pr = filteredPullRequests.first(where: { $0.number == selectedPRNumber }),
              let root = resolvedRepositoryRoot else { return }
        isOpening = true
        errorMessage = nil
        onSelect(pr, root)
    }

    func select(_ pr: TerminalOpenPullRequest) {
        guard let root = resolvedRepositoryRoot else { return }
        isOpening = true
        errorMessage = nil
        onSelect(pr, root)
    }

    func moveSelection(down: Bool) {
        let list = filteredPullRequests
        guard !list.isEmpty else { return }

        guard let current = selectedPRNumber,
              let idx = list.firstIndex(where: { $0.number == current }) else {
            selectedPRNumber = list.first?.number
            return
        }

        let newIdx = down ? min(idx + 1, list.count - 1) : max(idx - 1, 0)
        selectedPRNumber = list[newIdx].number
    }

    func cancel() {
        onCancel()
    }

    private func resolveGitRoot() async throws -> String {
        do {
            let output = try await TerminalProcessRunner.runCommand(
                "git",
                arguments: ["-C", repositoryRoot, "rev-parse", "--show-toplevel"]
            )
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw TerminalRepositoryServiceError.notARepository
        }
    }
}

struct TerminalPRReviewSheet: View {
    @ObservedObject var model: TerminalPRReviewSheetModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("PR Reviews")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            // Search field
            PRSearchField(
                text: $model.searchText,
                onArrowDown: { model.moveSelection(down: true) },
                onArrowUp: { model.moveSelection(down: false) },
                onReturn: { model.selectCurrent() }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            // PR list
            if model.isLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Loading pull requests…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isOpening {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Opening worktree…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                VStack(spacing: 8) {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") {
                        Task { await model.loadPullRequests() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredPullRequests.isEmpty {
                Text(model.searchText.isEmpty ? "No open pull requests." : "No matching pull requests.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.filteredPullRequests) { pr in
                                PRListRow(
                                    pr: pr,
                                    isSelected: model.selectedPRNumber == pr.number
                                )
                                .id(pr.number)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.select(pr)
                                }
                                .onHover { hovering in
                                    if hovering {
                                        model.selectedPRNumber = pr.number
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.selectedPRNumber) { newValue in
                        if let newValue {
                            withAnimation {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 450)
    }
}

/// NSTextField wrapper that forwards arrow key and Return events to closures
/// while keeping normal text editing behavior.
private struct PRSearchField: NSViewRepresentable {
    @Binding var text: String
    var onArrowDown: () -> Void
    var onArrowUp: () -> Void
    var onReturn: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = PRSearchNSTextField()
        field.placeholderString = "Search pull requests…"
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.onArrowDown = onArrowDown
        field.onArrowUp = onArrowUp
        field.onReturn = onReturn
        // Focus immediately
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if let field = nsView as? PRSearchNSTextField {
            field.onArrowDown = onArrowDown
            field.onArrowUp = onArrowUp
            field.onReturn = onReturn
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

private class PRSearchNSTextField: NSTextField {
    var onArrowDown: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onReturn: (() -> Void)?

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
        default:
            break
        }
        super.keyUp(with: event)
    }
}

private struct PRListRow: View {
    let pr: TerminalOpenPullRequest
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(pr.number)")
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(pr.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                Spacer()

                if pr.isDraft {
                    Text("Draft")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                    Text(pr.headRefName)
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.caption2)
                    Text(pr.authorLogin)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                Spacer()

                Text(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
    }
}
