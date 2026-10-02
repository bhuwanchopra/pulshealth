import Foundation

/// How one value becomes one CSV cell. Shared by every CSV the package writes
/// (the wake-log diagnostics export and the on-device health export) so there
/// is one quoting rule rather than one per writer.
///
/// The rules are the product API's, deliberately: `server/api/export.go` writes
/// its CSV with Go's `encoding/csv` and `strconv.FormatFloat(v, 'f', -1, 64)`,
/// and `docs/export.md` promises that the on-device export of a dataset the
/// server also serves is the same file. So a cell is quoted exactly when Go
/// would quote it, a float has no exponent and no trailing zeros, and an
/// instant is whole epoch milliseconds.
///
/// Cells are written **verbatim**. A value beginning with `=`, `+`, `-` or `@`
/// is a formula to a spreadsheet, and the server documents that as a caveat
/// rather than rewriting the value (a leading apostrophe would corrupt a
/// negative number for every consumer that is not a spreadsheet). The device
/// does the same, which is what keeps the two exports byte-compatible.
enum CSVField {
    /// RFC 4180 quoting, triggered by the same conditions as Go's
    /// `csv.Writer.fieldNeedsQuotes`: a delimiter, a quote, a CR or LF, a
    /// leading space, or the literal `\.` (PostgreSQL's end-of-data marker).
    /// The empty string is left bare — it is how a null is written.
    static func escape(_ field: String) -> String {
        guard needsQuotes(field) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func needsQuotes(_ field: String) -> Bool {
        guard let first = field.unicodeScalars.first else { return false }
        if field == "\\." || first.properties.isWhitespace { return true }
        // Scalars, not Characters: "\r\n" is a single Character that equals
        // neither "\r" nor "\n", so a Character scan lets a CRLF through bare.
        return field.unicodeScalars.contains {
            $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r"
        }
    }

    /// One record: cells escaped, comma-joined, LF-terminated (Go's default).
    static func row(_ cells: [String]) -> String {
        cells.map(escape).joined(separator: ",") + "\n"
    }

    /// Shortest decimal that round-trips, never in exponent form and with no
    /// trailing `.0` — `72`, `0.00001`, `-3.5` — matching
    /// `strconv.FormatFloat(v, 'f', -1, 64)`. Swift's own description is the
    /// same shortest digit string, but spells whole numbers `72.0` and
    /// switches to `1e-05` outside 1e-4..<1e16, so it is re-pointed here.
    static func number(_ value: Double) -> String {
        guard value.isFinite else {
            // Unreachable from the sync pipeline (JSONEncoder refuses these on
            // the wire); spelled as Go spells them rather than trapping.
            return value.isNaN ? "NaN" : (value < 0 ? "-Inf" : "+Inf")
        }
        var text = "\(value)"
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            text = expand(mantissa: text[..<e], exponent: Int(text[text.index(after: e)...]) ?? 0)
        }
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    static func number(_ value: Double?) -> String { value.map(number) ?? "" }
    static func number(_ value: Int?) -> String { value.map(String.init) ?? "" }

    /// Whole epoch milliseconds, floored — what `time.Time.UnixMilli()` gives
    /// the server's export. (The wire carries the unrounded double.)
    static func epochMilliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)))
    }

    static func epochMilliseconds(_ date: Date?) -> String { date.map(epochMilliseconds) ?? "" }

    /// `1.5e-05` → `0.000015`; `1e+16` → `10000000000000000`.
    private static func expand(mantissa: Substring, exponent: Int) -> String {
        let negative = mantissa.hasPrefix("-")
        let unsigned = negative ? mantissa.dropFirst() : mantissa
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts.first ?? "0")
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        let digits = integer + fraction
        let point = integer.count + exponent

        var out: String
        if point <= 0 {
            out = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            out = digits + String(repeating: "0", count: point - digits.count)
        } else {
            let split = digits.index(digits.startIndex, offsetBy: point)
            out = digits[..<split] + "." + digits[split...]
        }
        if out.contains(".") {
            while out.hasSuffix("0") { out.removeLast() }
            if out.hasSuffix(".") { out.removeLast() }
        }
        return negative ? "-" + out : out
    }
}
