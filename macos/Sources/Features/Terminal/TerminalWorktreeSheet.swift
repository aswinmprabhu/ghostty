import AppKit
import Foundation
import SwiftUI

@MainActor
final class TerminalWorktreeSheetModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var repositoryRoot: String
    @Published private(set) var branchCatalog = TerminalBranchCatalog(local: [], remote: [])
    @Published var useNewBranch = false
    @Published var selectedExistingBranchID = ""
    @Published var selectedBaseBranchID = ""
    @Published var newBranchName = ""
    @Published private(set) var isLoadingBranches = false
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    private let repositoryService: TerminalRepositoryService
    private let initialBaseBranchName: String?
    private let onComplete: (TerminalWorktreeCreationResult) -> Void
    private let onCancel: () -> Void

    init(
        repositoryService: TerminalRepositoryService,
        initialRepositoryRoot: String?,
        initialBaseBranchName: String?,
        onComplete: @escaping (TerminalWorktreeCreationResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.repositoryService = repositoryService
        self.repositoryRoot = initialRepositoryRoot ?? ""
        self.initialBaseBranchName = initialBaseBranchName
        self.onComplete = onComplete
        self.onCancel = onCancel

        if let initialRepositoryRoot, !initialRepositoryRoot.isEmpty {
            Task {
                await loadBranches()
            }
        }
    }

    var allBranches: [TerminalBranchDescriptor] {
        branchCatalog.all
    }

    var canSubmit: Bool {
        if isSubmitting || isLoadingBranches || repositoryRoot.isEmpty {
            return false
        }

        if useNewBranch {
            return !newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !selectedBaseBranchID.isEmpty
        }

        return !selectedExistingBranchID.isEmpty
    }

    func browseForRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repository"

        if panel.runModal() == .OK, let url = panel.url {
            repositoryRoot = url.path
            Task {
                await loadBranches()
            }
        }
    }

    func loadBranches() async {
        let repositoryRoot = repositoryRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else {
            branchCatalog = TerminalBranchCatalog(local: [], remote: [])
            selectedExistingBranchID = ""
            selectedBaseBranchID = ""
            return
        }

        isLoadingBranches = true
        errorMessage = nil
        defer { isLoadingBranches = false }

        do {
            let catalog = try await repositoryService.listBranches(in: repositoryRoot)
            branchCatalog = catalog

            if let existingBranch = catalog.all.first(where: { $0.reference == initialBaseBranchName || $0.name == initialBaseBranchName }) {
                selectedExistingBranchID = existingBranch.id
            } else {
                selectedExistingBranchID = catalog.local.first?.id ?? catalog.remote.first?.id ?? ""
            }

            if let baseBranch = catalog.local.first(where: { $0.reference == initialBaseBranchName }) {
                selectedBaseBranchID = baseBranch.id
            } else {
                selectedBaseBranchID = catalog.local.first?.id ?? catalog.remote.first?.id ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
            branchCatalog = TerminalBranchCatalog(local: [], remote: [])
            selectedExistingBranchID = ""
            selectedBaseBranchID = ""
        }
    }

    func submit() {
        guard canSubmit else { return }

        let repositoryRoot = repositoryRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repositoryRoot.isEmpty else { return }

        let selection: TerminalWorktreeSelection
        if useNewBranch {
            guard let base = branch(for: selectedBaseBranchID) else { return }
            selection = .newBranch(
                name: newBranchName.trimmingCharacters(in: .whitespacesAndNewlines),
                base: base
            )
        } else {
            guard let branch = branch(for: selectedExistingBranchID) else { return }
            selection = .existing(branch)
        }

        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }

            do {
                let result = try await repositoryService.createOrReuseWorktree(
                    request: TerminalWorktreeRequest(
                        repositoryRoot: repositoryRoot,
                        selection: selection
                    )
                )
                onComplete(result)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        onCancel()
    }

    private func branch(for id: String) -> TerminalBranchDescriptor? {
        allBranches.first(where: { $0.id == id })
    }
}

struct TerminalWorktreeSheet: View {
    @ObservedObject var model: TerminalWorktreeSheetModel

    private var groupedBranches: some View {
        Group {
            if !model.branchCatalog.local.isEmpty {
                Section("Local Branches") {
                    ForEach(model.branchCatalog.local) { branch in
                        Text(branch.reference).tag(branch.id)
                    }
                }
            }

            if !model.branchCatalog.remote.isEmpty {
                Section("Remote Branches") {
                    ForEach(model.branchCatalog.remote) { branch in
                        Text(branch.reference).tag(branch.id)
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Worktree")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Repository")
                    .font(.headline)

                HStack {
                    TextField("Repository path", text: $model.repositoryRoot)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("worktree-repository-path")
                    Button("Browse…") {
                        model.browseForRepository()
                    }
                    .accessibilityIdentifier("worktree-browse-repository")
                    Button("Load") {
                        Task {
                            await model.loadBranches()
                        }
                    }
                    .disabled(model.repositoryRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("worktree-load-branches")
                }
            }

            if model.isLoadingBranches {
                ProgressView("Loading branches…")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Create a new branch", isOn: $model.useNewBranch)
                        .accessibilityIdentifier("worktree-new-branch-toggle")

                    if model.useNewBranch {
                        TextField("New branch name", text: $model.newBranchName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("worktree-new-branch-name")

                        Picker("Base branch", selection: $model.selectedBaseBranchID) {
                            groupedBranches
                        }
                        .accessibilityIdentifier("worktree-base-branch-picker")
                    } else {
                        Picker("Branch", selection: $model.selectedExistingBranchID) {
                            groupedBranches
                        }
                        .accessibilityIdentifier("worktree-existing-branch-picker")
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancel()
                }
                .accessibilityIdentifier("worktree-cancel")
                Button(model.isSubmitting ? "Working…" : "Open Worktree") {
                    model.submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("worktree-submit")
            }
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }
}
