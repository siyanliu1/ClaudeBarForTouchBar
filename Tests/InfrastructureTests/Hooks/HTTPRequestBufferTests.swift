import Testing
import Foundation
@testable import Infrastructure

@Suite("HTTPRequestBuffer Tests")
struct HTTPRequestBufferTests {

    private func headers(contentLength: Int, expectContinue: Bool = false) -> String {
        var lines = [
            "POST /hook HTTP/1.1",
            "Host: localhost:19847",
            "Content-Type: application/json",
            "Content-Length: \(contentLength)",
        ]
        if expectContinue {
            lines.append("Expect: 100-continue")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    // MARK: - The bug: headers alone looked like a whole request

    @Test
    func `headers alone are not a complete request when a body is declared`() {
        // This is exactly what curl sends first for a payload over ~1KB:
        // the header block, terminated by CRLFCRLF, with the body held back.
        let payload = #"{"session_id":"abc","hook_event_name":"Stop"}"#
        var buffer = HTTPRequestBuffer()
        buffer.append(Data(headers(contentLength: payload.utf8.count, expectContinue: true).utf8))

        #expect(buffer.headerText != nil)
        #expect(buffer.body?.isEmpty == true)
        #expect(buffer.isComplete == false)
    }

    @Test
    func `request completes once the withheld body arrives`() {
        let payload = #"{"session_id":"abc","hook_event_name":"Stop"}"#
        var buffer = HTTPRequestBuffer()
        buffer.append(Data(headers(contentLength: payload.utf8.count, expectContinue: true).utf8))
        buffer.append(Data(payload.utf8))

        #expect(buffer.isComplete)
        #expect(buffer.body == Data(payload.utf8))
    }

    @Test
    func `body split across several reads is reassembled`() {
        let payload = #"{"session_id":"abc","hook_event_name":"Stop","last_assistant_message":"..."}"#
        var buffer = HTTPRequestBuffer()
        buffer.append(Data(headers(contentLength: payload.utf8.count).utf8))

        let bytes = Array(payload.utf8)
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            #expect(buffer.isComplete == false)
            buffer.append(Data(bytes[chunk..<min(chunk + 7, bytes.count)]))
        }

        #expect(buffer.isComplete)
        #expect(buffer.body == Data(payload.utf8))
    }

    @Test
    func `header block split mid-way is reassembled`() {
        let payload = #"{"a":1}"#
        let raw = Array((headers(contentLength: payload.utf8.count) + payload).utf8)
        var buffer = HTTPRequestBuffer()

        buffer.append(Data(raw[0..<20]))
        #expect(buffer.headerText == nil)
        #expect(buffer.isComplete == false)

        buffer.append(Data(raw[20...]))
        #expect(buffer.isComplete)
        #expect(buffer.body == Data(payload.utf8))
    }

    // MARK: - 100-continue handshake

    @Test
    func `a client waiting on 100-continue is owed one, exactly once`() {
        var buffer = HTTPRequestBuffer()
        buffer.append(Data(headers(contentLength: 4096, expectContinue: true).utf8))

        #expect(buffer.expectsContinue)
        #expect(buffer.needsContinue)

        buffer.didSendContinue = true
        #expect(buffer.needsContinue == false)
    }

    @Test
    func `no continue is owed when the client did not ask for one`() {
        var buffer = HTTPRequestBuffer()
        buffer.append(Data(headers(contentLength: 4096).utf8))

        #expect(buffer.expectsContinue == false)
        #expect(buffer.needsContinue == false)
    }

    @Test
    func `no continue is owed before the headers have arrived`() {
        var buffer = HTTPRequestBuffer()
        buffer.append(Data("POST /hook HTTP/1.1\r\nExpect: 100-cont".utf8))

        #expect(buffer.headerText == nil)
        #expect(buffer.needsContinue == false)
    }

    // MARK: - Header parsing

    @Test
    func `the header block is exactly what precedes the blank line`() {
        // Pinned deliberately: when header lookup silently returned nil for
        // everything, this is the assertion that would have said whether the
        // block itself was wrong or only the parsing of it.
        var buffer = HTTPRequestBuffer()
        buffer.append(Data(headers(contentLength: 44).utf8))

        #expect(buffer.headerText == "POST /hook HTTP/1.1\r\nHost: localhost:19847\r\nContent-Type: application/json\r\nContent-Length: 44")
        #expect(buffer.contentLength == 44)
    }

    @Test
    func `content length is read case-insensitively and ignores surrounding space`() {
        var buffer = HTTPRequestBuffer()
        buffer.append(Data("POST /hook HTTP/1.1\r\ncontent-length:   17  \r\n\r\n".utf8))

        #expect(buffer.contentLength == 17)
    }

    @Test
    func `a request with no declared length is complete as soon as headers end`() {
        // Nothing in the hook path sends one, but a bodyless GET must not hang
        // the connection open waiting for bytes that will never come.
        var buffer = HTTPRequestBuffer()
        buffer.append(Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))

        #expect(buffer.contentLength == nil)
        #expect(buffer.isComplete)
    }
}
