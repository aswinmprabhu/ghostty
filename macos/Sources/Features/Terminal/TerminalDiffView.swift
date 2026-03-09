import AppKit
import SwiftUI
import WebKit

// MARK: - WebView Find Bar

@MainActor
final class WebViewFindModel: ObservableObject {
    @Published var isVisible = false
    @Published var searchText = ""
    @Published var matchInfo = ""
    weak var webView: WKWebView?

    private var isInjected = false

    func show() { isVisible = true; injectIfNeeded() }
    func hide() {
        isVisible = false
        searchText = ""
        matchInfo = ""
        run("_pfClear()")
    }

    func findNext() {
        guard !searchText.isEmpty else { return }
        run("_pfNext('\(jsEscape(searchText))')") { [weak self] result in
            self?.matchInfo = result
        }
    }

    func findPrevious() {
        guard !searchText.isEmpty else { return }
        run("_pfPrev('\(jsEscape(searchText))')") { [weak self] result in
            self?.matchInfo = result
        }
    }

    private func run(_ js: String, completion: ((String) -> Void)? = nil) {
        webView?.evaluateJavaScript(js) { result, _ in
            if let s = result as? String { completion?(s) }
        }
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    func injectIfNeeded() {
        guard !isInjected else { return }
        isInjected = true
        webView?.evaluateJavaScript(Self.findScript)
    }

    // JS that finds text inside shadow DOMs, highlights matches, and scrolls to them
    static let findScript = """
    (function() {
        if (window._pfInit) return;
        window._pfInit = true;

        let matches = [];
        let currentIdx = -1;
        let lastQuery = '';
        const HL_STYLE = 'background: #facc15; color: #000; border-radius: 2px;';
        const HL_ACTIVE = 'background: #f97316; color: #000; border-radius: 2px;';
        const MARK_CLASS = '_pf-hl';

        function getTextNodes(root) {
            const nodes = [];
            const walk = (n) => {
                if (n.shadowRoot) walk(n.shadowRoot);
                if (n.nodeType === 3 && n.textContent.trim().length > 0) {
                    nodes.push(n);
                } else {
                    for (const c of n.childNodes) walk(c);
                }
            };
            walk(root);
            return nodes;
        }

        function clearMarks() {
            // Remove all highlight marks across all shadow roots
            const removeIn = (root) => {
                for (const mark of root.querySelectorAll('.' + MARK_CLASS)) {
                    const parent = mark.parentNode;
                    parent.replaceChild(document.createTextNode(mark.textContent), mark);
                    parent.normalize();
                }
                for (const el of root.querySelectorAll('*')) {
                    if (el.shadowRoot) removeIn(el.shadowRoot);
                }
            };
            removeIn(document);
            matches = [];
            currentIdx = -1;
        }

        function search(query) {
            clearMarks();
            if (!query) return '0/0';
            const lower = query.toLowerCase();
            const textNodes = getTextNodes(document.body);
            for (const node of textNodes) {
                const text = node.textContent;
                const textLower = text.toLowerCase();
                let idx = 0;
                const parts = [];
                let searchFrom = 0;
                while (true) {
                    const found = textLower.indexOf(lower, searchFrom);
                    if (found === -1) break;
                    if (found > idx) parts.push({ text: text.slice(idx, found), match: false });
                    parts.push({ text: text.slice(found, found + query.length), match: true });
                    idx = found + query.length;
                    searchFrom = idx;
                }
                if (parts.length === 0) continue;
                if (idx < text.length) parts.push({ text: text.slice(idx), match: false });
                const frag = document.createDocumentFragment();
                for (const p of parts) {
                    if (p.match) {
                        const mark = document.createElement('span');
                        mark.className = MARK_CLASS;
                        mark.style.cssText = HL_STYLE;
                        mark.textContent = p.text;
                        frag.appendChild(mark);
                        matches.push(mark);
                    } else {
                        frag.appendChild(document.createTextNode(p.text));
                    }
                }
                node.parentNode.replaceChild(frag, node);
            }
            lastQuery = query;
            return matches.length > 0 ? '0/' + matches.length : '0/0';
        }

        function setActive(idx) {
            if (currentIdx >= 0 && currentIdx < matches.length) {
                matches[currentIdx].style.cssText = HL_STYLE;
            }
            currentIdx = idx;
            if (currentIdx >= 0 && currentIdx < matches.length) {
                matches[currentIdx].style.cssText = HL_ACTIVE;
                // Scroll into view, traversing shadow host boundaries
                let el = matches[currentIdx];
                el.scrollIntoView({ block: 'center', behavior: 'smooth' });
            }
        }

        window._pfNext = function(query) {
            if (query !== lastQuery) search(query);
            if (matches.length === 0) return '0/0';
            setActive((currentIdx + 1) % matches.length);
            return (currentIdx + 1) + '/' + matches.length;
        };

        window._pfPrev = function(query) {
            if (query !== lastQuery) search(query);
            if (matches.length === 0) return '0/0';
            setActive((currentIdx - 1 + matches.length) % matches.length);
            return (currentIdx + 1) + '/' + matches.length;
        };

        window._pfClear = function() {
            clearMarks();
            lastQuery = '';
            return '';
        };
    })();
    """
}

struct WebViewFindBar: View {
    @ObservedObject var model: WebViewFindModel

    var body: some View {
        if model.isVisible {
            HStack(spacing: 6) {
                FindBarTextField(
                    text: $model.searchText,
                    onReturn: { model.findNext() },
                    onShiftReturn: { model.findPrevious() },
                    onEscape: { model.hide() }
                )
                .frame(width: 200)

                if !model.matchInfo.isEmpty {
                    Text(model.matchInfo)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.findPrevious()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)

                Button {
                    model.findNext()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)

                Button {
                    model.hide()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            )
            .padding(8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct FindBarTextField: NSViewRepresentable {
    @Binding var text: String
    var onReturn: () -> Void
    var onShiftReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FindBarNSTextField()
        field.placeholderString = "Find…"
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.delegate = context.coordinator
        field.onReturn = onReturn
        field.onShiftReturn = onShiftReturn
        field.onEscape = onEscape
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        if let f = nsView as? FindBarNSTextField {
            f.onReturn = onReturn
            f.onShiftReturn = onShiftReturn
            f.onEscape = onEscape
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onReturn: onReturn) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onReturn: () -> Void
        init(text: Binding<String>, onReturn: @escaping () -> Void) {
            _text = text
            self.onReturn = onReturn
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let f = notification.object as? NSTextField else { return }
            text = f.stringValue
            onReturn()
        }
    }
}

private class FindBarNSTextField: NSTextField {
    var onReturn: (() -> Void)?
    var onShiftReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return
            if event.modifierFlags.contains(.shift) {
                onShiftReturn?()
            } else {
                onReturn?()
            }
            return
        case 53: // Escape
            onEscape?()
            return
        default:
            break
        }
        super.keyUp(with: event)
    }
}

// MARK: - Main Diff View

struct TerminalDiffView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @StateObject private var findModel = WebViewFindModel()

    var body: some View {
        VStack(spacing: 0) {
            diffHeader
            Divider()
            diffContent
        }
        .overlay(alignment: .topTrailing) {
            WebViewFindBar(model: findModel)
        }
        .background {
            Button("") { findModel.show() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var diffHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                controller.closeDiff()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            if let file = tab.selectedDiffFile {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(file.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let file = tab.selectedDiffFile, !file.isBinary {
                HStack(spacing: 4) {
                    Text("+\(file.additions)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.green)
                    Text("-\(file.deletions)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var diffContent: some View {
        Group {
            if tab.isDiffLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Loading diff…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diffText = tab.diffRawText, !diffText.isEmpty {
                PierreDiffWebView(
                    diffText: diffText,
                    fileName: tab.selectedDiffFile?.path ?? "",
                    fileContent: tab.diffFileContent,
                    reviewThread: tab.activeReviewThread,
                    isReviewMode: tab.isReviewMode,
                    draftComments: tab.localReviewComments.filter { $0.filePath == tab.selectedDiffFile?.path },
                    findModel: findModel,
                    onLinesSelected: { startLine, endLine, side in
                        tab.pendingSelectionStart = startLine
                        tab.pendingSelectionEnd = endLine
                        tab.pendingSelectionSide = side
                        tab.showCommentBox = true
                        controller.objectWillChange.send()
                    },
                    onAddThreadToChat: {
                        if let thread = tab.activeReviewThread {
                            controller.addThreadToChat(thread)
                        }
                    },
                    onReplyToThread: { threadID, body in
                        controller.replyToThread(threadID: threadID, body: body)
                    },
                    onResolveThread: { threadID, resolve in
                        controller.resolveThread(threadID: threadID, resolve: resolve)
                    },
                    onStartReview: { startLine, endLine, side, body in
                        guard let file = tab.selectedDiffFile else { return }
                        let comment = TerminalLocalReviewComment(
                            id: UUID(),
                            filePath: file.path,
                            startLine: startLine,
                            endLine: endLine,
                            side: side,
                            text: body
                        )
                        tab.addReviewComment(comment)
                        controller.objectWillChange.send()
                    },
                    onDeleteDraft: { commentID in
                        if let uuid = UUID(uuidString: commentID) {
                            tab.removeReviewComment(id: uuid)
                            controller.objectWillChange.send()
                        }
                    }
                )
            } else {
                VStack {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            }
        }
        .overlay(alignment: .bottom) {
            if !tab.isReviewMode && tab.showCommentBox {
                InlineCommentBox(
                    text: Binding(
                        get: { tab.pendingCommentText },
                        set: { tab.pendingCommentText = $0 }
                    ),
                    selectedRange: commentRangeLabel,
                    onAdd: { addComment() },
                    onCancel: { cancelComment() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.showCommentBox)
    }

    private var commentRangeLabel: String {
        guard let start = tab.pendingSelectionStart else { return "" }
        let end = tab.pendingSelectionEnd ?? start
        let side = tab.pendingSelectionSide ?? "new"
        if start == end {
            return "Line \(start) (\(side))"
        }
        return "Lines \(start)–\(end) (\(side))"
    }

    private func addComment() {
        let text = tab.pendingCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let file = tab.selectedDiffFile,
              let start = tab.pendingSelectionStart else { return }

        let comment = TerminalLocalReviewComment(
            id: UUID(),
            filePath: file.path,
            startLine: start,
            endLine: tab.pendingSelectionEnd ?? start,
            side: tab.pendingSelectionSide ?? "new",
            text: text
        )
        tab.addReviewComment(comment)
        cancelComment()
    }

    private func cancelComment() {
        tab.pendingCommentText = ""
        tab.pendingSelectionStart = nil
        tab.pendingSelectionEnd = nil
        tab.pendingSelectionSide = nil
        tab.showCommentBox = false
        controller.objectWillChange.send()
    }

    private var emptyMessage: String {
        if let file = tab.selectedDiffFile {
            if file.isBinary { return "Binary file — no diff available." }
            if file.badges.contains("Untracked") { return "New untracked file — no diff available." }
        }
        return "No diff content available."
    }
}

// MARK: - WKWebView wrapper for @pierre/diffs

struct PierreDiffWebView: NSViewRepresentable {
    let diffText: String
    let fileName: String
    let fileContent: String?
    let reviewThread: TerminalPullRequestReviewThread?
    let isReviewMode: Bool
    let draftComments: [TerminalLocalReviewComment]
    var findModel: WebViewFindModel? = nil
    let onLinesSelected: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
    let onAddThreadToChat: () -> Void
    let onReplyToThread: (_ threadID: String, _ body: String) -> Void
    let onResolveThread: (_ threadID: String, _ resolve: Bool) -> Void
    let onStartReview: (_ startLine: Int, _ endLine: Int, _ side: String, _ body: String) -> Void
    let onDeleteDraft: (_ commentID: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLinesSelected: onLinesSelected,
            onAddThreadToChat: onAddThreadToChat,
            onReplyToThread: onReplyToThread,
            onResolveThread: onResolveThread,
            onStartReview: onStartReview,
            onDeleteDraft: onDeleteDraft
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "lineSelection")
        contentController.add(context.coordinator, name: "addToChat")
        contentController.add(context.coordinator, name: "replyToThread")
        contentController.add(context.coordinator, name: "resolveThread")
        contentController.add(context.coordinator, name: "startReview")
        contentController.add(context.coordinator, name: "deleteDraft")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        findModel?.webView = webView

        let html = Self.buildHTML(
            diffText: diffText, fileName: fileName,
            fileContent: fileContent,
            reviewThread: reviewThread, isReviewMode: isReviewMode,
            draftComments: draftComments
        )
        webView.loadHTMLString(html, baseURL: URL(string: "https://esm.sh/"))

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let draftCount = draftComments.count
        if context.coordinator.lastDiffText != diffText
            || context.coordinator.lastDraftCount != draftCount {
            context.coordinator.lastDiffText = diffText
            context.coordinator.lastDraftCount = draftCount
            let html = Self.buildHTML(
                diffText: diffText, fileName: fileName,
                fileContent: fileContent,
                reviewThread: reviewThread, isReviewMode: isReviewMode,
                draftComments: draftComments
            )
            webView.loadHTMLString(html, baseURL: URL(string: "https://esm.sh/"))
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var onLinesSelected: (_ startLine: Int, _ endLine: Int, _ side: String) -> Void
        var onAddThreadToChat: () -> Void
        var onReplyToThread: (_ threadID: String, _ body: String) -> Void
        var onResolveThread: (_ threadID: String, _ resolve: Bool) -> Void
        var onStartReview: (_ startLine: Int, _ endLine: Int, _ side: String, _ body: String) -> Void
        var onDeleteDraft: (_ commentID: String) -> Void
        weak var webView: WKWebView?
        var lastDiffText: String?
        var lastDraftCount: Int = 0

        init(
            onLinesSelected: @escaping (_ startLine: Int, _ endLine: Int, _ side: String) -> Void,
            onAddThreadToChat: @escaping () -> Void,
            onReplyToThread: @escaping (_ threadID: String, _ body: String) -> Void,
            onResolveThread: @escaping (_ threadID: String, _ resolve: Bool) -> Void,
            onStartReview: @escaping (_ startLine: Int, _ endLine: Int, _ side: String, _ body: String) -> Void,
            onDeleteDraft: @escaping (_ commentID: String) -> Void
        ) {
            self.onLinesSelected = onLinesSelected
            self.onAddThreadToChat = onAddThreadToChat
            self.onReplyToThread = onReplyToThread
            self.onResolveThread = onResolveThread
            self.onStartReview = onStartReview
            self.onDeleteDraft = onDeleteDraft
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "addToChat" {
                DispatchQueue.main.async { [weak self] in
                    self?.onAddThreadToChat()
                }
                return
            }

            if message.name == "replyToThread",
               let body = message.body as? [String: Any],
               let threadID = body["threadID"] as? String,
               let replyBody = body["body"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onReplyToThread(threadID, replyBody)
                }
                return
            }

            if message.name == "resolveThread",
               let body = message.body as? [String: Any],
               let threadID = body["threadID"] as? String,
               let resolve = body["resolve"] as? Bool {
                DispatchQueue.main.async { [weak self] in
                    self?.onResolveThread(threadID, resolve)
                }
                return
            }

            if message.name == "startReview",
               let body = message.body as? [String: Any],
               let startLine = body["startLine"] as? Int,
               let endLine = body["endLine"] as? Int,
               let side = body["side"] as? String,
               let text = body["body"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onStartReview(startLine, endLine, side, text)
                }
                return
            }

            if message.name == "deleteDraft",
               let body = message.body as? [String: Any],
               let commentID = body["commentID"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.onDeleteDraft(commentID)
                }
                return
            }

            guard message.name == "lineSelection",
                  let body = message.body as? [String: Any],
                  let startLine = body["startLine"] as? Int,
                  let endLine = body["endLine"] as? Int,
                  let side = body["side"] as? String
            else { return }

            DispatchQueue.main.async { [weak self] in
                self?.onLinesSelected(startLine, endLine, side)
            }
        }
    }

    private static func buildHTML(
        diffText: String,
        fileName: String,
        fileContent: String?,
        reviewThread: TerminalPullRequestReviewThread?,
        isReviewMode: Bool,
        draftComments: [TerminalLocalReviewComment]
    ) -> String {
        let escapedDiff = diffText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let escapedFileContent: String? = fileContent.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
        }

        let lang = Self.detectLanguage(from: fileName)

        // Build annotations JSON from review thread + draft comments
        var annotationItems: [String] = []

        if let thread = reviewThread, let line = thread.line ?? thread.originalLine {
            let side = thread.diffSide?.uppercased() == "LEFT" ? "deletions" : "additions"
            var commentItems: [String] = []
            for comment in thread.comments {
                let escapedAuthor = Self.escapeJS(comment.authorLogin)
                let escapedBody = Self.escapeJS(comment.body)
                let dateStr = Self.escapeJS(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                commentItems.append("{ author: '\(escapedAuthor)', body: '\(escapedBody)', date: '\(dateStr)' }")
            }
            let commentsArray = commentItems.joined(separator: ", ")
            let resolvedStr = thread.isResolved ? "true" : "false"
            let escapedThreadID = Self.escapeJS(thread.id)
            annotationItems.append("""
            {
                lineNumber: \(line),
                side: '\(side)',
                metadata: {
                    type: 'thread',
                    threadID: '\(escapedThreadID)',
                    comments: [\(commentsArray)],
                    isResolved: \(resolvedStr)
                }
            }
            """)
        }

        // Add draft comment annotations (only for current file)
        for draft in draftComments {
            let escapedBody = Self.escapeJS(draft.text)
            let escapedID = Self.escapeJS(draft.id.uuidString)
            let draftSide = draft.side == "old" ? "deletions" : "additions"
            annotationItems.append("""
            {
                lineNumber: \(draft.endLine),
                side: '\(draftSide)',
                metadata: {
                    type: 'draft',
                    commentID: '\(escapedID)',
                    body: '\(escapedBody)',
                    startLine: \(draft.startLine),
                    endLine: \(draft.endLine)
                }
            }
            """)
        }

        let annotationsJS = "const annotations = [\(annotationItems.joined(separator: ",\n"))];";
        let isReviewModeJS = isReviewMode ? "true" : "false"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                background: transparent;
                color: #e0e0e0;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                height: 100%;
                overflow: hidden;
            }
            #container {
                width: 100%;
                height: 100%;
                overflow: auto;
            }
            #loading {
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100%;
                color: #888;
                font-size: 13px;
            }
            #loading.hidden { display: none; }
            #error {
                display: none;
                padding: 20px;
                color: #ff6b6b;
                font-size: 13px;
                white-space: pre-wrap;
            }
        </style>
        </head>
        <body>
        <div id="loading">Loading diff…</div>
        <div id="error"></div>
        <div id="container"></div>
        <script type="module">
        try {
            const { FileDiff, parsePatchFiles, DIFFS_TAG_NAME } = await import('https://esm.sh/@pierre/diffs@1.0.11');

            const patchText = `\(escapedDiff)`;
            const parsedPatches = parsePatchFiles(patchText, '\(lang)');
            const isReviewMode = \(isReviewModeJS);

            // Populate full file lines for incremental expansion
            \(escapedFileContent != nil ? "const fullFileContent = `\(escapedFileContent!)`;" : "const fullFileContent = null;")
            if (fullFileContent != null) {
                const SPLIT_RE = /(?<=\\n)/;
                const fileLines = fullFileContent.split(SPLIT_RE);
                for (const patch of parsedPatches) {
                    for (const fd of patch.files) {
                        fd.newLines = fileLines;
                        fd.oldLines = fileLines;
                    }
                }
            }

            \(annotationsJS)

            let annotationElement = null;

            // Inline comment form state
            let activeInlineForm = null;

            function removeInlineForm() {
                if (activeInlineForm && activeInlineForm.parentNode) {
                    activeInlineForm.parentNode.removeChild(activeInlineForm);
                }
                activeInlineForm = null;
            }

            function showInlineCommentForm(startLine, endLine, side, parentEl) {
                removeInlineForm();

                const form = document.createElement('div');
                form.style.cssText = 'padding: 12px 16px; background: #1e293b; border-left: 3px solid #3b82f6; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                const rangeLabel = startLine === endLine
                    ? 'Line ' + startLine + ' (' + side + ')'
                    : 'Lines ' + startLine + '–' + endLine + ' (' + side + ')';

                const header = document.createElement('div');
                header.style.cssText = 'display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;';
                const label = document.createElement('span');
                label.style.cssText = 'font-size: 11px; color: #94a3b8; font-weight: 600;';
                label.textContent = 'Add review comment — ' + rangeLabel;
                header.appendChild(label);
                form.appendChild(header);

                const textarea = document.createElement('textarea');
                textarea.placeholder = 'Leave a comment…';
                textarea.style.cssText = 'width: 100%; min-height: 60px; max-height: 120px; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 13px; font-family: inherit; resize: vertical;';
                textarea.addEventListener('pointerdown', (e) => e.stopPropagation());
                textarea.addEventListener('keydown', (e) => e.stopPropagation());
                form.appendChild(textarea);

                const btnRow = document.createElement('div');
                btnRow.style.cssText = 'display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px;';

                const cancelBtn = document.createElement('button');
                cancelBtn.textContent = 'Cancel';
                cancelBtn.style.cssText = 'font-size: 12px; padding: 6px 14px; border-radius: 6px; border: 1px solid #475569; background: #334155; color: #e2e8f0; cursor: pointer; font-weight: 500; font-family: inherit;';
                cancelBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    removeInlineForm();
                });
                cancelBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                btnRow.appendChild(cancelBtn);

                const addBtn = document.createElement('button');
                addBtn.textContent = 'Start a review';
                addBtn.style.cssText = 'font-size: 12px; padding: 6px 14px; border-radius: 6px; border: none; background: #238636; color: white; cursor: pointer; font-weight: 600; font-family: inherit;';
                addBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const text = textarea.value.trim();
                    if (!text) return;
                    window.webkit.messageHandlers.startReview.postMessage({
                        startLine: startLine,
                        endLine: endLine,
                        side: side,
                        body: text
                    });
                    removeInlineForm();
                });
                addBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                btnRow.appendChild(addBtn);

                form.appendChild(btnRow);

                if (parentEl) {
                    parentEl.appendChild(form);
                }
                activeInlineForm = form;

                // Focus textarea
                setTimeout(() => textarea.focus(), 50);

                return form;
            }

            function renderAnnotation(annotation) {
                const m = annotation.metadata;

                // Draft comment annotation
                if (m.type === 'draft') {
                    const wrapper = document.createElement('div');
                    wrapper.style.cssText = 'padding: 10px 16px; background: #1a2332; border-left: 3px solid #238636; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                    const header = document.createElement('div');
                    header.style.cssText = 'display: flex; align-items: center; gap: 8px; margin-bottom: 6px;';

                    const badge = document.createElement('span');
                    badge.style.cssText = 'font-size: 10px; font-weight: 700; color: #238636; background: rgba(35,134,54,0.15); padding: 2px 6px; border-radius: 4px; text-transform: uppercase; letter-spacing: 0.5px;';
                    badge.textContent = 'Pending';
                    header.appendChild(badge);

                    const range = document.createElement('span');
                    range.style.cssText = 'font-size: 11px; color: #64748b;';
                    range.textContent = m.startLine === m.endLine
                        ? 'L' + m.startLine
                        : 'L' + m.startLine + '–L' + m.endLine;
                    header.appendChild(range);

                    const spacer = document.createElement('span');
                    spacer.style.cssText = 'flex: 1;';
                    header.appendChild(spacer);

                    const deleteBtn = document.createElement('button');
                    deleteBtn.textContent = 'Delete';
                    deleteBtn.style.cssText = 'font-size: 11px; padding: 2px 8px; border-radius: 4px; border: 1px solid #6b2126; background: transparent; color: #f85149; cursor: pointer; font-family: inherit;';
                    deleteBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        window.webkit.messageHandlers.deleteDraft.postMessage({ commentID: m.commentID });
                    });
                    deleteBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                    header.appendChild(deleteBtn);

                    wrapper.appendChild(header);

                    const body = document.createElement('div');
                    body.style.cssText = 'font-size: 13px; color: #cbd5e1; line-height: 1.5; white-space: pre-wrap;';
                    body.textContent = m.body;
                    wrapper.appendChild(body);

                    return wrapper;
                }

                // Existing review thread annotation
                const threadID = m.threadID;

                const wrapper = document.createElement('div');
                wrapper.id = 'review-thread-annotation';
                annotationElement = wrapper;
                wrapper.style.cssText = 'padding: 12px 16px; background: #1e293b; border-left: 3px solid #3b82f6; margin: 4px 0; font-family: -apple-system, BlinkMacSystemFont, sans-serif;';

                // Header row
                const header = document.createElement('div');
                header.style.cssText = 'display: flex; align-items: center; gap: 8px; margin-bottom: 8px;';

                const threadLabel = document.createElement('span');
                threadLabel.style.cssText = 'font-size: 11px; color: #94a3b8; font-weight: 600; flex-shrink: 0;';
                threadLabel.textContent = m.isResolved ? 'Resolved Thread' : 'Review Thread';
                header.appendChild(threadLabel);

                const spacer = document.createElement('span');
                spacer.style.cssText = 'flex: 1;';
                header.appendChild(spacer);

                const btnStyle = 'font-size: 11px; padding: 3px 10px; border-radius: 4px; border: 1px solid #475569; background: #334155; color: #e2e8f0; cursor: pointer; font-family: inherit; flex-shrink: 0;';

                // Resolve / Unresolve button
                const resolveBtn = document.createElement('button');
                resolveBtn.textContent = m.isResolved ? 'Unresolve' : 'Resolve';
                resolveBtn.style.cssText = btnStyle;
                if (m.isResolved) {
                    resolveBtn.style.borderColor = '#065f46';
                    resolveBtn.style.color = '#6ee7b7';
                }
                resolveBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    window.webkit.messageHandlers.resolveThread.postMessage({
                        threadID: threadID,
                        resolve: !m.isResolved
                    });
                });
                resolveBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                header.appendChild(resolveBtn);

                // Add to chat button
                const addBtn = document.createElement('button');
                addBtn.textContent = 'Add to chat';
                addBtn.style.cssText = btnStyle;
                addBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    window.webkit.messageHandlers.addToChat.postMessage({});
                });
                addBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                header.appendChild(addBtn);

                wrapper.appendChild(header);

                // Comment bubbles
                for (const c of m.comments) {
                    const commentDiv = document.createElement('div');
                    commentDiv.style.cssText = 'padding: 8px 10px; background: #0f172a; border-radius: 6px; margin-bottom: 6px;';

                    const commentHeader = document.createElement('div');
                    commentHeader.style.cssText = 'display: flex; justify-content: space-between; margin-bottom: 4px;';

                    const author = document.createElement('span');
                    author.style.cssText = 'font-size: 12px; font-weight: 600; color: #e2e8f0;';
                    author.textContent = c.author;
                    commentHeader.appendChild(author);

                    const date = document.createElement('span');
                    date.style.cssText = 'font-size: 11px; color: #64748b;';
                    date.textContent = c.date;
                    commentHeader.appendChild(date);

                    commentDiv.appendChild(commentHeader);

                    const body = document.createElement('div');
                    body.style.cssText = 'font-size: 13px; color: #cbd5e1; line-height: 1.5; white-space: pre-wrap;';
                    body.textContent = c.body;
                    commentDiv.appendChild(body);

                    wrapper.appendChild(commentDiv);
                }

                // Reply box
                const replyArea = document.createElement('div');
                replyArea.style.cssText = 'margin-top: 8px; display: flex; flex-direction: column; gap: 8px;';

                const textarea = document.createElement('textarea');
                textarea.placeholder = 'Reply to this thread…';
                textarea.style.cssText = 'width: 100%; min-height: 36px; max-height: 100px; padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: #e2e8f0; font-size: 13px; font-family: inherit; resize: vertical;';
                textarea.addEventListener('pointerdown', (e) => e.stopPropagation());
                textarea.addEventListener('keydown', (e) => e.stopPropagation());
                replyArea.appendChild(textarea);

                const sendBtn = document.createElement('button');
                sendBtn.textContent = 'Reply';
                sendBtn.style.cssText = 'align-self: flex-end; font-size: 12px; padding: 8px 14px; border-radius: 6px; border: none; background: #3b82f6; color: white; cursor: pointer; font-weight: 600; font-family: inherit;';
                sendBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    const text = textarea.value.trim();
                    if (!text) return;
                    window.webkit.messageHandlers.replyToThread.postMessage({
                        threadID: threadID,
                        body: text
                    });
                    textarea.value = '';
                    textarea.disabled = true;
                    sendBtn.disabled = true;
                    sendBtn.textContent = 'Sent';
                    sendBtn.style.background = '#065f46';
                });
                sendBtn.addEventListener('pointerdown', (e) => e.stopPropagation());
                replyArea.appendChild(sendBtn);

                wrapper.appendChild(replyArea);

                return wrapper;
            }

            // Handle line selection — in review mode, show inline form; otherwise post to Swift
            function handleLineSelection(startLine, endLine, side, containerEl) {
                if (isReviewMode) {
                    // For review mode, inject an inline comment form into the container
                    // We insert it after the diff element
                    showInlineCommentForm(startLine, endLine, side, containerEl);
                } else {
                    window.webkit.messageHandlers.lineSelection.postMessage({
                        startLine: startLine,
                        endLine: endLine,
                        side: side
                    });
                }
            }

            document.getElementById('loading').classList.add('hidden');

            const container = document.getElementById('container');

            for (const patch of parsedPatches) {
                for (const fileDiff of patch.files) {

                    const instance = new FileDiff({
                        theme: { dark: 'pierre-dark', light: 'pierre-light' },
                        themeType: 'dark',
                        diffStyle: 'split',
                        overflow: 'scroll',
                        enableLineSelection: true,
                        disableFileHeader: true,
                        lineHoverHighlight: 'both',
                        enableGutterUtility: true,
                        hunkSeparators: 'line-info',
                        expansionLineCount: 20,
                        renderAnnotation: renderAnnotation,
                        onGutterUtilityClick(range) {
                            if (range != null && range.start != null) {
                                const side = range.side === 'deletions' ? 'old' : 'new';
                                handleLineSelection(
                                    Math.min(range.start, range.end),
                                    Math.max(range.start, range.end),
                                    side,
                                    container
                                );
                            }
                        },
                        onLineSelectionEnd(range) {
                            if (range != null && range.start != null) {
                                const side = range.side === 'deletions' ? 'old' : 'new';
                                handleLineSelection(
                                    Math.min(range.start, range.end),
                                    Math.max(range.start, range.end),
                                    side,
                                    container
                                );
                            }
                        },
                        onLineNumberClick(props) {
                            const side = props.annotationSide === 'deletions' ? 'old' : 'new';
                            handleLineSelection(props.lineNumber, props.lineNumber, side, container);
                        },
                    });

                    const fileContainer = document.createElement(DIFFS_TAG_NAME);
                    container.appendChild(fileContainer);
                    instance.render({
                        fileDiff,
                        fileContainer,
                        lineAnnotations: annotations.length > 0 ? annotations : undefined
                    });
                }
            }

            // Scroll to the annotation as soon as it appears in the DOM
            if (annotations.length > 0) {
                function scrollToAnnotation() {
                    const containerEl = document.getElementById('container');
                    function findInShadow(root) {
                        const el = root.querySelector('#review-thread-annotation');
                        if (el) return el;
                        for (const host of root.querySelectorAll('*')) {
                            if (host.shadowRoot) {
                                const found = findInShadow(host.shadowRoot);
                                if (found) return found;
                            }
                        }
                        return null;
                    }
                    const target = annotationElement || findInShadow(document);
                    if (target && containerEl) {
                        let offsetTop = 0;
                        let el = target;
                        while (el) {
                            offsetTop += el.offsetTop || 0;
                            el = el.offsetParent;
                        }
                        containerEl.scrollTop = Math.max(0, offsetTop - containerEl.clientHeight / 3);
                        return true;
                    }
                    return false;
                }

                // Try immediately first
                if (!scrollToAnnotation()) {
                    // Watch for the annotation to appear via MutationObserver
                    const obs = new MutationObserver(() => {
                        if (scrollToAnnotation()) obs.disconnect();
                    });
                    obs.observe(document.getElementById('container'), { childList: true, subtree: true });
                }
            }
        } catch (err) {
            document.getElementById('loading').classList.add('hidden');
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = 'Failed to load diff renderer: ' + err.message;
            console.error('Pierre diffs error:', err);
        }
        </script>
        </body>
        </html>
        """
    }

    static func detectLanguage(from path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "ts", "tsx": return "typescript"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "swift": return "swift"
        case "rb": return "ruby"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp": return "cpp"
        case "zig": return "zig"
        case "sh", "bash", "zsh": return "bash"
        case "yaml", "yml": return "yaml"
        case "json": return "json"
        case "xml", "html", "xib", "plist", "sdef": return "xml"
        case "css": return "css"
        case "md": return "markdown"
        case "sql": return "sql"
        default: return ext.isEmpty ? "text" : ext
        }
    }

    static func escapeJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

// MARK: - Inline Comment Box

private struct InlineCommentBox: View {
    @Binding var text: String
    let selectedRange: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add review comment")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !selectedRange.isEmpty {
                    Text(selectedRange)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Add to review") {
                    onAdd()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 8, y: -2)
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

// MARK: - Review Comments Uber Box (Editable)

struct ReviewCommentsUberBox: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @State private var errorMessage: String?
    @State private var editableText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Review Comments")
                    .font(.headline)

                Spacer()

                Text("\(tab.localReviewComments.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }

            TextEditor(text: $editableText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    tab.clearReviewComments()
                    editableText = ""
                    errorMessage = nil
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                Button {
                    let result = sendToChat()
                    if let error = result {
                        errorMessage = error
                    } else {
                        errorMessage = nil
                    }
                } label: {
                    Label("Fix in chat", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear { rebuildText() }
        .onReceive(tab.$localReviewComments) { _ in rebuildText() }
    }

    private func rebuildText() {
        var text = ""
        for comment in tab.localReviewComments {
            let fileName = URL(fileURLWithPath: comment.filePath).lastPathComponent
            if comment.startLine == comment.endLine {
                text += "[\(fileName):L\(comment.startLine) (\(comment.side))]\n"
            } else {
                text += "[\(fileName):L\(comment.startLine)-L\(comment.endLine) (\(comment.side))]\n"
            }
            text += "\(comment.text)\n\n"
        }
        editableText = text
    }

    private func sendToChat() -> String? {
        guard let surface = controller.focusedSurface, let surfaceModel = surface.surfaceModel else {
            return "No active terminal session. Open a terminal first."
        }

        let trimmed = editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No review comments to send." }

        let message = "Please fix the following review comments:\n\n\(trimmed)\n"
        surfaceModel.sendText(message)
        return nil
    }
}

// MARK: - PR Thread Comments Uber Box (Comments tab)

struct PRThreadCommentsUberBox: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @State private var errorMessage: String?
    @State private var editableText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Comments for Chat")
                    .font(.headline)

                Spacer()

                Text("\(tab.prThreadReviewComments.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }

            TextEditor(text: $editableText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 80, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    tab.clearPRThreadComments()
                    editableText = ""
                    errorMessage = nil
                } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                Button {
                    let result = sendToChat()
                    if let error = result {
                        errorMessage = error
                    } else {
                        errorMessage = nil
                    }
                } label: {
                    Label("Fix in chat", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear { rebuildText() }
        .onReceive(tab.$prThreadReviewComments) { _ in rebuildText() }
    }

    private func rebuildText() {
        var text = ""
        for comment in tab.prThreadReviewComments {
            let fileName = URL(fileURLWithPath: comment.filePath).lastPathComponent
            if comment.startLine == comment.endLine {
                text += "[\(fileName):L\(comment.startLine) (\(comment.side))]\n"
            } else {
                text += "[\(fileName):L\(comment.startLine)-L\(comment.endLine) (\(comment.side))]\n"
            }
            text += "\(comment.text)\n\n"
        }
        editableText = text
    }

    private func sendToChat() -> String? {
        guard let surface = controller.focusedSurface, let surfaceModel = surface.surfaceModel else {
            return "No active terminal session. Open a terminal first."
        }

        let trimmed = editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No comments to send." }

        let message = "Please address the following PR review comments:\n\n\(trimmed)\n"
        surfaceModel.sendText(message)
        return nil
    }
}

// MARK: - File Viewer View (full file, not diff)

struct TerminalFileViewerView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @StateObject private var findModel = WebViewFindModel()

    var body: some View {
        VStack(spacing: 0) {
            fileViewerHeader
            Divider()
            fileViewerContent
        }
        .overlay(alignment: .topTrailing) {
            WebViewFindBar(model: findModel)
        }
        .background {
            Button("") { findModel.show() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var fileViewerHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                controller.closeFileViewer()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            if let path = tab.viewerFilePath {
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fileViewerContent: some View {
        Group {
            if tab.isViewerLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Loading file…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let content = tab.viewerFileContent, !content.isEmpty {
                PierreFileWebView(
                    fileContent: content,
                    fileName: tab.viewerFilePath ?? "",
                    findModel: findModel
                )
            } else {
                VStack {
                    Text("File is empty or could not be read.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            }
        }
    }
}

// MARK: - WKWebView wrapper for full file viewing with pierre

// MARK: - Combined (multi-file) Diff View

struct TerminalCombinedDiffView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: TerminalTabState
    @StateObject private var findModel = WebViewFindModel()

    var body: some View {
        VStack(spacing: 0) {
            combinedDiffHeader
            Divider()
            combinedDiffContent
        }
        .overlay(alignment: .topTrailing) {
            WebViewFindBar(model: findModel)
        }
        .background {
            Button("") { findModel.show() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var combinedDiffHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                controller.closeCombinedDiff()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.plain)

            Text(tab.combinedDiffTitle ?? "All Changes")
                .font(.body.weight(.semibold))
                .lineLimit(1)

            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var combinedDiffContent: some View {
        Group {
            if tab.isCombinedDiffLoading {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 4)
                    Text("Loading diff…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diffText = tab.combinedDiffRawText, !diffText.isEmpty {
                PierreCombinedDiffWebView(
                    diffText: diffText,
                    findModel: findModel
                )
            } else {
                VStack {
                    Text("No changes to display.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
            }
        }
    }
}

// MARK: - WKWebView for combined multi-file diff

struct PierreCombinedDiffWebView: NSViewRepresentable {
    let diffText: String
    var findModel: WebViewFindModel? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastDiffText = diffText
        findModel?.webView = webView

        let html = Self.buildCombinedHTML(diffText: diffText)
        webView.loadHTMLString(html, baseURL: URL(string: "https://esm.sh/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastDiffText != diffText {
            context.coordinator.lastDiffText = diffText
            let html = Self.buildCombinedHTML(diffText: diffText)
            webView.loadHTMLString(html, baseURL: URL(string: "https://esm.sh/"))
        }
    }

    class Coordinator: NSObject {
        var lastDiffText: String?
    }

    private static func buildCombinedHTML(diffText: String) -> String {
        let escapedDiff = diffText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                background: transparent;
                color: #e0e0e0;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                height: 100%;
                overflow: hidden;
            }
            #container {
                width: 100%;
                height: 100%;
                overflow: auto;
            }
            #loading {
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100%;
                color: #888;
                font-size: 13px;
            }
            #loading.hidden { display: none; }
            #error {
                display: none;
                padding: 20px;
                color: #ff6b6b;
                font-size: 13px;
                white-space: pre-wrap;
            }
        </style>
        </head>
        <body>
        <div id="loading">Loading diff…</div>
        <div id="error"></div>
        <div id="container"></div>
        <script type="module">
        try {
            const { FileDiff, parsePatchFiles, DIFFS_TAG_NAME } = await import('https://esm.sh/@pierre/diffs@1.0.11');

            const patchText = `\(escapedDiff)`;
            const parsedPatches = parsePatchFiles(patchText);

            document.getElementById('loading').classList.add('hidden');
            const container = document.getElementById('container');

            for (const patch of parsedPatches) {
                for (const fileDiff of patch.files) {
                    const instance = new FileDiff({
                        theme: { dark: 'pierre-dark', light: 'pierre-light' },
                        themeType: 'dark',
                        diffStyle: 'split',
                        overflow: 'scroll',
                        lineHoverHighlight: 'both',
                        hunkSeparators(hunkData) {
                            const wrapper = document.createElement('div');
                            wrapper.style.gridColumn = 'span 2';
                            const inner = document.createElement('div');
                            inner.style.cssText = 'position: sticky; left: 0; width: var(--diffs-column-width); display: flex; align-items: center; gap: 8px;';
                            const lineText = document.createElement('span');
                            lineText.textContent = (hunkData.lines || '') + ' unmodified lines';
                            inner.appendChild(lineText);
                            const ctx = hunkData.hunkContext || hunkData.context || hunkData.header || hunkData.section || '';
                            if (ctx) {
                                const ctxSpan = document.createElement('span');
                                ctxSpan.textContent = ctx;
                                ctxSpan.style.cssText = 'color: #8b949e; font-style: italic;';
                                inner.appendChild(ctxSpan);
                            }
                            if (!ctx) {
                                const dbg = document.createElement('span');
                                dbg.textContent = '[keys: ' + Object.keys(hunkData).join(',') + ']';
                                dbg.style.cssText = 'color: #f85149; font-size: 10px;';
                                inner.appendChild(dbg);
                            }
                            wrapper.appendChild(inner);
                            return wrapper;
                        },
                        expansionLineCount: 20,
                    });

                    const fileContainer = document.createElement(DIFFS_TAG_NAME);
                    container.appendChild(fileContainer);
                    instance.render({ fileDiff, fileContainer });
                }
            }
        } catch (err) {
            document.getElementById('loading').classList.add('hidden');
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = 'Failed to load diff renderer: ' + err.message;
            console.error('Pierre combined diff error:', err);
        }
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - WKWebView wrapper for full file viewing with pierre

struct PierreFileWebView: NSViewRepresentable {
    let fileContent: String
    let fileName: String
    var findModel: WebViewFindModel? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.lastContent = fileContent
        findModel?.webView = webView

        let html = Self.buildFileHTML(content: fileContent, fileName: fileName)
        webView.loadHTMLString(html, baseURL: URL(string: "https://esm.sh/"))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastContent != fileContent {
            context.coordinator.lastContent = fileContent
            let html = Self.buildFileHTML(content: fileContent, fileName: fileName)
            webView.loadHTMLString(html, baseURL: URL(string: "https://esm.sh/"))
        }
    }

    class Coordinator: NSObject {
        var lastContent: String?
    }

    private static func buildFileHTML(content: String, fileName: String) -> String {
        let lang = PierreDiffWebView.detectLanguage(from: fileName)

        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let escapedName = PierreDiffWebView.escapeJS(fileName)

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body {
                background: transparent;
                color: #e0e0e0;
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                height: 100%;
                overflow: hidden;
            }
            #container {
                width: 100%;
                height: 100%;
                overflow: auto;
            }
            #loading {
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100%;
                color: #888;
                font-size: 13px;
            }
            #loading.hidden { display: none; }
            #error {
                display: none;
                padding: 20px;
                color: #ff6b6b;
                font-size: 13px;
                white-space: pre-wrap;
            }
        </style>
        </head>
        <body>
        <div id="loading">Loading file…</div>
        <div id="error"></div>
        <div id="container"></div>
        <script type="module">
        try {
            const { File, DIFFS_TAG_NAME } = await import('https://esm.sh/@pierre/diffs@1.0.11');

            const fileContent = `\(escapedContent)`;

            document.getElementById('loading').classList.add('hidden');

            const container = document.getElementById('container');

            const instance = new File({
                theme: { dark: 'pierre-dark', light: 'pierre-light' },
                themeType: 'dark',
                overflow: 'scroll',
                disableFileHeader: true,
                lineHoverHighlight: 'both',
            });

            const fileContainer = document.createElement(DIFFS_TAG_NAME);
            container.appendChild(fileContainer);
            instance.render({
                file: { contents: fileContent, name: '\(escapedName)', lang: '\(lang)' },
                fileContainer
            });
        } catch (err) {
            document.getElementById('loading').classList.add('hidden');
            const errorEl = document.getElementById('error');
            errorEl.style.display = 'block';
            errorEl.textContent = 'Failed to load file viewer: ' + err.message;
            console.error('Pierre file viewer error:', err);
        }
        </script>
        </body>
        </html>
        """
    }
}
