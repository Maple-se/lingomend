import DiagnosticsCore

public extension TextSnapshot {
    func changeReason(comparedTo original: TextSnapshot) -> DiagnosticReason? {
        if applicationIdentifier != original.applicationIdentifier
            || focusedElementIdentifier != original.focusedElementIdentifier { return .focusChanged }
        if text != original.text || revisionToken != original.revisionToken { return .sourceChanged }
        if selectedRange != original.selectedRange { return .selectionChanged }
        return nil
    }
}
