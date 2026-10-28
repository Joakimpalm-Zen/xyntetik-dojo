/// Colours relayed messages on the way to the screen. A harness paints its own transcript, so the only
/// place to make a `[from: <name>]` tag stand out is the byte stream from the harness to the terminal:
/// every tag is wrapped in a truecolour foreground code and a reset to the default foreground.
public enum Highlight {
    static let open: [UInt8] = Array("[from: ".utf8)
    static let maxTagLength = open.count + 24 + 1

    /// The foreground colour code for an RGB value.
    public static func foreground(red: Int, green: Int, blue: Int) -> [UInt8] {
        Array("\u{1b}[38;2;\(red);\(green);\(blue)m".utf8)
    }

    /// Back to the default foreground.
    public static let reset: [UInt8] = Array("\u{1b}[39m".utf8)

    /// Returns `carry` + `input` with every complete tag wrapped in `color` and `reset`. Bytes at the end
    /// that could still become a tag are left in `carry` for the next call; the caller flushes them raw
    /// when no more data follows soon.
    public static func tagged(_ input: [UInt8], carry: inout [UInt8], color: [UInt8]) -> [UInt8] {
        let data = carry + input
        carry = []
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            guard data[i] == UInt8(ascii: "[") else { out.append(data[i]); i += 1; continue }
            let rest = data.count - i
            if rest < open.count {
                if data[i...].elementsEqual(open.prefix(rest)) { carry = Array(data[i...]); return out }
                out.append(data[i]); i += 1; continue
            }
            guard data[i..<i + open.count].elementsEqual(open) else { out.append(data[i]); i += 1; continue }
            let nameStart = i + open.count
            var j = nameStart
            while j < data.count, j - nameStart <= 24, isNameByte(data[j]) { j += 1 }
            if j < data.count, data[j] == UInt8(ascii: "]"), j > nameStart {
                out += color + data[i...j] + reset
                i = j + 1
            } else if j == data.count, rest <= maxTagLength {
                carry = Array(data[i...])
                return out
            } else {
                out.append(data[i]); i += 1
            }
        }
        return out
    }

    private static func isNameByte(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b == UInt8(ascii: ".")
    }
}
