import SwiftUI

/// Logos oficiais (paths SVG das marcas, viewBox 24x24, fonte: simple-icons).
struct ProviderLogo: View {
    let provider: Provider
    var body: some View {
        switch provider {
        case .claude: SVGShape(data: Logo.claude).fill(Logo.claudeOrange)
        case .cursor: SVGShape(data: Logo.cursor).fill(Color.primary)
        }
    }
}

enum Logo {
    static let claudeOrange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    static let claude = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"

    static let cursor = "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23"
}

/// Desenha um path SVG (viewBox 24x24) escalado para o espaco disponivel.
struct SVGShape: Shape {
    let data: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / viewBox
        let t = CGAffineTransform(translationX: rect.midX - viewBox * s / 2, y: rect.midY - viewBox * s / 2).scaledBy(x: s, y: s)
        return SVGPath.parse(data).applying(t)
    }
}

/// Parser minimo de path SVG: M L H V C S Q T A Z (absolutos e relativos).
enum SVGPath {
    private static var cache: [String: Path] = [:]

    static func parse(_ d: String) -> Path {
        if let p = cache[d] { return p }
        var sc = Scanner(d)
        var p = Path()
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint?
        var cmd: Character = "M"
        var prevCmd: Character = " "

        loop: while true {
            sc.skipSeparators()
            guard let c = sc.peek else { break loop }
            if c.isLetter { cmd = c; sc.advance() }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }

            switch cmd.uppercased().first! {
            case "M":
                guard let x = sc.number(), let y = sc.number() else { break loop }
                cur = pt(x, y); start = cur; p.move(to: cur)
                cmd = rel ? "l" : "L"  // pares seguintes sao lineTo
            case "L":
                guard let x = sc.number(), let y = sc.number() else { break loop }
                cur = pt(x, y); p.addLine(to: cur)
            case "H":
                guard let x = sc.number() else { break loop }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); p.addLine(to: cur)
            case "V":
                guard let y = sc.number() else { break loop }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); p.addLine(to: cur)
            case "C":
                guard let a = sc.number(), let b = sc.number(), let c2 = sc.number(), let d2 = sc.number(),
                      let x = sc.number(), let y = sc.number() else { break loop }
                let c1 = pt(a, b), cc = pt(c2, d2)
                cur = pt(x, y); p.addCurve(to: cur, control1: c1, control2: cc); lastCtrl = cc
            case "S":
                guard let c2 = sc.number(), let d2 = sc.number(), let x = sc.number(), let y = sc.number() else { break loop }
                let c1 = "CS".contains(prevCmd) ? reflect(lastCtrl, cur) : cur
                let cc = pt(c2, d2)
                cur = pt(x, y); p.addCurve(to: cur, control1: c1, control2: cc); lastCtrl = cc
            case "Q":
                guard let a = sc.number(), let b = sc.number(), let x = sc.number(), let y = sc.number() else { break loop }
                let c1 = pt(a, b)
                cur = pt(x, y); p.addQuadCurve(to: cur, control: c1); lastCtrl = c1
            case "T":
                guard let x = sc.number(), let y = sc.number() else { break loop }
                let c1 = "QT".contains(prevCmd) ? reflect(lastCtrl, cur) : cur
                cur = pt(x, y); p.addQuadCurve(to: cur, control: c1); lastCtrl = c1
            case "A":
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(),
                      let large = sc.flag(), let sweep = sc.flag(),
                      let x = sc.number(), let y = sc.number() else { break loop }
                let end = pt(x, y)
                arc(&p, from: cur, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = end
            case "Z":
                p.closeSubpath(); cur = start
            default:
                sc.advance()
            }
            prevCmd = cmd.uppercased().first!
        }
        cache[d] = p
        return p
    }

    private static func reflect(_ c: CGPoint?, _ about: CGPoint) -> CGPoint {
        guard let c else { return about }
        return CGPoint(x: 2 * about.x - c.x, y: 2 * about.y - c.y)
    }

    /// Arco eliptico SVG convertido em curvas de Bezier (SVG 1.1, apendice F.6).
    private static func arc(_ p: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        if p0 == p1 { return }
        if rx == 0 || ry == 0 { p.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let alpha = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosP - ry * sin(t) * sinP, y: cy + rx * cos(t) * sinP + ry * sin(t) * cosP)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosP - ry * cos(t) * sinP, y: -rx * sin(t) * sinP + ry * cos(t) * cosP)
        }
        var t = theta1
        for i in 0..<segments {
            let t2 = t + step
            let a = point(t), b = i == segments - 1 ? p1 : point(t2)
            let da = deriv(t), db = deriv(t2)
            p.addCurve(to: b, control1: CGPoint(x: a.x + alpha * da.x, y: a.y + alpha * da.y),
                       control2: CGPoint(x: b.x - alpha * db.x, y: b.y - alpha * db.y))
            t = t2
        }
    }

    private struct Scanner {
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        var peek: Character? { i < chars.count ? chars[i] : nil }
        mutating func advance() { i += 1 }
        mutating func skipSeparators() { while let c = peek, c == " " || c == "," || c.isNewline || c == "\t" { i += 1 } }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek, c == "0" || c == "1" else { return nil }
            i += 1
            return c == "1"
        }

        /// Le um numero; aceita "-.5", ".5.3" (dois numeros) e expoente.
        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = i
            if let c = peek, c == "-" || c == "+" { i += 1 }
            var dot = false, digits = false
            while let c = peek {
                if c.isNumber { digits = true; i += 1 }
                else if c == "." && !dot { dot = true; i += 1 }
                else if (c == "e" || c == "E") && digits {
                    i += 1
                    if let s = peek, s == "-" || s == "+" { i += 1 }
                } else { break }
            }
            guard digits, let v = Double(String(chars[begin..<i])) else { i = begin; return nil }
            return CGFloat(v)
        }
    }
}
