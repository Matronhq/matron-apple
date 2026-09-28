import XCTest
import SwiftUI
import UIKit
@testable import Matron

/// SCRATCH: which way of hosting keeps content put under a safe area.
@MainActor
final class ScratchSafeAreaVariantsTests: XCTestCase {
    struct Pieces: View {
        var body: some View {
            Text("Thinking…")
                .padding(6)
                .background(Capsule().fill(Color.red))
        }
    }

    final class Shield: UIView {
        override var safeAreaInsets: UIEdgeInsets { .zero }
    }

    final class ShieldedHost: UIView {
        let hosted: UIView
        init(frame: CGRect, hosted: UIView) {
            self.hosted = hosted
            super.init(frame: frame)
            addSubview(hosted)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var safeAreaInsets: UIEdgeInsets { .zero }
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted.frame = bounds
        }
    }

    private func place(_ view: UIView, atY y: CGFloat) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        view.frame.origin.y = y
        controller.view.addSubview(view)
        for _ in 0..<5 {
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func pieces(in view: UIView) -> [String] {
        var out: [String] = []
        func visit(_ parent: UIView, hosted: Bool) {
            for subview in parent.subviews {
                let isHost = String(describing: type(of: subview)).contains("UIHosting")
                if hosted {
                    let f = subview.convert(subview.bounds, to: view)
                    out.append(String(format: "%@ %.1f %.1f %.1f %.1f", String(describing: type(of: subview)),
                                      f.minX, f.minY, f.width, f.height))
                }
                visit(subview, hosted: hosted || isHost)
            }
        }
        visit(view, hosted: false)
        return out
    }

    private func report(_ name: String, height: CGFloat, make: (CGRect) -> UIView) throws {
        let frame = CGRect(x: 0, y: 0, width: 393, height: height)
        let clear = make(frame)
        try place(clear, atY: 300)
        let under = make(frame)
        try place(under, atY: 0)
        let a = pieces(in: clear), b = pieces(in: under)
        print("SAVAR \(name) h=\(Int(height)) same=\(a == b) underSafe=\(under.safeAreaInsets.top) clear=\(a) under=\(b)")
    }

    private func contentView<V: View>(_ view: V, frame: CGRect) -> UIView {
        let hosted = UIHostingConfiguration { view }.margins(.all, 0).makeContentView()
        hosted.frame = frame
        return hosted
    }

    func test_SCRATCH_variants() throws {
        for height in [40, 100] as [CGFloat] {
            try report("A plain", height: height) { frame in
                self.contentView(Pieces().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), frame: frame)
            }
            try report("B ignoresSafeArea outside frame", height: height) { frame in
                self.contentView(Pieces().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea(), frame: frame)
            }
            try report("C ignoresSafeArea inside frame", height: height) { frame in
                self.contentView(Pieces().ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), frame: frame)
            }
            try report("D clear overlay ignoring", height: height) { frame in
                self.contentView(Color.clear.ignoresSafeArea().overlay(alignment: .topLeading) { Pieces() }, frame: frame)
            }
            try report("E shield container", height: height) { frame in
                let hosted = UIHostingConfiguration {
                    Pieces().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.margins(.all, 0).makeContentView()
                return ShieldedHost(frame: frame, hosted: hosted)
            }
            try report("F hosting controller safeAreaRegions=[]", height: height) { frame in
                let host = UIHostingController(rootView: Pieces()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
                host.safeAreaRegions = []
                host.sizingOptions = []
                host.view.backgroundColor = .clear
                host.view.frame = frame
                return host.view
            }
            try report("G geometry offset", height: height) { frame in
                self.contentView(GeometryReader { proxy in
                    Pieces()
                        .frame(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                               height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom,
                               alignment: .topLeading)
                        .offset(x: -proxy.safeAreaInsets.leading, y: -proxy.safeAreaInsets.top)
                }, frame: frame)
            }
        }
    }
}
