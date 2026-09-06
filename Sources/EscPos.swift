import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Bitmap

/// A 1-bit-per-pixel raster, 1 = ink, packed MSB-first per row.
struct Bitmap {
    var width: Int
    var height: Int
    var bits: [UInt8]

    var rowBytes: Int { (width + 7) / 8 }

    func pixel(_ x: Int, _ y: Int) -> Bool {
        let idx = y * rowBytes + (x >> 3)
        guard idx < bits.count else { return false }
        return (bits[idx] >> (7 - UInt8(x & 7))) & 1 == 1
    }

    func cgImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var gray = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width where pixel(x, y) {
                gray[y * width + x] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    @discardableResult
    func writePNG(to url: URL) -> Bool {
        guard let image = cgImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

// MARK: - Style

enum TextAlign { case left, center, right }

struct Style: Equatable {
    var align: TextAlign = .left
    var bold = false
    var underline = false
    var invert = false
    var widthMul = 1
    var heightMul = 1
}

enum Block {
    case text(String, Style)
    case image(Bitmap, String)   // raster + the PNG filename it was written to
    case note(String)
    case cut
}

// MARK: - Decoder

/// Walks a raw ESC/POS byte stream into renderable blocks plus a command trace.
///
/// The subtle part is `ESC *`: esc_pos_utils_plus' `image()` rotates the source
/// 270 degrees, slices it into 24-dot-tall strips and emits one `ESC *` chunk
/// per strip with a newline between them. Those chunks have to be stitched back
/// together vertically, and the separating newlines must not break the line
/// layout, or logos come out as stripes.
final class EscPosDecoder {
    private let d: [UInt8]
    private var i = 0
    private let outDir: URL
    private let jobName: String

    private(set) var trace: [String] = []
    private(set) var blocks: [Block] = []
    private(set) var imageCount = 0

    private var line = ""
    private var style = Style()
    private var lineStyle = Style()

    private var bandBits: [UInt8] = []
    private var bandWidth = 0
    private var bandHeight = 0

    init(data: [UInt8], outDir: URL, jobName: String) {
        self.d = data
        self.outDir = outDir
        self.jobName = jobName
    }

    // -- helpers

    private func log(_ s: String) { trace.append(s) }

    private var atEnd: Bool { i >= d.count }

    private func byte() -> UInt8 {
        guard i < d.count else { return 0 }
        defer { i += 1 }
        return d[i]
    }

    private func take(_ n: Int) -> [UInt8] {
        let end = min(i + n, d.count)
        defer { i = end }
        return Array(d[i..<end])
    }

    private func flushLine() {
        blocks.append(.text(line, lineStyle))
        line = ""
        lineStyle = style
    }

    private func emit(_ bitmap: Bitmap, kind: String) {
        imageCount += 1
        let name = "\(jobName)-img\(imageCount).png"
        bitmap.writePNG(to: outDir.appendingPathComponent(name))
        blocks.append(.image(bitmap, name))
        log("    -> \(kind) \(bitmap.width)x\(bitmap.height) rendered")
    }

    // -- ESC * band stitching

    private func bandAdd(m: UInt8, columns: Int, payload: [UInt8]) {
        let bytesPerCol = (m == 32 || m == 33) ? 3 : 1
        let rows = bytesPerCol * 8
        if bandWidth != 0 && bandWidth != columns { bandFlush() }
        bandWidth = columns
        let rowBytes = (columns + 7) / 8
        for r in 0..<rows {
            var row = [UInt8](repeating: 0, count: rowBytes)
            for x in 0..<columns {
                let idx = x * bytesPerCol + (r >> 3)
                guard idx < payload.count else { continue }
                if (payload[idx] >> (7 - UInt8(r & 7))) & 1 == 1 {
                    row[x >> 3] |= 0x80 >> UInt8(x & 7)
                }
            }
            bandBits.append(contentsOf: row)
        }
        bandHeight += rows
    }

    private func bandFlush() {
        guard bandWidth > 0 else { return }
        emit(Bitmap(width: bandWidth, height: bandHeight, bits: bandBits),
             kind: "ESC * bit image")
        bandBits = []
        bandWidth = 0
        bandHeight = 0
    }

    // -- main loop

    @discardableResult
    func run() -> EscPosDecoder {
        while !atEnd {
            let c = byte()
            switch c {
            case 0x1B: esc()
            case 0x1D: bandFlush(); gs()
            case 0x1C: bandFlush(); log("FS \(hex(take(1))) (kanji mode)")
            case 0x10: log("DLE \(hex(take(3))) (real-time status request)")
            case 0x0A:
                // the ESC * encoder puts a newline after every band; inside an
                // image that byte is a separator, not a line break
                if bandWidth == 0 { flushLine() }
            case 0x0D: break
            case 0x09: line += "\t"
            default:
                bandFlush()
                line.append(Character(UnicodeScalar(cp437(c)) ?? " "))
            }
        }
        bandFlush()
        if !line.isEmpty { flushLine() }
        return self
    }

    private func esc() {
        let c = byte()
        // line-spacing commands bracket the image bands, so they must not flush
        switch c {
        case 0x33: log("ESC 3 \(byte())      line spacing"); return
        case 0x32: log("ESC 2        default line spacing"); return
        case 0x2A:
            let m = byte(), nl = byte(), nh = byte()
            let n = Int(nl) | (Int(nh) << 8)
            let payload = take(n * ((m == 32 || m == 33) ? 3 : 1))
            log("ESC * m=\(m) n=\(n)  bit-image band (\(payload.count) bytes)")
            bandAdd(m: m, columns: n, payload: payload)
            return
        default: break
        }

        bandFlush()
        switch c {
        case 0x40:
            style = Style(); lineStyle = style
            log("ESC @        initialize printer")
        case 0x61:
            let n = byte()
            style.align = n == 1 ? .center : (n == 2 ? .right : .left)
            if line.isEmpty { lineStyle = style }
            log("ESC a \(n)      align \(style.align)")
        case 0x21:
            let n = byte()
            style.bold = n & 0x08 != 0
            style.widthMul = n & 0x20 != 0 ? 2 : 1
            style.heightMul = n & 0x10 != 0 ? 2 : 1
            style.underline = n & 0x80 != 0
            if line.isEmpty { lineStyle = style }
            log(String(format: "ESC ! 0x%02x   print mode", Int(n)))
        case 0x45:
            style.bold = byte() != 0
            if line.isEmpty { lineStyle = style }
            log("ESC E        bold \(style.bold)")
        case 0x47: log("ESC G \(byte())      double-strike")
        case 0x2D:
            style.underline = byte() != 0
            if line.isEmpty { lineStyle = style }
            log("ESC -        underline \(style.underline)")
        case 0x64:
            let n = Int(byte())
            log("ESC d \(n)      feed \(n) lines")
            for _ in 0..<n { flushLine() }
        case 0x4A: log("ESC J \(byte())      feed n dots")
        case 0x74: log("ESC t \(byte())      select code page")
        case 0x52: log("ESC R \(byte())      international char set")
        case 0x4D: log("ESC M \(byte())      select font")
        case 0x63: log("ESC c \(hex(take(2)))   paper sensor cfg")
        case 0x70:
            let p = take(3)
            log("ESC p \(p.map(String.init).joined(separator: " "))  *** OPEN CASH DRAWER ***")
            blocks.append(.note("cash drawer pulse"))
        default:
            log(String(format: "ESC 0x%02x     (unhandled)", Int(c)))
        }
    }

    private func gs() {
        let c = byte()
        switch c {
        case 0x21:
            let n = byte()
            style.widthMul = Int(n >> 4) + 1
            style.heightMul = Int(n & 0x0F) + 1
            if line.isEmpty { lineStyle = style }
            log("GS ! \(String(format: "0x%02x", Int(n)))    char size w\(style.widthMul) h\(style.heightMul)")
        case 0x56:
            let m = byte()
            var extra = ""
            if m == 65 || m == 66 { extra = " feed=\(byte())" }
            log("GS V \(m)\(extra)     *** CUT PAPER ***")
            if !line.isEmpty { flushLine() }
            blocks.append(.cut)
        case 0x76:
            _ = byte()                       // '0'
            let m = byte()
            let h = take(4)
            let wbytes = Int(h[0]) | (Int(h[1]) << 8)
            let height = Int(h[2]) | (Int(h[3]) << 8)
            let payload = take(wbytes * height)
            log("GS v 0 m=\(m)  raster \(wbytes * 8)x\(height)")
            emit(Bitmap(width: wbytes * 8, height: height, bits: payload),
                 kind: "GS v 0 raster")
        case 0x6B:
            let m = byte()
            var data: [UInt8] = []
            if m <= 6 {
                while !atEnd && d[i] != 0 { data.append(byte()) }
                i += 1
            } else {
                data = take(Int(byte()))
            }
            let text = String(decoding: data, as: UTF8.self)
            log("GS k m=\(m)    BARCODE '\(text)'")
            blocks.append(.note("barcode: \(text)"))
        case 0x28:
            let fn = byte()
            let pl = byte(), ph = byte()
            let body = take(Int(pl) | (Int(ph) << 8))
            if fn == 0x6B {
                log("GS ( k   QR/2D code, \(body.count) bytes")
                if body.count > 3 && body[0] == 0x31 && body[1] == 0x50 {
                    blocks.append(.note("QR: " + String(decoding: body[3...], as: UTF8.self)))
                }
            } else {
                log("GS ( \(Character(UnicodeScalar(fn)))   graphics, \(body.count) bytes")
            }
        case 0x42:
            style.invert = byte() != 0
            log("GS B         reverse \(style.invert)")
        case 0x4C: log("GS L \(hex(take(2)))   left margin")
        case 0x57: log("GS W \(hex(take(2)))   print area width")
        case 0x72, 0x61, 0x66, 0x48, 0x68, 0x77:
            log("GS \(Character(UnicodeScalar(c))) \(byte())      parameter")
        default:
            log(String(format: "GS 0x%02x      (unhandled)", Int(c)))
        }
    }

    private func hex(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }

    /// Map a CP437 byte to a displayable scalar; ASCII passes straight through.
    private func cp437(_ b: UInt8) -> UInt32 {
        b < 0x80 ? UInt32(b) : Self.cp437High[Int(b) - 0x80]
    }

    private static let cp437High: [UInt32] = [
        0xC7,0xFC,0xE9,0xE2,0xE4,0xE0,0xE5,0xE7,0xEA,0xEB,0xE8,0xEF,0xEE,0xEC,0xC4,0xC5,
        0xC9,0xE6,0xC6,0xF4,0xF6,0xF2,0xFB,0xF9,0xFF,0xD6,0xDC,0xA2,0xA3,0xA5,0x20A7,0x192,
        0xE1,0xED,0xF3,0xFA,0xF1,0xD1,0xAA,0xBA,0xBF,0x2310,0xAC,0xBD,0xBC,0xA1,0xAB,0xBB,
        0x2591,0x2592,0x2593,0x2502,0x2524,0x2561,0x2562,0x2556,0x2555,0x2563,0x2551,0x2557,
        0x255D,0x255C,0x255B,0x2510,0x2514,0x2534,0x252C,0x251C,0x2500,0x253C,0x255E,0x255F,
        0x255A,0x2554,0x2569,0x2566,0x2560,0x2550,0x256C,0x2567,0x2568,0x2564,0x2565,0x2559,
        0x2558,0x2552,0x2553,0x256B,0x256A,0x2518,0x250C,0x2588,0x2584,0x258C,0x2590,0x2580,
        0x3B1,0xDF,0x393,0x3C0,0x3A3,0x3C3,0xB5,0x3C4,0x3A6,0x398,0x3A9,0x3B4,0x221E,0x3C6,
        0x3B5,0x2229,0x2261,0xB1,0x2265,0x2264,0x2320,0x2321,0xF7,0x2248,0xB0,0x2219,0xB7,
        0x221A,0x207F,0xB2,0x25A0,0xA0,
    ]
}

/// TSPL/TSC label jobs are plain text commands, not ESC/POS.
func looksLikeTSC(_ data: [UInt8]) -> Bool {
    let head = String(decoding: data.prefix(200), as: UTF8.self).uppercased()
    return ["SIZE ", "GAP ", "CLS\r\n", "DIRECTION ", "PRINT "].contains { head.contains($0) }
}
