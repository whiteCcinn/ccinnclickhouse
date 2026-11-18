import AppKit
import CcinnClickHouseKit
import SwiftUI
import Testing
@testable import CcinnClickHouse

/// An editor wired like `SQLWorkbenchView` wires it, with the binding and the model's diagnostics held
/// here, so tests can play the model's part (including lagging behind the text view).
@MainActor
private final class EditorHarness {
    var text: String
    var selection = NSRange(location: 0, length: 0)
    var diagnostics: [SQLDiagnostic] = []
    var reportedEdits: [SQLTextEdit] = []
    let textView: SQLTextView
    let coordinator: SQLEditor.Coordinator
    private let window: NSWindow

    init(_ text: String, diagnostics: [SQLDiagnostic] = []) {
        self.text = text
        self.diagnostics = diagnostics
        textView = SQLTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        coordinator = SQLEditor.Coordinator(SQLEditor(text: .constant(text), selection: .constant(selection)))
        coordinator.parent = editor
        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.lastSyncedText = text
        coordinator.diagnostics = diagnostics
        window.contentView = textView
        window.makeFirstResponder(textView)
    }

    var editor: SQLEditor {
        SQLEditor(text: Binding(get: { self.text }, set: { self.text = $0 }),
                  selection: Binding(get: { self.selection }, set: { self.selection = $0 }),
                  diagnostics: diagnostics,
                  onEdit: { self.reportedEdits += $0 })
    }

    /// What SwiftUI does on every re-render of the workbench.
    func render() { coordinator.update(from: editor) }

    func type(_ string: String, at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
        selection = textView.selectedRange()
        textView.insertText(string, replacementRange: textView.selectedRange())
    }
}

@Suite("SQL editor", .serialized)
@MainActor
struct SQLEditorTests {
    @Test func formattingIsOneUndoableEditThatEditTrackingSees() throws {
        let original = "select a, b from t"
        let harness = EditorHarness(original)
        let undo = try #require(harness.textView.undoManager)
        undo.groupsByEvent = false
        let formatted = try #require(SQLFormatter.format(original))
        let length = (original as NSString).length
        undo.beginUndoGrouping()
        #expect(harness.textView.replace(NSRange(location: 0, length: length), with: formatted, expecting: original,
                                         actionName: "Format SQL", selecting: NSRange(location: 3, length: 0)) == .replaced)
        undo.endUndoGrouping()
        #expect(harness.textView.string == formatted)
        #expect(harness.text == formatted, "the binding is updated like typing")
        #expect(!harness.reportedEdits.isEmpty, "edit tracking sees the replacement")
        #expect(harness.textView.selectedRange() == NSRange(location: 3, length: 0))
        #expect(undo.undoActionName == "Format SQL")
        undo.undo()
        #expect(harness.textView.string == original, "one ⌘Z restores the original")
        // Out-of-date ranges are refused instead of trapping.
        #expect(harness.textView.replace(NSRange(location: 0, length: 10_000), with: "x", expecting: original, actionName: "Format SQL",
                                         selecting: NSRange(location: 0, length: 0)) == .textChanged)
    }

    /// Review #2: a format finishing while an input method composes never replaces the text (or ends the composition).
    @Test func formattingWaitsForTheInputMethod() {
        let harness = EditorHarness("select 1")
        harness.textView.setSelectedRange(NSRange(location: 8, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let outcome = harness.textView.replace(NSRange(location: 0, length: 8), with: "SELECT 1", expecting: "select 1", actionName: "Format SQL",
                                               selecting: NSRange(location: 0, length: 0))
        #expect(outcome == .composing)
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "select 1 ni")
    }

    /// Review #2: the result applies only to the live text it was computed for, not to the model's (possibly lagging) copy.
    @Test func formattingRefusesTextThatChanged() {
        let harness = EditorHarness("select 1")
        harness.type(" + 2", at: 8)
        let outcome = harness.textView.replace(NSRange(location: 0, length: 8), with: "SELECT 1", expecting: "select 1", actionName: "Format SQL",
                                               selecting: NSRange(location: 0, length: 0))
        #expect(outcome == .textChanged)
        #expect(harness.textView.string == "select 1 + 2")
    }

    /// Review: "unchanged" means the same UTF-16 code units, not Swift's canonical equivalence. NFD `é` (e + U+0301) is
    /// equal to NFC `é` as a `String`, but a range computed on one is wrong on the other.
    @Test func formattingRefusesCanonicallyEquivalentButDifferentText() {
        let harness = EditorHarness("select 'e\u{301}'")
        let nfc = "select '\u{E9}'"
        #expect(harness.textView.string == nfc, "Swift calls them equal")
        let outcome = harness.textView.replace(NSRange(location: 0, length: 6), with: "SELECT", expecting: nfc, actionName: "Format SQL",
                                               selecting: NSRange(location: 0, length: 0))
        #expect(outcome == .textChanged)
        #expect(harness.textView.string.utf16.elementsEqual("select 'e\u{301}'".utf16))
    }

    // A re-render while an input method composes must not overwrite the marked text.
    @Test func compositionSurvivesARenderWithLaggingText() {
        let harness = EditorHarness("SELECT 1")
        harness.textView.setSelectedRange(NSRange(location: 8, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textView.hasMarkedText())
        // The 300 ms lint lands while composing: the model's text is behind the storage, so its
        // diagnostics describe older text and must not be adopted yet.
        harness.diagnostics = SQLLinter.diagnose("SELECT (")
        harness.render()
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "SELECT 1 ni")
        #expect(harness.coordinator.diagnostics.isEmpty)
        // Committing reports every edit, in order, and the binding catches up.
        harness.textView.insertText(" 你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.text == "SELECT 1 你")
        var index = SQLLineIndex("SELECT 1")
        for edit in harness.reportedEdits { index.apply(edit) }
        #expect(index.length == ("SELECT 1 你" as NSString).length)
    }

    // A binding that changes while an input method composes (e.g. History → Open) waits for the commit.
    @Test func compositionIsNotReplacedByANewBinding() {
        let harness = EditorHarness("SELECT 1")
        harness.textView.setSelectedRange(NSRange(location: 8, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.text = "SELECT 2"
        harness.render()
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "SELECT 1 ni")
    }

    // Storage edits that get no textDidChange are reported instead of being overwritten.
    @Test func unreportedStorageEditsCatchUp() async throws {
        let harness = EditorHarness("SELECT 1")
        harness.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "-- c\n")
        #expect(harness.coordinator.hasPendingEdits)
        harness.render()
        #expect(harness.textView.string == "-- c\nSELECT 1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.text == "-- c\nSELECT 1")
        #expect(!harness.coordinator.hasPendingEdits)
    }

    // Return after a failed statement keeps its marker; typing onto its last token does not.
    @Test func returnAfterTheStatementKeepsItsMarker() {
        let failure = SQLDiagnostic(range: 14..<15, scope: 0..<15, severity: .error, source: .server, message: "Syntax error near 't'")
        let harness = EditorHarness("SELECT 1 FORM t", diagnostics: [failure])
        harness.type("\n", at: 15)
        #expect(harness.coordinator.diagnostics == [failure])
        let glued = EditorHarness("SELECT 1 FORM t", diagnostics: [failure])
        glued.type("x", at: 15)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // Text typed right before a statement only moves it when it stays a separate token.
    @Test func typingBeforeAStatement() {
        let failure = SQLDiagnostic(range: 23..<24, scope: 9..<24, severity: .error, source: .server, message: "m")
        let newline = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        newline.type("\n", at: 9)
        #expect(newline.coordinator.diagnostics.map(\.range) == [24..<25])
        let glued = EditorHarness("SELECT 1;SELECT x FORM t", diagnostics: [failure])
        glued.type("x", at: 9)
        #expect(glued.coordinator.diagnostics.isEmpty)
    }

    // Editing the failing statement removes its marker immediately (before the model answers).
    @Test func fixingTheStatementDropsItsMarker() {
        let failure = SQLDiagnostic(range: 9..<13, scope: 0..<15, severity: .error, source: .server, message: "m")
        let harness = EditorHarness("SELECT 1 FORM t", diagnostics: [failure])
        harness.textView.setSelectedRange(NSRange(location: 9, length: 4))
        harness.textView.insertText("FROM", replacementRange: NSRange(location: 9, length: 4))
        #expect(harness.coordinator.diagnostics.isEmpty)
        #expect(harness.text == "SELECT 1 FROM t")
        #expect(harness.reportedEdits.count == 1)
    }

    // A local marker stays put while the user types elsewhere in its statement.
    @Test func localMarkersDoNotBlinkWhileTyping() {
        let text = "SELECT count(1 FROM t"
        let harness = EditorHarness(text, diagnostics: SQLLinter.diagnose(text))
        harness.type(" ", at: 21)
        harness.type("W", at: 22)
        #expect(harness.coordinator.diagnostics.map(\.range) == [12..<13])
    }

    // New diagnostics from the model (a run finished) are adopted without touching the text.
    @Test func modelDiagnosticsAreAdopted() {
        let harness = EditorHarness("SELECT x FROM t")
        let failure = SQLDiagnostic(range: 7..<8, scope: 0..<15, severity: .error, source: .server, message: "Unknown expression identifier 'x'")
        harness.diagnostics = [failure]
        harness.render()
        #expect(harness.coordinator.diagnostics == [failure])
        #expect(harness.textView.inlineDiagnostics == [failure])
        #expect(harness.textView.string == "SELECT x FROM t")
    }
}

/// Format SQL as the toolbar and ⌥⌘L run it: on the editor's own text and selection, as one edit, and with a reason in
/// the status line whenever the text is left as it was.
@Suite("Format SQL in the editor", .serialized)
@MainActor
struct SQLFormatRunnerTests {
    private let upper = SQLFormatOptions(keywordCase: .upper)

    /// Runs Format SQL and waits for it to finish.
    private func format(_ runner: SQLFormatRunner, fallback: (text: String, selection: NSRange) = ("", NSRange(location: 0, length: 0)),
                        options: SQLFormatOptions = SQLFormatOptions(keywordCase: .upper),
                        whileRunning: () -> Void = {}, direct: @escaping SQLFormatRunner.DirectReplace = { _, _, _, _ in false }) async throws {
        runner.format(options: options, fallback: fallback, replaceWithoutEditor: direct)
        whileRunning()
        let deadline = ContinuousClock.now + .seconds(10)
        while runner.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!runner.isRunning)
    }

    /// The editor's own text and selection are formatted, not the model's copy (which lags while an input method composes).
    @Test func formatsTheEditorsOwnTextAndSelection() async throws {
        let harness = EditorHarness("select a,b from t")
        let runner = SQLFormatRunner()
        runner.editor.textView = harness.textView
        harness.textView.setSelectedRange(NSRange(location: 7, length: 3))
        try await format(runner, fallback: ("stale model text", NSRange(location: 0, length: 0)))
        #expect(harness.textView.string == "select a, b from t")
        #expect(harness.textView.selectedRange() == NSRange(location: 7, length: 4))
        #expect(runner.notice == nil)
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try await format(runner)
        #expect(harness.textView.string == "SELECT\n  a,\n  b\nFROM t")
        #expect(harness.text == "SELECT\n  a,\n  b\nFROM t", "the model hears about it like typing")
    }

    /// Final review (d): every refusal says why in the status line.
    @Test func aRefusalSaysWhy() async throws {
        let harness = EditorHarness("select 1_000, a from t")
        let runner = SQLFormatRunner()
        runner.editor.textView = harness.textView
        try await format(runner)
        #expect(runner.notice == .refused(.ambiguousToken("1_000")))
        #expect(runner.notice?.message.contains("1_000") == true)
        #expect(harness.textView.string == "select 1_000, a from t")

        harness.textView.string = "SELECT 1"
        try await format(runner)
        #expect(runner.notice == .alreadyFormatted)
    }

    @Test func composingTextIsNeverFormatted() async throws {
        let harness = EditorHarness("select a,b from t")
        let runner = SQLFormatRunner()
        runner.editor.textView = harness.textView
        harness.textView.setSelectedRange(NSRange(location: 17, length: 0))
        harness.textView.setMarkedText(" ni", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await format(runner)
        #expect(runner.notice == .composing)
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "select a,b from t ni")
    }

    /// Text typed while the format runs: the result is for the old text, so it is not applied, and the user is told.
    @Test func textChangedWhileFormattingIsLeftAlone() async throws {
        let harness = EditorHarness("select a,b from t")
        let runner = SQLFormatRunner()
        runner.editor.textView = harness.textView
        try await format(runner, whileRunning: { harness.type(" x", at: 17) })
        #expect(harness.textView.string == "select a,b from t x")
        #expect(runner.notice == .textChanged)
        // A model edit (typing, Open) while a format runs cancels it and says so.
        runner.format(options: upper, fallback: ("", NSRange(location: 0, length: 0))) { _, _, _, _ in false }
        runner.textDidChange()
        #expect(!runner.isRunning)
        #expect(runner.notice == .textChanged)
        // The next edit clears the notice.
        runner.textDidChange()
        #expect(runner.notice == nil)
    }

    /// A tab opened from launch arguments before its editor appeared: the model's text is formatted and replaced.
    @Test func withoutAnEditorTheModelTextIsReplaced() async throws {
        let runner = SQLFormatRunner()
        var replaced: (String, NSRange, String, NSRange)?
        try await format(runner, fallback: ("select a,b from t", NSRange(location: 0, length: 0)), direct: { expected, range, text, selection in
            replaced = (expected, range, text, selection)
            return true
        })
        #expect(replaced?.0 == "select a,b from t")
        #expect(replaced?.1 == NSRange(location: 0, length: 17))
        #expect(replaced?.2 == "SELECT\n  a,\n  b\nFROM t")
        #expect(runner.notice == nil)
        try await format(runner, fallback: ("select a,b from t", NSRange(location: 0, length: 0)), direct: { _, _, _, _ in false })
        #expect(runner.notice == .textChanged)
    }
}
