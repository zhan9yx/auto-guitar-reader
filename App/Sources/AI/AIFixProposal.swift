import Foundation
import AGRCore

/// What the AI proposed for one score: validated fixes the user can accept or reject one by one,
/// plus the suggestions that were refused and the issues the model left alone.
struct AIFixProposal: Identifiable {
    let id = UUID()
    /// The score the fixes were validated against (apply accepted fixes to this, not to an edited copy).
    var original: Score
    var issues: [AIIssue]
    var fixes: [AppliedFix]
    var rejected: [RejectedFix]
    var unresolvedIssueIDs: [String]

    var isEmpty: Bool { fixes.isEmpty }

    /// Issues a fix addresses (for the list header).
    func issues(for fix: AppliedFix) -> [AIIssue] {
        fix.issueIDs.compactMap { id in issues.first { $0.id == id } }
    }

    /// `original` with only the fixes in `acceptedIDs` applied (in proposal order). `failed` lists accepted
    /// fixes that no longer apply cleanly in that combination.
    func result(accepting acceptedIDs: Set<String>) -> (score: Score, failed: [RejectedFix]) {
        let chosen = fixes.filter { acceptedIDs.contains($0.id) }
        let (score, failed) = AIAssistService.apply(fixes: chosen, to: original)
        return (score, failed)
    }
}
