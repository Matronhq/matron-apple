import XCTest
import SwiftUI
import UIKit
import MatronModels
import MatronDesignSystem
@testable import Matron

/// SCRATCH DIAGNOSTIC, never merged. Prints where hosted timeline content
/// ends up, with and without `SafeAreaShield`, for a cell clear of the safe
/// area (y 300) and one under it (y 0). Read the `SAFEAREA-DIAG` lines.
@MainActor
final class SafeAreaDiagTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)

    private func factory() -> HostedRowFactory {
        HostedRowFactory(viewModel: TimelineFixtures.viewModel(LiveTimelineFixture()), actions: .inert,
                         environment: TimelineHostedEnvironment())
    }

    private func content(_ body: String, pills: [ConversationLinkRef] = []) -> TextRowContent {
        TextRowContent(itemID: "1", body: body, isOwn: false, sendState: .sent, timestamp: TimelineFixtures.base,
                       avatarSender: nil, senderLabel: "matron", pills: pills)
    }

    final class FrameBox { var global: CGRect = .null }
    final class MarkerView: UIView {}

    struct Marker: UIViewRepresentable {
        func makeUIView(context: Context) -> MarkerView { MarkerView() }
        func updateUIView(_ view: MarkerView, context: Context) {}
    }

    struct Pieces: View {
        let box: FrameBox
        var body: some View {
            Text("Thinking…")
                .padding(6)
                .background(Capsule().fill(Color.red))
                .background(Marker())
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    box.global = frame
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Mounting

    private func mount(_ view: UIView, atY y: CGFloat, configure: () -> Void = {}) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        view.frame.origin.y = y
        controller.view.addSubview(view)
        configure()
        for _ in 0..<8 {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Printing

    private func fmt(_ r: CGRect) -> String {
        String(format: "[%.1f %.1f %.1f %.1f]", r.minX, r.minY, r.width, r.height)
    }

    private func fmt(_ i: UIEdgeInsets) -> String {
        String(format: "(t%.1f l%.1f b%.1f r%.1f)", i.top, i.left, i.bottom, i.right)
    }

    private func dump(_ label: String, _ view: UIView, box: FrameBox? = nil) {
        func line(_ text: String) { print("SAFEAREA-DIAG \(label) \(text)") }
        line("cell frame=\(fmt(view.frame)) safeArea=\(fmt(view.safeAreaInsets))")
        func visitView(_ parent: UIView, depth: Int) {
            for sub in parent.subviews {
                let frame = sub.convert(sub.bounds, to: view)
                line("view d\(depth) \(type(of: sub)) \(fmt(frame)) safeArea=\(fmt(sub.safeAreaInsets))")
                visitView(sub, depth: depth + 1)
            }
        }
        visitView(view, depth: 1)
        func visitLayer(_ parent: CALayer, depth: Int) {
            for sub in parent.sublayers ?? [] {
                let frame = sub.convert(sub.bounds, to: view.layer)
                let owner = (sub.delegate as? UIView).map { "view:\(type(of: $0))" } ?? "bare"
                line("layer d\(depth) \(type(of: sub)) \(fmt(frame)) \(owner) contents=\(sub.contents != nil)")
                visitLayer(sub, depth: depth + 1)
            }
        }
        visitLayer(view.layer, depth: 1)
        if let box {
            line("swiftui-global \(fmt(box.global)) minus-cell-origin y=\(String(format: "%.1f", box.global.minY - view.frame.minY))")
        }
        let map = bitmap(view)
        line("pixels ink=\(fmt(inkBounds(map))) red=\(fmt(redBounds(map)))")
    }

    // MARK: - Pixels

    struct Bitmap {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        let scale: CGFloat = 2
    }

    private func bitmap(_ view: UIView) -> Bitmap {
        let scale: CGFloat = 2
        let width = Int((view.bounds.width * scale).rounded(.up))
        let height = Int((view.bounds.height * scale).rounded(.up))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let cgImage = image.cgImage, width > 0, height > 0 else {
            return Bitmap(pixels: [], width: 0, height: 0)
        }
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Bitmap(pixels: pixels, width: width, height: height)
    }

    private func bounds(_ map: Bitmap, where matches: (Int) -> Bool) -> CGRect {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<map.height {
            for x in 0..<map.width where matches((y * map.width + x) * 4) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .null }
        return CGRect(x: CGFloat(minX) / map.scale, y: CGFloat(minY) / map.scale,
                      width: CGFloat(maxX - minX + 1) / map.scale, height: CGFloat(maxY - minY + 1) / map.scale)
    }

    /// Everything that differs from the top left pixel.
    private func inkBounds(_ map: Bitmap) -> CGRect {
        guard map.pixels.count >= 4 else { return .null }
        let base = Array(map.pixels[0..<4])
        return bounds(map) { offset in
            (0..<4).contains { abs(Int(map.pixels[offset + $0]) - Int(base[$0])) > 8 }
        }
    }

    private func redBounds(_ map: Bitmap) -> CGRect {
        bounds(map) { offset in
            map.pixels[offset] > 180 && map.pixels[offset + 1] < 110 && map.pixels[offset + 2] < 110
                && map.pixels[offset + 3] > 200
        }
    }

    private func difference(_ label: String, _ clear: UIView, _ under: UIView) {
        let first = bitmap(clear), second = bitmap(under)
        guard first.width == second.width, first.height == second.height, !first.pixels.isEmpty else {
            print("SAFEAREA-DIAG \(label) pixel-difference sizes differ or empty: "
                  + "\(first.width)x\(first.height) vs \(second.width)x\(second.height)")
            return
        }
        var count = 0
        let box = bounds(first) { offset in
            let differs = (0..<4).contains { abs(Int(first.pixels[offset + $0]) - Int(second.pixels[offset + $0])) > 8 }
            if differs { count += 1 }
            return differs
        }
        print("SAFEAREA-DIAG \(label) pixel-difference clear-vs-under count=\(count) bounds=\(fmt(box))")
    }

    // MARK: - The cases

    private func hostedRow(_ tag: String) throws {
        func cell(atY y: CGFloat) throws -> (HostedRowCell, FrameBox) {
            let box = FrameBox()
            let cell = HostedRowCell(frame: CGRect(x: 0, y: 0, width: 393, height: 40))
            cell.configure(rowID: "row-1", expectedHeight: 40, content: AnyView(Pieces(box: box)))
            try mount(cell, atY: y)
            return (cell, box)
        }
        let clear = try cell(atY: 300), under = try cell(atY: 0)
        dump("\(tag) row clear", clear.0, box: clear.1)
        dump("\(tag) row under", under.0, box: under.1)
        difference("\(tag) row", clear.0, under.0)
    }

    private func footer(_ tag: String) throws {
        func footer(atY y: CGFloat) throws -> (TimelineFooterView, FrameBox) {
            let box = FrameBox()
            let footer = TimelineFooterView(frame: CGRect(x: 0, y: 0, width: 393, height: 30))
            footer.configure(content: AnyView(Pieces(box: box)))
            try mount(footer, atY: y)
            return (footer, box)
        }
        let clear = try footer(atY: 300), under = try footer(atY: 0)
        dump("\(tag) footer clear", clear.0, box: clear.1)
        dump("\(tag) footer under", under.0, box: under.1)
        difference("\(tag) footer", clear.0, under.0)
    }

    private func textCell(_ tag: String, _ name: String, _ content: TextRowContent) throws {
        func cell(atY y: CGFloat) throws -> TextMessageCell {
            let factory = factory()
            guard case .text(let render) = TimelineMeasurer(factory: factory).measure(
                .text(content), width: 393, style: style) else { throw XCTSkip("text rows measure as renders") }
            let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: 393, height: render.layout.rowHeight))
            try mount(cell, atY: y) {
                cell.configure(render: render, factory: factory, onRetry: { _ in })
            }
            return cell
        }
        let clear = try cell(atY: 300), under = try cell(atY: 0)
        dump("\(tag) \(name) clear", clear)
        dump("\(tag) \(name) under", under)
        difference("\(tag) \(name)", clear, under)
    }

    func test_printWhereHostedContentEndsUp() throws {
        #if compiler(>=6.2)
        let toolchain = "compiler>=6.2 (Xcode 26)"
        #else
        let toolchain = "compiler<6.2 (Xcode 16)"
        #endif
        print("SAFEAREA-DIAG env os=\(UIDevice.current.systemVersion) \(toolchain)")
        defer { TimelineHosting.shieldsHostedContent = true }
        for shield in [true, false] {
            TimelineHosting.shieldsHostedContent = shield
            let tag = shield ? "SHIELD" : "BARE"
            try hostedRow(tag)
            try footer(tag)
            try textCell(tag, "pills", content("See [Auth refactor](matron://convo/auth-1).",
                                               pills: [ConversationLinkRef(id: "auth-1", text: "Auth refactor")]))
            try textCell(tag, "table", content("| Name | Value |\n| --- | --- |\n| one | 1 |\n| two | 2 |"))
        }
    }
}
