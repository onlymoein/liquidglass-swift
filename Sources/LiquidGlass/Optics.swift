import CoreGraphics
import Foundation

/// What iOS 27's glass does to the light, as liquidglass measured it on the iPhone simulator
/// (parity/PLAN.md in onlymoein/liquidglass). Lengths are in points.
enum Optics {
  /// How much of the size curve applies: none at 60 points tall or less, all of it at 120.
  static func sizeCurve(_ short: CGFloat) -> CGFloat { min(max((short - 60) / 60, 0), 1) }

  /// How far in from the rim the glass bends.
  static func bezel(_ short: CGFloat) -> CGFloat { min(max(2.4 + short * 0.059, 3), 12) }

  /// How far in the rim looks, at the very edge: about a third of the height.
  static func reach(_ short: CGFloat) -> CGFloat { min(short * 0.33, 48) }

  /// The blur's standard deviation.
  static func blur(clear: Bool) -> CGFloat { clear ? 1.3 : 15.3 }

  struct Tone: Equatable {
    var contrast: Double
    var brightness: Double
    var saturation: Double
  }

  static func tone(short: CGFloat, dark: Bool, clear: Bool) -> Tone {
    let t = Double(sizeCurve(short))
    func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
    if clear { return Tone(contrast: 0.793, brightness: 1.205, saturation: 1.117) }
    if dark { return Tone(contrast: lerp(0.68, 0.66), brightness: lerp(0.98, 0.83), saturation: lerp(1.6, 1.7)) }
    return Tone(contrast: lerp(0.314, 0.307), brightness: lerp(1.511, 1.554), saturation: lerp(2, 2.081))
  }

  static let luma: [Double] = [0.2126, 0.7152, 0.0722]

  /// In dark mode iOS glass isn't linear: brightness peaks over light greys and falls again over
  /// white, and colour fades as the backdrop gets brighter. Glass 60 points tall or less keeps
  /// more of it than glass 120 or more. Measured values, by the backdrop's luminance from black to
  /// white, from liquidglass's refraction.ts.
  static let darkSmall = (brightness: [32.0, 62, 89, 113, 134, 151, 166, 177, 185], colour: [1.27, 1.22, 1.18, 1.13, 1.08, 1.03, 0.98, 0.94, 0.89])
  static let darkLarge = (brightness: [32.0, 59, 83, 102, 117, 126, 129, 128, 121], colour: [1.27, 1.19, 1.11, 1.03, 0.95, 0.87, 0.79, 0.71, 0.63])

  /// Dark glass over an sRGB-encoded colour, `size` along the curve from small (0) to large (1).
  static func dark(_ rgb: [Double], size: Double) -> [Double] {
    let l = zip(rgb, luma).map(*).reduce(0, +)
    func table(_ small: [Double], _ large: [Double]) -> Double {
      let x = min(max(l, 0), 1) * Double(small.count - 1)
      let i = min(Int(x), small.count - 2), f = x - Double(i)
      let at = { (k: Int) in small[k] + (large[k] - small[k]) * size }
      return at(i) + (at(i + 1) - at(i)) * f
    }
    let brightness = table(darkSmall.brightness, darkLarge.brightness) / 255
    let gain = table(darkSmall.colour, darkLarge.colour)
    return rgb.map { min(max(brightness + gain * ($0 - l), 0), 1) }
  }

  /// Contrast, then brightness, then saturation, in that order as CSS filters apply them, folded
  /// into one matrix. Rows are red, green and blue; every row has the same bias.
  static func matrix(_ tone: Tone) -> (rows: [[Double]], bias: Double) {
    let scale = tone.brightness * tone.contrast
    let s = tone.saturation
    let rows = (0..<3).map { row in
      (0..<3).map { col in scale * ((row == col ? s : 0) + (1 - s) * luma[col]) }
    }
    return (rows, 0.5 * tone.brightness * (1 - tone.contrast))
  }

  /// The shadow: barely any on a button, `0 8px 21px` at 7% on a 120-point panel, 11% in dark mode.
  static func shadow(short: CGFloat, dark: Bool) -> (opacity: Float, radius: CGFloat, offset: CGFloat) {
    let t = sizeCurve(short)
    return (Float(t * (dark ? 0.11 : 0.07)), 10.5, 8 * t)
  }
}

/// The rim, as iOS lights it, ported from the Android shader's `rim` and `rimAcross`.
enum Rim {
  /// Premultiplied white and alpha at a point `points` in from the edge, facing `n`.
  static func rim(points: Double, nx: Double, ny: Double, shine: Double, clear: Double) -> (white: Double, alpha: Double) {
    // Lit from straight above, in y-down coordinates.
    let facing = -ny
    let end = facing * facing
    let side = 1 - end
    var lit = 0.0, shade = 0.0
    if points >= 0 {
      let line = max(0, 0.39 - 0.29 * points)
      if facing > 0 {
        lit = end * (line + (points > 1 ? 0.05 * max(0, 1 - (points - 1) / 2.5) : 0))
        shade = end * 0.02 * max(0, 1 - abs(points - 9) / 5)
      } else if facing < 0 {
        lit = end * line
      }
      shade += side * 0.02 * min(max((15 - points) / 5, 0), 1)
    } else {
      shade = (side * 0.45 + end * 0.12) * min(max(1 + points / 0.75, 0), 1)
    }
    lit = min(max(lit * shine * (1 + clear * 1.1), 0), 1)
    shade = min(max(shade * shine, 0), 1)
    let alpha = lit + shade - lit * shade
    let white = lit + shade > 0 ? lit / (lit + shade) : 0
    return (white * alpha, alpha)
  }

  /// The rim averaged across a pixel, so the hairline meets the glass in a smooth pixel.
  static func across(d: Double, density: Double, nx: Double, ny: Double, shine: Double, clear: Double) -> (white: Double, alpha: Double) {
    if d > 15 * density + 1 { return (0, 0) }
    if d > 1.5 { return rim(points: d / density, nx: nx, ny: ny, shine: shine, clear: clear) }
    var w = 0.0, a = 0.0
    for i in 0..<4 {
      let s = rim(points: (d + (Double(i) - 1.5) * 0.25) / density, nx: nx, ny: ny, shine: shine, clear: clear)
      w += s.white; a += s.alpha
    }
    return (w / 4, a / 4)
  }

  /// The rim for glass of `size`, drawn `margin` points beyond it on every side, at `scale`
  /// pixels to the point.
  static func image(size: CGSize, radius: CGFloat, scale: CGFloat, margin: CGFloat, shine: Double, clear: Double) -> CGImage? {
    let width = Int(((size.width + margin * 2) * scale).rounded(.up))
    let height = Int(((size.height + margin * 2) * scale).rounded(.up))
    guard width > 0, height > 0 else { return nil }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let half = CGSize(width: size.width / 2, height: size.height / 2)
    let density = Double(scale)
    let reachIn = 15 * density + 2
    for y in 0..<height {
      let py = (CGFloat(y) + 0.5) / scale - margin - half.height
      for x in 0..<width {
        let px = (CGFloat(x) + 0.5) / scale - margin - half.width
        // Skip the middle quickly: nothing is drawn further in than the rim reaches.
        if abs(px) < half.width - 16 - radius * 1.2 && abs(py) < half.height - 16 { continue }
        let e = Contour.edge(CGPoint(x: px, y: py), half: half, radius: radius)
        let d = Double(e.d) * density
        if d / density < -1 || d > reachIn { continue }
        let r = across(d: d, density: density, nx: Double(e.nx), ny: Double(e.ny), shine: shine, clear: clear)
        if r.alpha <= 0 { continue }
        let i = (y * width + x) * 4
        let w = UInt8(min(max(r.white * 255, 0), 255).rounded())
        pixels[i] = w; pixels[i + 1] = w; pixels[i + 2] = w
        pixels[i + 3] = UInt8(min(max(r.alpha * 255, 0), 255).rounded())
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}

/// A damped spring, solved exactly each frame, as liquidglass's `spring.ts`.
struct Spring {
  var value = 0.0
  var target = 0.0
  var velocity = 0.0
  var stiffness = 230.0
  var damping = 23.7

  var isResting: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.005 }

  mutating func advance(_ dt: Double) {
    let x = value - target, v = velocity
    let half = damping / 2
    let discriminant = half * half - stiffness
    if abs(discriminant) < 1e-4 {
      let decay = exp(-half * dt), b = v + half * x
      value = target + decay * (x + b * dt)
      velocity = decay * (v - half * b * dt)
    } else if discriminant > 0 {
      let root = discriminant.squareRoot()
      let r1 = -half + root, r2 = -half - root
      let a = (v - r2 * x) / (r1 - r2), b = x - a
      value = target + a * exp(r1 * dt) + b * exp(r2 * dt)
      velocity = a * r1 * exp(r1 * dt) + b * r2 * exp(r2 * dt)
    } else {
      let omega = (-discriminant).squareRoot()
      let decay = exp(-half * dt), c = cos(omega * dt), s = sin(omega * dt)
      value = target + decay * (x * c + ((v + half * x) / omega) * s)
      velocity = decay * (v * c - ((half * v + stiffness * x) / omega) * s)
    }
    if isResting { value = target; velocity = 0 }
  }
}
