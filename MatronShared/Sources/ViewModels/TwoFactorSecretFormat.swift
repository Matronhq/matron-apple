import Foundation

/// How the sign-in screens print an authenticator setup key.
public enum TwoFactorSecretFormat {
    /// "JBSW Y3DP …": easier to read off the screen and type elsewhere.
    public static func grouped(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { start -> String in
            let from = secret.index(secret.startIndex, offsetBy: start)
            let to = secret.index(from, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex
            return String(secret[from..<to])
        }.joined(separator: " ")
    }
}
