import Foundation

extension JournalAPI {
    /// The words of a voice note the journal transcribed at upload
    /// (`GET /media/:id/transcript?wait=N`, `wait` at most 30 seconds):
    /// `{status: none|pending|done|failed, transcript?}`. `nil` for
    /// anything but `done` with words: a journal with transcription off
    /// (`none`), one still working (`pending` after the wait), a failure,
    /// or a journal that predates the route (404).
    public func mediaTranscript(blobRef: String, waitSeconds: Int) async throws -> String? {
        let (data, response) = try await rawRequest(
            path: "/media/\(Self.pathSegment(blobRef))/transcript", method: "GET", body: nil,
            query: [URLQueryItem(name: "wait", value: String(max(0, min(30, waitSeconds))))])
        guard response.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["status"] as? String == "done",
              let transcript = (obj["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty
        else { return nil }
        return transcript
    }
}
