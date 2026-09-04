#if ENABLE_TOUCHBAR
import AppKit
import Domain

/// The two quota lines at the right of the board, 125 × 26 pt.
///
/// ```
///  Claude 90%/15%/30%
///  Codex  80%/45%
/// ```
///
/// Every number is coloured by its own status, so the line reads as five
/// separate answers rather than one sentence. Tapping anywhere in the column
/// refreshes Claude and Codex — the board's only refresh affordance, and it
/// costs no width.
final class QuotaColumnView: NSView {
    private let claudeLine = NSTextField(labelWithString: "")
    private let codexLine = NSTextField(labelWithString: "")

    /// Called when the user taps the column.
    var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QuotaColumnView is never loaded from a nib")
    }

    func configure(with board: TouchBarBoard, palette: TouchBarPalette) {
        claudeLine.attributedStringValue = line(
            label: "Claude",
            labelColor: palette.claudeLabel,
            cells: board.claude,
            palette: palette,
            isRefreshing: board.isRefreshing
        )
        codexLine.attributedStringValue = line(
            label: "Codex",
            labelColor: palette.codexLabel,
            cells: board.codex,
            palette: palette,
            isRefreshing: board.isRefreshing
        )
    }

    // MARK: - Private

    private func build() {
        for line in [claudeLine, codexLine] {
            line.font = TouchBarFont.quota
            line.lineBreakMode = .byClipping
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
        }

        NSLayoutConstraint.activate([
            claudeLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            claudeLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            claudeLine.topAnchor.constraint(equalTo: topAnchor),

            codexLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            codexLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            codexLine.topAnchor.constraint(equalTo: claudeLine.bottomAnchor, constant: 1),
            codexLine.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @objc private func tapped() {
        onTap?()
    }

    private func line(
        label: String,
        labelColor: NSColor,
        cells: [TouchBarBoard.QuotaCell],
        palette: TouchBarPalette,
        isRefreshing: Bool
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: label + " ",
            attributes: [.font: TouchBarFont.quota, .foregroundColor: labelColor]
        )

        for (index, cell) in cells.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(
                    string: "/",
                    attributes: [.font: TouchBarFont.quota, .foregroundColor: palette.endedSecondaryText]
                ))
            }
            text.append(NSAttributedString(
                string: display(cell),
                attributes: [
                    .font: TouchBarFont.quota,
                    // Dimming the whole line while syncing says "these numbers
                    // are being replaced" without moving anything, which on a
                    // bar this small matters more than it sounds.
                    .foregroundColor: isRefreshing ? palette.dimmedText : color(of: cell, in: palette),
                ]
            ))
        }

        return text
    }

    private func display(_ cell: TouchBarBoard.QuotaCell) -> String {
        guard let percent = cell.percent else { return "–" }
        return "\(Int(percent.rounded()))%"
    }

    private func color(of cell: TouchBarBoard.QuotaCell, in palette: TouchBarPalette) -> NSColor {
        guard let status = cell.status else { return palette.endedSecondaryText }
        return palette.color(for: status)
    }
}
#endif
