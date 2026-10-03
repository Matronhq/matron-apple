import Foundation

/// One cloud voice the journal offers (`GET /tts/voices`).
public struct TTSVoice: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let locale: String
    public let gender: String

    public init(id: String, name: String, locale: String = "en-GB", gender: String = "") {
        self.id = id; self.name = name; self.locale = locale; self.gender = gender
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: json["name"] as? String ?? id, locale: json["locale"] as? String ?? "",
                  gender: json["gender"] as? String ?? "")
    }
}

public struct TTSVoices: Equatable, Sendable {
    public let voices: [TTSVoice]
    /// The journal's own default, used when the user has not chosen.
    public let defaultVoiceID: String?

    public init(voices: [TTSVoice], defaultVoiceID: String?) {
        self.voices = voices; self.defaultVoiceID = defaultVoiceID
    }
}

public enum TTSError: Error, Equatable, Sendable {
    /// `GET /tts/voices` answered 404 (a journal that predates `/tts`) or
    /// 501 (no Azure key): this journal has no cloud voice. The only
    /// answer worth remembering for the session.
    case unavailable
    /// Any other answer that is not a clip: 400 `bad_request` /
    /// `unknown_voice`, 403 `forbidden`, 404 (an old journal), 413, 429
    /// `tts_budget_exceeded`, 501 `tts_unconfigured`, 502 `tts_failed`,
    /// 503 `tts_busy`, an empty body. Say the same text with the
    /// on-device voice, and ask again next time.
    case failed(status: Int, code: String?)
}

/// The journal's text-to-speech surface (spec 2026-10-03 §2), as a
/// protocol so the player tests against a fake.
public protocol SpeechSynthesising: Sendable {
    func ttsVoices() async throws -> TTSVoices
    /// The clip for `text` as MP3 bytes. `voice` nil = the journal's default.
    func tts(text: String, voice: String?) async throws -> Data
}

extension JournalAPI: SpeechSynthesising {
    /// `POST /tts` refuses longer text.
    public static let ttsTextLimit = 2_000

    /// `text` cut to what `POST /tts` accepts. The journal counts UTF-16
    /// units, so a character outside the basic plane counts twice; the
    /// cut falls between characters, never inside one.
    static func ttsLimited(_ text: String) -> String {
        guard text.utf16.count > ttsTextLimit else { return text }
        var units = 0
        return String(text.prefix { character in
            units += character.utf16.count
            return units <= ttsTextLimit
        })
    }

    static func decodeVoices(_ obj: [String: Any]) -> TTSVoices {
        let voices = (obj["voices"] as? [[String: Any]] ?? []).compactMap(TTSVoice.init(json:))
        return TTSVoices(voices: voices, defaultVoiceID: obj["default"] as? String)
    }

    private static func errorCode(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
    }

    public func ttsVoices() async throws -> TTSVoices {
        let (data, response) = try await rawRequest(path: "/tts/voices", method: "GET", body: nil)
        switch response.statusCode {
        case 200:
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw TTSError.failed(status: 200, code: "malformed")
            }
            return Self.decodeVoices(obj)
        case 404, 501:
            throw TTSError.unavailable
        default:
            throw TTSError.failed(status: response.statusCode, code: Self.errorCode(data))
        }
    }

    /// `format` is left to the journal's default (MP3, 24 kHz): the `wav`
    /// form is for notification sounds, a later phase. The response's
    /// `ETag` is the audio's SHA-256 and the journal does not act on
    /// `If-None-Match`, so nothing here revalidates: the phone caches by
    /// its own key (`SpeechClipCache`).
    public func tts(text: String, voice: String?) async throws -> Data {
        var body: [String: Any] = ["text": Self.ttsLimited(text)]
        if let voice { body["voice"] = voice }
        let (data, response) = try await rawRequest(path: "/tts", method: "POST", body: body)
        guard response.statusCode == 200, !data.isEmpty else {
            throw TTSError.failed(status: response.statusCode, code: Self.errorCode(data))
        }
        return data
    }
}
