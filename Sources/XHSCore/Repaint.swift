/// Repaints the near-white backgrounds a harness asks for (the band behind a user message in Claude Code's
/// light theme, for one) to the pane's paper shade, so a white block never lands on the paper. Only
/// background colours change; text colours and every other colour stay the harness's own.
public enum Repaint {
    /// A background is near white when every channel is at least this bright and they differ by at most `spread`.
    static let floor = 216
    static let spread = 16

    /// Returns `carry` + `input` with each near-white background in an SGR sequence replaced by `shade`.
    /// A control sequence cut off at the end of `input` waits in `carry` for the next call.
    public static func apply(_ input: [UInt8], carry: inout [UInt8], shade: (red: Int, green: Int, blue: Int)) -> [UInt8] {
        let data = carry + input
        carry = []
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            guard data[i] == 0x1B else { out.append(data[i]); i += 1; continue }
            // ESC at the very end, or ESC [ with no final byte yet: wait for more, within reason.
            if i + 1 == data.count { carry = [0x1B]; return out }
            guard data[i + 1] == UInt8(ascii: "[") else { out.append(data[i]); i += 1; continue }
            var j = i + 2
            while j < data.count, data[j] < 0x40 || data[j] > 0x7E { j += 1 }
            if j == data.count {
                if data.count - i <= 64 { carry = Array(data[i...]); return out }
                out.append(data[i]); i += 1; continue
            }
            if data[j] == UInt8(ascii: "m") {
                out += sgr(Array(data[(i + 2)..<j]), shade: shade)
            } else {
                out += data[i...j]
            }
            i = j + 1
        }
        return out
    }

    /// One SGR sequence, rebuilt with near-white backgrounds replaced.
    static func sgr(_ params: [UInt8], shade: (red: Int, green: Int, blue: Int)) -> [UInt8] {
        let text = String(decoding: params, as: UTF8.self)
        // Private sequences (ESC[>4;2m), colon-separated sub-parameters (4:3, 48:2::r:g:b) and anything
        // else that is not plain numbers pass through untouched.
        let plain = params.allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: ";") }
        guard plain, text.contains("4") || text.contains("107") else { return [0x1B, UInt8(ascii: "[")] + params + [UInt8(ascii: "m")] }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var out: [String] = []
        var k = 0
        let replacement = "48;2;\(shade.red);\(shade.green);\(shade.blue)"
        while k < parts.count {
            let p = parts[k]
            if p == 48, k + 4 < parts.count, parts[k + 1] == 2 {
                let (r, g, b) = (parts[k + 2], parts[k + 3], parts[k + 4])
                out.append(isNearWhite(r, g, b) ? replacement : "48;2;\(r);\(g);\(b)")
                k += 5
            } else if p == 48, k + 2 < parts.count, parts[k + 1] == 5 {
                let (r, g, b) = xterm(parts[k + 2])
                out.append(isNearWhite(r, g, b) ? replacement : "48;5;\(parts[k + 2])")
                k += 3
            } else if p == 107 {
                out.append(replacement)
                k += 1
            } else if p == 38 || p == 58, k + 1 < parts.count, parts[k + 1] == 2 {
                out.append(parts[k..<min(k + 5, parts.count)].map(String.init).joined(separator: ";"))
                k += 5
            } else if p == 38 || p == 58, k + 1 < parts.count, parts[k + 1] == 5 {
                out.append(parts[k..<min(k + 3, parts.count)].map(String.init).joined(separator: ";"))
                k += 3
            } else {
                out.append(String(p))
                k += 1
            }
        }
        return Array("\u{1b}[\(out.joined(separator: ";"))m".utf8)
    }

    static func isNearWhite(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        min(r, g, b) >= floor && max(r, g, b) - min(r, g, b) <= spread
    }

    /// The xterm 256-colour palette: the 16 base colours (bright white is white), the 6x6x6 cube and the grey ramp.
    static func xterm(_ index: Int) -> (Int, Int, Int) {
        switch index {
        case 15: return (255, 255, 255)
        case 0..<16: return (0, 0, 0)
        case 16..<232:
            let n = index - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return (steps[n / 36], steps[n / 6 % 6], steps[n % 6])
        case 232..<256:
            let v = 8 + 10 * (index - 232)
            return (v, v, v)
        default: return (0, 0, 0)
        }
    }
}
