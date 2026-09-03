import Foundation
import Domain

/// Parses Claude Code hook event JSON payloads into SessionEvent domain objects.
public enum SessionEventParser {
    /// Parses raw JSON data from a hook HTTP request into a SessionEvent.
    /// Claude Code sends JSON with fields: session_id, hook_event_name, cwd, etc.
    public static func parse(_ data: Data) -> SessionEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let sessionId = json["session_id"] as? String,
              let eventNameRaw = json["hook_event_name"] as? String,
              let eventName = SessionEvent.EventName(rawValue: eventNameRaw) else {
            return nil
        }

        let cwd = json["cwd"] as? String ?? ""

        return SessionEvent(
            sessionId: sessionId,
            eventName: eventName,
            cwd: cwd,
            message: text(json["message"]),
            transcriptPath: json["transcript_path"] as? String,
            userPrompt: text(json["prompt"]),
            lastAssistantMessage: text(json["last_assistant_message"]),
            notificationType: json["notification_type"] as? String
        )
    }

    /// Free text from a hook payload, capped so a pasted novel of a prompt does
    /// not sit in memory for the life of the session. Nothing displays more than
    /// a line of it.
    private static let maxTextLength = 500

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return String(string.prefix(maxTextLength))
    }
}
