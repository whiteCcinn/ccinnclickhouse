import AppKit
import CcinnClickHouseKit
import Observation

/// Why Format SQL left the text as it was. Shown in the status line under the editor until the next edit, the next
/// format, or a few seconds later.
enum FormatNotice: Equatable {
    case alreadyFormatted
    /// An input method is composing text: it is never interrupted.
    case composing
    /// The text changed after the format started, so its result no longer applies.
    case textChanged
    case refused(SQLFormatter.Refusal)

    var message: String {
        switch self {
        case .alreadyFormatted:
            "Already formatted"
        case .composing:
            "Not formatted: finish the text you are composing first"
        case .textChanged:
            "Not formatted: the text changed while it was being formatted"
        case let .refused(.ambiguousToken(token)):
            "Not formatted: ClickHouse versions read “\(token.count > 40 ? String(token.prefix(40)) + "…" : token)” differently"
        case let .refused(.invisibleCharacter(code)):
            "Not formatted: an invisible character (U+\(String(format: "%04X", code))) stands outside strings and comments, and ClickHouse may read it as a space"
        case .refused(.tooLarge):
            "Not formatted: the result would be too large (very deep nesting)"
        case .refused(.notEquivalent):
            "Not formatted: the result could not be proven to mean exactly the same"
        case .refused(.cancelled):
            "Formatting was cancelled"
        }
    }

    /// Anything but "already formatted" left the user's request undone.
    var isProblem: Bool { self != .alreadyFormatted }
}

/// Format SQL for one editor (design D5 of add-sql-formatter). It formats the editor's own text and selection (the
/// model's copy lags behind while an input method composes) off the main actor, and applies the result as one
/// undoable edit, only to the exact text it was computed for and never while an input method composes. A newer
/// request or any edit cancels a format still running. Whenever the text is left as it was, `notice` says why.
@MainActor
@Observable
final class SQLFormatRunner {
    /// Replaces the model's text for a tab whose editor is not attached yet (opened from launch arguments): `true` when
    /// the model still held `expected` and took the replacement.
    typealias DirectReplace = @MainActor (_ expected: String, _ range: NSRange, _ replacement: String, _ selection: NSRange) -> Bool

    /// How long a notice stays in the status line.
    static let noticeDuration: Duration = .seconds(8)

    /// The tab's editor.
    let editor = SQLEditorController()
    private(set) var isRunning = false
    private(set) var notice: FormatNotice?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Increases with every request and every cancellation; a late result for an older one is dropped.
    @ObservationIgnored private var generation: UInt64 = 0

    /// Formats the selection, or the whole text when nothing is selected. `fallback` (the model's text and selection)
    /// and `replaceWithoutEditor` are used only while no editor is attached.
    func format(options: SQLFormatOptions, fallback: (text: String, selection: NSRange), replaceWithoutEditor: @escaping DirectReplace) {
        stop()
        clearNotice()
        let live = editor.state
        if live?.isComposing == true {
            show(.composing)
            return
        }
        let source = live?.text ?? fallback.text
        let selection = live?.selection ?? fallback.selection
        let generation = generation
        isRunning = true
        task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { SQLFormatter.edit(for: source, selection: selection, options: options) }
            let edit = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.task = nil
            self.isRunning = false
            self.apply(edit, to: source, replaceWithoutEditor: replaceWithoutEditor)
        }
    }

    /// The text changed (typing, Open, a replacement): a format still running no longer applies, and says so; an
    /// older notice is stale.
    func textDidChange() {
        let interrupted = isRunning
        stop()
        if interrupted { show(.textChanged) } else { clearNotice() }
    }

    private func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        isRunning = false
    }

    private func apply(_ edit: SQLFormatter.Edit, to source: String, replaceWithoutEditor: DirectReplace) {
        switch edit {
        case .unchanged:
            show(.alreadyFormatted)
        case let .refused(reason):
            show(.refused(reason))
        case let .replace(range, replacement, selection):
            if editor.isAttached {
                switch editor.replace(range, with: replacement, expecting: source, actionName: "Format SQL", selecting: selection) {
                case .replaced: break
                case .composing: show(.composing)
                case .textChanged, .noEditor: show(.textChanged)
                }
            } else if !replaceWithoutEditor(source, range, replacement, selection) {
                show(.textChanged)
            }
        }
    }

    private func show(_ notice: FormatNotice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled, let self, self.notice == notice else { return }
            self.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }
}
