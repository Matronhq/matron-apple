import XCTest
import SwiftUI
@testable import MatronDesignSystem

/// Snapshot coverage for the media & links browser sheet body: each tab
/// populated and empty, plus the load-failure state. Thumbnails resolve to
/// nil (placeholder rendering) so the grid is deterministic — image bytes
/// never enter a snapshot.
final class MediaBrowserSnapshotTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_755_000_000)

    private var mediaCells: [MediaBrowserView.MediaCell] {
        [
            .init(id: 4, url: URL(string: "https://j.example/media/a"), expired: false),
            .init(id: 3, url: URL(string: "https://j.example/media/e"), expired: false, isLoading: true),
            .init(id: 2, url: URL(string: "https://j.example/media/b"), expired: false),
            .init(id: 1, url: nil, expired: true),
        ]
    }
    private var fileRows: [MediaBrowserView.FileRow] {
        [
            .init(id: 5, url: URL(string: "https://j.example/media/c"), name: "report.pdf",
                  sizeBytes: 1_234_567, expired: false, isLoading: false),
            .init(id: 4, url: URL(string: "https://j.example/media/d"), name: "trace.log",
                  sizeBytes: 88, expired: false, isLoading: true),
            .init(id: 3, url: nil, name: "old.zip", sizeBytes: 999, expired: true, isLoading: false),
        ]
    }
    private var linkRows: [MediaBrowserView.LinkRow] {
        [
            .init(id: "https://example.com/pr/42", url: URL(string: "https://example.com/pr/42")!,
                  context: "opened https://example.com/pr/42 for review", date: date),
            .init(id: "https://docs.example", url: URL(string: "https://docs.example")!,
                  context: "docs are at https://docs.example", date: date),
        ]
    }

    private func frame<V: View>(_ view: V) -> some View {
        view.frame(width: 600, height: 480)
    }

    func test_mediaTab_populated() {
        assertVariants(of: frame(MediaBrowserView(
            media: mediaCells, files: [], links: [], initialTab: .media)),
            named: "media-populated")
    }
    func test_mediaTab_empty() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], initialTab: .media)),
            named: "media-empty")
    }
    func test_filesTab_populated() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: fileRows, links: [], initialTab: .files)),
            named: "files-populated")
    }
    func test_filesTab_empty() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], initialTab: .files)),
            named: "files-empty")
    }
    func test_linksTab_populated() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: linkRows, initialTab: .links)),
            named: "links-populated")
    }
    func test_linksTab_empty() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], initialTab: .links)),
            named: "links-empty")
    }
    func test_loadFailed() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], loadFailed: true)),
            named: "load-failed")
    }
}
