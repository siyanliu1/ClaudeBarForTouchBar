import Foundation

/// Accumulates bytes off a connection until a whole HTTP request has arrived.
///
/// The hook script posts with `curl -d @-`. curl withholds a body over roughly
/// 1 KB behind an `Expect: 100-continue` header until the server says it may
/// send — so a single `receive` returns the headers alone for exactly the
/// payloads that matter most (`Stop` carries the assistant's last message).
/// The headers already end in `\r\n\r\n`, so a naive reader sees a
/// well-formed request with an empty body and drops the event.
struct HTTPRequestBuffer {

    /// Everything received so far, headers included.
    private(set) var data = Data()

    /// Whether `100 Continue` has already been sent for this request, so it is
    /// sent at most once.
    var didSendContinue = false

    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    mutating func append(_ chunk: Data) {
        data.append(chunk)
    }

    /// The header block, or nil while it is still arriving.
    var headerText: String? {
        guard let terminator = data.range(of: Self.headerTerminator) else { return nil }
        return String(data: data[data.startIndex..<terminator.lowerBound], encoding: .utf8)
    }

    /// Everything after the header block, or nil while the headers are still arriving.
    var body: Data? {
        guard let terminator = data.range(of: Self.headerTerminator) else { return nil }
        return data[terminator.upperBound...]
    }

    /// Whether the client is holding its body back waiting for `100 Continue`.
    var expectsContinue: Bool {
        header(named: "expect")?.lowercased() == "100-continue"
    }

    /// The client's declared body length, when it declared one.
    var contentLength: Int? {
        header(named: "content-length").flatMap(Int.init)
    }

    /// True once the whole request has arrived: the header block, plus a body
    /// at least as long as any declared `Content-Length`.
    var isComplete: Bool {
        guard let body else { return false }
        guard let contentLength else { return true }
        return body.count >= contentLength
    }

    /// Whether a `100 Continue` is owed to the client right now.
    var needsContinue: Bool {
        headerText != nil && expectsContinue && !didSendContinue && !isComplete
    }

    /// Looks a header up by its lowercased name.
    ///
    /// Plain Foundation string APIs throughout: `split(separator:)` with a
    /// literal is overloaded three ways (Character, Collection, RegexComponent)
    /// and picked one that matched nothing here, which silently made every
    /// header invisible.
    private func header(named name: String) -> String? {
        guard let headerText else { return nil }
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.range(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard key == name else { continue }
            return String(line[colon.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
