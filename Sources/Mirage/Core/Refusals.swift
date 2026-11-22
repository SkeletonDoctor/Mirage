import Foundation

/// A refusal rate that a model's author published on its Hugging Face card.
/// These are the author's own measurements on their own test prompts; Mirage does not verify them.
struct RefusalReport: Equatable, Sendable {
    /// Share of test prompts refused, 0 to 1.
    let rate: Double
    /// The figure as written, for example "3/100" or "0%".
    let figure: String
    /// The line of the card it came from.
    let snippet: String
    /// True when the figure was found on the base model's card rather than this conversion's own.
    var fromBase = false

    var percentText: String {
        let p = rate * 100
        return p == p.rounded() ? "\(Int(p))%" : String(format: "%.1f%%", p)
    }
}

enum RefusalParser {
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }

    private static let fractionArrow = regex(#"(\d+)\s*/\s*(\d+)\s*(?:→|->|=>|\bto\b)\s*(\d+)\s*/\s*(\d+)"#)
    private static let percentArrow = regex(#"(\d+(?:\.\d+)?)\s*%\s*(?:→|->|=>|\bto\b)\s*(\d+(?:\.\d+)?)\s*%"#)
    private static let fraction = regex(#"(\d+)\s*/\s*(\d+)"#)
    private static let compliancePercent = regex(#"(\d+(?:\.\d+)?)\s*%\s+(?:[\w-]+\s+){0,2}compliance"#)
    private static let compliancePercentAfter = regex(#"compl\w*\D{0,40}?(\d+(?:\.\d+)?)\s*%"#)
    private static let anyPercent = regex(#"(?<![-+±−\d.])(\d+(?:\.\d+)?)\s*%"#)

    /// Finds the lowest refusal rate a model card states, or nil when it gives no figure.
    static func parse(_ card: String) -> RefusalReport? {
        var best: RefusalReport?
        func consider(_ rate: Double, _ figure: String, _ line: String) {
            guard rate >= 0, rate <= 1 else { return }
            if best == nil || rate < best!.rate {
                let clean = line.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " >-#\t"))
                best = RefusalReport(rate: rate, figure: figure, snippet: String(clean.prefix(260)))
            }
        }
        for raw in card.split(whereSeparator: \.isNewline).prefix(1500) {
            let line = String(raw)
            let lower = line.lowercased()
            guard lower.contains("refus") || lower.contains("complian") || lower.contains("comply") else { continue }
            // "Over-refusal" measures harmless prompts being refused, which is a different thing.
            if lower.contains("over-refus") || lower.contains("overrefus") { continue }
            // A line that only talks about compliance counts answers, not refusals.
            let complianceLine = !lower.contains("refus")
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            func group(_ m: NSTextCheckingResult, _ i: Int) -> String { ns.substring(with: m.range(at: i)) }
            /// Whether the words right after a match say it counts answers rather than refusals.
            func isCompliance(after m: NSTextCheckingResult) -> Bool {
                let start = m.range.location + m.range.length
                let tail = ns.substring(with: NSRange(location: start, length: min(14, ns.length - start))).lowercased()
                return complianceLine || tail.contains("compl")
            }

            var usedArrow = false
            for m in fractionArrow.matches(in: line, range: whole) {
                guard let n = Double(group(m, 3)), let d = Double(group(m, 4)), d >= 10, n <= d else { continue }
                usedArrow = true
                let rate = isCompliance(after: m) ? 1 - n / d : n / d
                consider(rate, isCompliance(after: m) ? "\(Int(d - n))/\(Int(d))" : "\(Int(n))/\(Int(d))", line)
            }
            for m in percentArrow.matches(in: line, range: whole) {
                guard let p = Double(group(m, 2)), p <= 100 else { continue }
                usedArrow = true
                let rate = isCompliance(after: m) ? 1 - p / 100 : p / 100
                consider(rate, String(format: "%g%%", rate * 100), line)
            }
            if usedArrow { continue }       // a before → after pair is the clearest statement on the line

            for m in fraction.matches(in: line, range: whole) {
                guard let n = Double(group(m, 1)), let d = Double(group(m, 2)), d >= 10, n <= d else { continue }
                let rate = isCompliance(after: m) ? 1 - n / d : n / d
                consider(rate, isCompliance(after: m) ? "\(Int(d - n))/\(Int(d))" : "\(Int(n))/\(Int(d))", line)
            }
            for m in compliancePercent.matches(in: line, range: whole) {
                guard let p = Double(group(m, 1)), p <= 100 else { continue }
                consider(1 - p / 100, String(format: "%g%%", 100 - p), line)
            }
            if complianceLine {
                for m in compliancePercentAfter.matches(in: line, range: whole) {
                    guard let p = Double(group(m, 1)), p <= 100 else { continue }
                    consider(1 - p / 100, String(format: "%g%%", 100 - p), line)
                }
            }
            if !complianceLine {
                // A refusal line or table row often lists the original model first and the unlocked one after;
                // the lowest percentage on it is the unlocked model's. Signed values are changes, not rates.
                for m in anyPercent.matches(in: line, range: whole) {
                    guard let p = Double(group(m, 1)), p <= 100 else { continue }
                    consider(p / 100, String(format: "%g%%", p), line)
                }
            }
        }
        return best
    }

    /// The repos a conversion says it was made from, taken from its `base_model:` tags.
    static func baseModels(tags: [String]) -> [String] {
        var out: [String] = []
        for tag in tags where tag.hasPrefix("base_model:") {
            let repo = tag.split(separator: ":").last.map(String.init) ?? ""
            if repo.contains("/"), !out.contains(repo) { out.append(repo) }
        }
        return out
    }
}
