import Foundation
import Testing
@testable import PlatformBridge

struct ReadingScopeResolverTests {
    @Test func repeatedWordUsesActualRange() throws {
        let text = "The current flows through the coil. This is our current plan."
        let range = (text as NSString).range(of: "current", options: .backwards)
        let result = try ReadingScopeResolver().resolve(text: text, selection: range)
        #expect(result.selection == "current")
        #expect(result.context == "This is our current plan.")
        #expect(result.availability == .sentence)
    }

    @Test func abbreviationDoesNotCutTechnicalContext() throws {
        let text = "Fig. 2 shows the current at 3.5 A. Next sentence."
        let result = try ReadingScopeResolver().resolve(text: text, selection: (text as NSString).range(of: "current"))
        #expect(result.context == "Fig. 2 shows the current at 3.5 A.")
    }

    @Test func selectedSentenceAndParagraph() throws {
        let text = "One sentence. Another sentence."
        let result = try ReadingScopeResolver().resolve(text: text, selection: NSRange(location: 0, length: text.utf16.count))
        #expect(result.selection == text)
        #expect(result.availability == .excerpt)
        let sentence = "This is our current plan."
        let single = try ReadingScopeResolver().resolve(text: sentence, selection: NSRange(location: 0, length: sentence.utf16.count))
        #expect(single.context == sentence)
        #expect(single.availability == .sentence)
    }

    @Test func pdfWrapsAndHyphensPreserveMeaningfulHyphens() throws {
        let text = "The cur\u{00AD}\nrent flows under light-\nload conditions."
        let result = try ReadingScopeResolver().resolve(text: text,
            selection: (text as NSString).range(of: "cur\u{00AD}\nrent"), isPDF: true)
        #expect(result.selection == "current")
        #expect(result.context == "The current flows under light- load conditions.")
        #expect(result.availability == .sentence)
    }

    @Test func missingContextIsExplicit() throws {
        let scope = try ReadingScopeResolver().selectionOnly("current")
        #expect(scope.before.isEmpty && scope.after.isEmpty)
        #expect(scope.availability == .selectionOnly)
    }

    @Test func boundedExcerptDoesNotSplitUnicode() throws {
        let text = String(repeating: "😀", count: 900) + " current " + String(repeating: "x", count: 3_000)
        let result = try ReadingScopeResolver().resolve(text: text, selection: (text as NSString).range(of: "current"))
        #expect(result.availability == .excerpt)
        #expect(result.context.utf16.count <= 2_000)
        #expect(!result.context.contains("�"))
    }

    @Test func invalidAndOversizedSelectionRejected() throws {
        let resolver = ReadingScopeResolver()
        #expect(throws: ReadingScopeError.invalidRange) { try resolver.resolve(text: "😀", selection: NSRange(location: 0, length: 1)) }
        #expect(throws: ReadingScopeError.invalidRange) { try resolver.resolve(text: "x", selection: NSRange(location: 0, length: 0)) }
        #expect(throws: ReadingScopeError.tooLong) { try resolver.selectionOnly(String(repeating: "x", count: 1_201)) }
        #expect(throws: ReadingScopeError.emptySelection) { try resolver.selectionOnly("  \n") }
    }
}
