import CoreGraphics
import Foundation

/// The outline of a piece of glass.
public enum GlassShape: Sendable, Hashable {
  /// Fully round ends, like a pill button or a tab bar.
  case capsule
  /// A circle, or as round as the frame allows.
  case circle
  /// A rectangle with iOS's continuous corners.
  case rect(cornerRadius: CGFloat)

  func radius(for size: CGSize) -> CGFloat {
    let most = min(size.width, size.height) / 2
    switch self {
    case .capsule, .circle: return most
    case .rect(let r): return min(max(r, 0), most)
    }
  }
}

/// iOS's corners and the distance to the rim, as the web and Android versions draw them.
///
/// iOS's corners are continuous: a superellipse of power 2.5 that starts 1.2 times the radius
/// along each edge, so the curve begins further out than a circle's would. A corner that long
/// needs room, so a capsule stays circular, as on iOS.
enum Contour {
  static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
    let hw = rect.width / 2, hh = rect.height / 2
    guard hw > 0, hh > 0 else { return CGPath(rect: .zero, transform: nil) }
    let r = min(max(radius, 0), min(hw, hh))
    if r <= 0 { return CGPath(rect: rect, transform: nil) }
    let reach = r * 1.2
    if reach > min(hw, hh) {
      return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
    let cx = rect.midX, cy = rect.midY
    let path = CGMutablePath()
    let steps = 24
    let corners: [(CGFloat, CGFloat)] = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
    for (q, (sx, sy)) in corners.enumerated() {
      for i in 0...steps {
        let t = (CGFloat(q) + CGFloat(i) / CGFloat(steps)) * .pi / 2
        let u = pow(abs(cos(t)), 0.8), v = pow(abs(sin(t)), 0.8)
        let point = CGPoint(x: cx + sx * (hw - reach + u * reach), y: cy + sy * (hh - reach + v * reach))
        if q == 0 && i == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
    }
    path.closeSubpath()
    return path
  }

  /// The same shape drawn `inset` points further in.
  static func path(in rect: CGRect, radius: CGFloat, inset: CGFloat) -> CGPath {
    path(in: rect.insetBy(dx: inset, dy: inset), radius: max(0, radius - inset))
  }

  /// How far in from the rim a point is, and which way is out. `p` is measured from the middle.
  /// Negative distances are outside. A port of the Android shader's `edge`.
  static func edge(_ p: CGPoint, half: CGSize, radius: CGFloat) -> (d: CGFloat, nx: CGFloat, ny: CGFloat) {
    func sign(_ v: CGFloat) -> CGFloat { v > 0 ? 1 : v < 0 ? -1 : 0 }
    let reach = radius * 1.2
    if radius > 0 && reach <= min(half.width, half.height) {
      let a = abs(p.x) - (half.width - reach)
      let b = abs(p.y) - (half.height - reach)
      if a > 0 && b > 0 {
        let u = a / reach, v = b / reach
        let g = pow(pow(u, 2.5) + pow(v, 2.5), 0.4)
        let gx = pow(u / g, 1.5), gy = pow(v / g, 1.5)
        let norm = (gx * gx + gy * gy).squareRoot()
        return ((1 - g) * reach / norm, gx / norm * sign(p.x), gy / norm * sign(p.y))
      }
      let dx = half.width - abs(p.x), dy = half.height - abs(p.y)
      return dx < dy ? (dx, sign(p.x), 0) : (dy, 0, sign(p.y))
    }
    let r = min(radius, min(half.width, half.height))
    let qx = abs(p.x) - (half.width - r), qy = abs(p.y) - (half.height - r)
    let ox = max(qx, 0), oy = max(qy, 0)
    let l = (ox * ox + oy * oy).squareRoot()
    let d = r - (l + min(max(qx, qy), 0))
    if l > 0 { return (d, ox / l * sign(p.x), oy / l * sign(p.y)) }
    return qx > qy ? (d, sign(p.x), 0) : (d, 0, sign(p.y))
  }
}
