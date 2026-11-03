import Foundation
import UniformTypeIdentifiers

/// How an attachment's filename is shown and whether the Mac opens it in
/// its default app straight away. Attachment names come from whoever sent
/// the file, so both decisions read the name as the system would.
public enum AttachmentOpenPolicy {
    /// `name` without invisible control and formatting characters (bidi
    /// overrides and isolates, zero-width marks, C0/C1 controls), so the
    /// name shown is the name the system sees: "report\u{202E}fdp.app"
    /// would otherwise draw as "reportppa.pdf".
    public static func visibleFilename(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Whether a file called `filename` is an everyday document (a picture,
    /// a PDF, plain text, an office document, audio or video) that can go
    /// to its default app on a click. Anything else (an app, an installer,
    /// a script, a Terminal profile, a link file, a web page, a file with
    /// no or an unknown extension) is confirmed first. Judged from the
    /// extension, because that is what picks the app that opens it.
    public static func opensWithoutAsking(filename: String) -> Bool {
        let ext = (visibleFilename(filename) as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        if askFirst.contains(where: { type.conforms(to: $0) }) { return false }
        return everyday.contains(where: { type.conforms(to: $0) })
            || everydayIdentifiers.contains(type.identifier)
    }

    private static let everyday: [UTType] = [
        .image, .pdf, .plainText, .rtf, .rtfd, .commaSeparatedText, .tabSeparatedText,
        .json, .spreadsheet, .presentation, .audiovisualContent,
    ]

    /// Office and iWork documents that declare no `spreadsheet` or
    /// `presentation` conformance.
    private static let everydayIdentifiers: Set<String> = [
        "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
        "org.oasis-open.opendocument.text", "com.apple.iwork.pages.sec-pages",
        "com.apple.iwork.pages.pages",
    ]

    /// Kinds that run code or hand off to something else when opened, even
    /// where they also count as text or an image (a shell script is plain
    /// text, an SVG is an image that a browser opens).
    private static let askFirst: [UTType] = [
        .executable, .script, .shellScript, .application, .applicationBundle, .bundle,
        .package, .html, .xml, .propertyList, .svg, .webArchive, .internetLocation,
        .internetShortcut, .archive, .diskImage,
    ] + ["com.apple.terminal.shell-script", "com.apple.terminal.settings",
                           "com.apple.installer-package-archive", "com.apple.file-location"]
        .compactMap { UTType($0) }
}
