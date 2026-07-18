import SwiftUI
import CoreImage.CIFilterBuiltins

/// CoreImage QR rendering, shared by the iOS and Mac "Link a Device"
/// screens.
public enum QRCode {
    /// Renders `string` as a QR `CGImage`, scaled up `scale`× from the raw
    /// module matrix so it stays crisp (no interpolation) at display size.
    public static func image(for string: String, scale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

public struct QRCodeView: View {
    let string: String

    public init(string: String) {
        self.string = string
    }

    public var body: some View {
        if let image = QRCode.image(for: string) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .accessibilityLabel("Sign-in QR code")
        }
        // qrCodeGenerator only fails on un-encodable input; our payloads are
        // short ASCII, so there is no meaningful fallback to draw.
    }
}
