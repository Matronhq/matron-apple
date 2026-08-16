import XCTest
import SwiftUI
@testable import MatronDesignSystem

final class BoxChipTests: XCTestCase {
    /// The chip must never grow a row: it renders on the title line, capped
    /// to one line. Rows in this app have a hard fixed-height invariant
    /// (ChatRowHeightTests) that a wrapping chip would break.
    func testChipIsSingleLineAndTruncates() {
        let chip = BoxChip("a-very-long-box-name-that-will-not-fit")
        XCTAssertEqual(chip.displayName, "a-very-long-box-name-that-will-not-fit")
        XCTAssertEqual(chip.lineLimit, 1)
    }

    /// Pins name → palette index for fixed fixtures. If this test breaks,
    /// the hash or palette changed and every user's colours re-shuffle —
    /// that must never happen silently.
    func testPaletteIndexIsPinned() {
        XCTAssertEqual(BoxChip.paletteIndex(for: "eric"), 4)
        XCTAssertEqual(BoxChip.paletteIndex(for: "dan-mac"), 4)
        XCTAssertEqual(BoxChip.paletteIndex(for: "build-7"), 9)
        XCTAssertEqual(BoxChip.paletteIndex(for: ""), 1)      // FNV offset basis % 10
        XCTAssertEqual(BoxChip.paletteIndex(for: "🦊 box"), 1) // multi-byte UTF-8
    }

    func testPaletteIndexIsDeterministicAndInRange() {
        for name in ["eric", "dan-mac", "build-7", "", "🦊 box", "a-very-long-box-name-that-will-not-fit"] {
            let first = BoxChip.paletteIndex(for: name)
            XCTAssertEqual(first, BoxChip.paletteIndex(for: name))
            XCTAssertTrue((0..<BoxChip.palette.count).contains(first))
        }
        // Distinct fixtures observed to land on distinct hues.
        XCTAssertNotEqual(BoxChip.paletteIndex(for: "eric"), BoxChip.paletteIndex(for: "build-7"))
    }

    /// `contrastingForeground(for:)` (used by `SenderAvatar`'s initials,
    /// drawn on the RAW full-opacity fill — unlike this chip's own
    /// `textTint`, which is for text beside a pale ~18%-opacity capsule)
    /// must clear WCAG AA (4.5:1) against every palette entry's raw hue.
    /// Fixture names chosen so each pins a distinct index (mirrors
    /// `testChipFullPaletteSnapshots`).
    func testContrastingForegroundClearsWCAG_AA_forEveryPaletteEntry() {
        let names = ["dev-7", "romeo", "india", "charlie", "quebec",
                     "delta", "lima", "alpha", "echo", "foxtrot"]
        for (index, name) in names.enumerated() {
            XCTAssertEqual(BoxChip.paletteIndex(for: name), index,
                           "\(name) must pin palette index \(index)")
            let luminance = BoxChip.relativeLuminance(BoxChip.paletteRGB[index])
            let contrastWithWhite = 1.05 / (luminance + 0.05)
            let contrastWithBlack = (luminance + 0.05) / 0.05
            let bestRatio = max(contrastWithWhite, contrastWithBlack)
            XCTAssertGreaterThanOrEqual(bestRatio, 4.5,
                "palette index \(index) can't clear WCAG AA (4.5:1) with either white or black text — best available is \(bestRatio)")

            let fg = BoxChip.contrastingForeground(for: name)
            let expected: Color = contrastWithBlack > contrastWithWhite ? .black : .white
            XCTAssertEqual(fg, expected, "index \(index) must pick the higher-contrast option")
        }
    }

    /// Deterministic per-name, matching `paletteIndex`'s own contract —
    /// same name always resolves to the same foreground choice.
    func testContrastingForegroundIsDeterministic() {
        for name in ["eric", "dan-mac", "build-7", "", "🦊 box"] {
            XCTAssertEqual(BoxChip.contrastingForeground(for: name), BoxChip.contrastingForeground(for: name))
        }
    }

    /// Pins the two hues the review explicitly flagged as failing WCAG
    /// with white text (≈2.5:1 cyan, ≈2.1:1 mint) — both must resolve to
    /// black.
    func testContrastingForeground_cyanAndMint_resolveToBlack() {
        // "build-7" pins palette index 9 (mint); need a cyan (index 8)
        // fixture too — reuse the full-palette fixture list's mapping.
        let cyanFixture = "echo"    // index 8 per testChipFullPaletteSnapshots
        let mintFixture = "foxtrot" // index 9
        XCTAssertEqual(BoxChip.paletteIndex(for: cyanFixture), 8)
        XCTAssertEqual(BoxChip.paletteIndex(for: mintFixture), 9)
        XCTAssertEqual(BoxChip.contrastingForeground(for: cyanFixture), .black)
        XCTAssertEqual(BoxChip.contrastingForeground(for: mintFixture), .black)
    }

    // MARK: - textTint WCAG audit

    /// 0–255 sRGB triple, matching `BoxChip.paletteRGB`'s element type.
    private typealias RGB = (r: Double, g: Double, b: Double)

    /// Apple's documented DARK-appearance sRGB for each `palette` entry,
    /// same order — what the dynamic system colours resolve to in dark
    /// mode, where both the fill and the gated `.mix` operate. Test-local:
    /// production never needs these (the dynamic colours adapt on their
    /// own). Frozen alongside `palette`/`paletteRGB` — if either is ever
    /// reordered or extended, this one must move with it.
    private static let paletteDarkRGB: [RGB] = [
        (10, 132, 255),   // .blue
        (48, 209, 88),    // .green
        (255, 159, 10),   // .orange
        (191, 90, 242),   // .purple
        (64, 200, 224),   // .teal
        (255, 55, 95),    // .pink
        (94, 92, 230),    // .indigo
        (172, 142, 104),  // .brown
        (100, 210, 255),  // .cyan
        (99, 230, 226),   // .mint
    ]

    /// The darkest-margin surface the chip's fill sits on in dark mode:
    /// `matronBubbleBot`'s dark variant (MatronPalette.swift). The iOS
    /// plain-List background (pure black) is darker still, which only
    /// RAISES contrast for the light-mixed text, so this is the binding
    /// case; light mode's binding surface is plain white.
    private static let darkSurface: RGB = (38, 36, 33)

    private static func srgbToLinear(_ channel255: Double) -> Double {
        let c = channel255 / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB255(_ linear: Double) -> Double {
        let c = min(max(linear, 0), 1)
        return (c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255
    }

    /// sRGB → Oklab (https://bottosson.github.io/posts/oklab/).
    private static func oklab(_ rgb: RGB) -> (L: Double, a: Double, b: Double) {
        let r = srgbToLinear(rgb.r), g = srgbToLinear(rgb.g), b = srgbToLinear(rgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// `Color.mix(with:by:)`'s default `.perceptual` space modelled as
    /// Oklab interpolation — the same model the Android port's audit
    /// verified against (matron-android#38), where it reproduced Compose's
    /// rendered output to ±0.02 of contrast. Gamut-clamped like the real
    /// mix; 0–255 in, 0–255 out.
    private static func mixPerceptual(_ x: RGB, with y: RGB, by fraction: Double) -> RGB {
        let from = oklab(x), to = oklab(y)
        let L = from.L + (to.L - from.L) * fraction
        let a = from.a + (to.a - from.a) * fraction
        let b = from.b + (to.b - from.b) * fraction
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (linearToSRGB255(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                linearToSRGB255(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                linearToSRGB255(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// The chip's effective background: the tint at `BoxChip.fillAlpha`
    /// source-over the app surface, in gamma-encoded sRGB — how Core
    /// Animation composites sRGB layers, and the model WCAG tooling (and
    /// the Android audit) uses.
    private static func fill(_ tint: RGB, over surface: RGB) -> RGB {
        let alpha = BoxChip.fillAlpha
        return (tint.r * alpha + surface.r * (1 - alpha),
                tint.g * alpha + surface.g * (1 - alpha),
                tint.b * alpha + surface.b * (1 - alpha))
    }

    /// WCAG 2.1 contrast ratio between two opaque colours.
    private static func contrastRatio(_ x: RGB, _ y: RGB) -> Double {
        let lx = BoxChip.relativeLuminance(x), ly = BoxChip.relativeLuminance(y)
        return (max(lx, ly) + 0.05) / (min(lx, ly) + 0.05)
    }

    /// The mixed `textTint` (iOS 18 / macOS 15 path) must clear WCAG AA
    /// (4.5:1) for every palette entry in both schemes, over the fill the
    /// chip text actually sits on. Measured ratios this pins (light over
    /// white / dark over `darkSurface`):
    ///   blue 7.68/5.34, green 5.46/6.76, orange 5.42/6.61,
    ///   purple 7.89/5.37, teal 6.02/6.75, pink 7.06/5.34,
    ///   indigo 9.32/4.57, brown 7.33/5.54, cyan 5.97/7.11, mint 5.24/7.50.
    /// Dark indigo is the closest call: the SAME maths over Android's
    /// palette (light hues in both themes) fails at 4.32:1 — Apple only
    /// clears it because dark systemIndigo (94,92,230) is lighter, so any
    /// palette or fraction change must re-face this gate. The pre-mix OS
    /// fallback (raw tint, see `textTint`) is a documented floor well
    /// below AA (mint on the light fill ≈1.8:1) and is deliberately NOT
    /// asserted here.
    func testTextTintClearsWCAG_AA_overChipFillForEveryPaletteEntry() {
        XCTAssertEqual(Self.paletteDarkRGB.count, BoxChip.palette.count,
                       "dark palette table must move with the palette")
        let white: RGB = (255, 255, 255)
        let black: RGB = (0, 0, 0)
        for index in BoxChip.paletteRGB.indices {
            let lightBase = BoxChip.paletteRGB[index]
            let lightRatio = Self.contrastRatio(
                Self.mixPerceptual(lightBase, with: black, by: BoxChip.lightTextMixFraction),
                Self.fill(lightBase, over: white))
            XCTAssertGreaterThanOrEqual(lightRatio, 4.5,
                "palette index \(index) light text lands at \(lightRatio):1 over its fill — below WCAG AA")

            let darkBase = Self.paletteDarkRGB[index]
            let darkRatio = Self.contrastRatio(
                Self.mixPerceptual(darkBase, with: white, by: BoxChip.darkTextMixFraction),
                Self.fill(darkBase, over: Self.darkSurface))
            XCTAssertGreaterThanOrEqual(darkRatio, 4.5,
                "palette index \(index) dark text lands at \(darkRatio):1 over its fill — below WCAG AA")
        }
    }

    /// Visual baseline: two chips whose fixture names land on different
    /// palette hues, side by side, light/dark/axxxl.
    func testChipColorSnapshots() {
        let row = HStack(spacing: 6) {
            BoxChip("eric")  // palette index 4 (teal)
            BoxChip("greg")  // palette index 2 (orange)
        }
        .padding(8)
        assertVariants(of: row, named: "BoxChip_colors")
    }

    /// Every fixture name below hashes to a distinct palette index (0…9 in
    /// order), so this baseline shows the entire palette — text legibility
    /// over the tinted fill is reviewable for all ten hues in light, dark
    /// and accessibility variants at once.
    func testChipFullPaletteSnapshots() {
        let names = ["dev-7", "romeo", "india", "charlie", "quebec",
                     "delta", "lima", "alpha", "echo", "foxtrot"]
        for (index, name) in names.enumerated() {
            XCTAssertEqual(BoxChip.paletteIndex(for: name), index,
                           "\(name) must pin palette index \(index)")
        }
        let grid = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { ForEach(names.prefix(5), id: \.self) { BoxChip($0) } }
            HStack(spacing: 6) { ForEach(names.suffix(5), id: \.self) { BoxChip($0) } }
        }
        .padding(8)
        assertVariants(of: grid, named: "BoxChip_palette")
    }
}
