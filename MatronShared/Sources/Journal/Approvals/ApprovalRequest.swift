import Foundation

/// One thing the user is asked to approve with their device's key: what
/// will be signed, and the words the confirm sheet shows with it.
public struct ApprovalRequest: Equatable, Sendable {
    /// What kind of statement this becomes. A tap carries its item, button
    /// and prompt digest here.
    public var kind: ApprovalStatement.Kind
    /// Signed exactly as given, and shown line by line.
    public var subject: ApprovalSubject
    /// What is being approved, in a few words: the item's title, or the
    /// account action ("Change password").
    public var headline: String
    /// The item's number as text ("#7"), for a tap or a consent item.
    public var reference: String?
    /// The button being pressed, for a tap or a consent answer.
    public var button: String?
    /// The question's words, or a spawn's task in full, shown under the
    /// headline.
    public var detail: String?
    /// For an account-kind request sent to a box rather than to the
    /// journal (unlock, clear lockdown): nothing else differs, but the
    /// sheet names the box.
    public var box: String?

    public init(kind: ApprovalStatement.Kind, subject: ApprovalSubject, headline: String, reference: String? = nil,
                button: String? = nil, detail: String? = nil, box: String? = nil) {
        self.kind = kind; self.subject = subject; self.headline = headline; self.reference = reference
        self.button = button; self.detail = detail; self.box = box
    }

    /// The subject's lines, in the order they are signed.
    public var subjectLines: [(key: String, value: String)] { ApprovalSubjects.lines(subject) }
}

/// Signs a request, after showing it to the user. Returns nil when the
/// account has no approval key (the request then goes unsigned, as it
/// always did). Throws `ApprovalKeyFailure.cancelled` when the user backs
/// out, and an `ApprovalError` when the account has a key but this device
/// cannot sign.
public typealias ApprovalSigner = @Sendable (ApprovalRequest) async throws -> SignedApproval?

/// Why this device could not produce an approval the account needs.
public enum ApprovalError: Error, Equatable, Sendable {
    /// The account has an approval key, this device has none.
    case noKeyOnThisDevice
    /// This device's key was removed from the account.
    case keyRevoked
    /// The journal has approval keys switched off (no public URL).
    case disabled
    /// What the user was shown does not match what would be signed (a
    /// spawn's task whose hash is not the subject's).
    case subjectMismatch(String)
}

extension ApprovalError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noKeyOnThisDevice:
            return "This needs an approval key and this device doesn't have one. Approve it on a device that does, or set one up in Settings ▸ Approval keys."
        case .keyRevoked:
            return "This device's approval key has been removed from the account. Set up a new key in Settings ▸ Approval keys."
        case .disabled:
            return "Approval keys are switched off on this server."
        case .subjectMismatch(let detail):
            return detail
        }
    }
}
