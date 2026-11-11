#if os(macOS)
import AppKit
import CoreImage
import QuartzCore

/// Glass on the Mac, drawn from Core Animation layers that filter what's behind them.
///
/// The window server runs Core Image's built-in filters on a layer's backdrop, live, AppKit views
/// such as scroll views included. Three things about that shape this view:
///
/// - A layer's `backgroundFilters` see only what its own parent has drawn beneath it. SwiftUI
///   hosts this view inside a wrapper of its own, which has nothing beneath, so the glass's
///   layers are put beside that wrapper instead, just below it, where SwiftUI's content behind
///   the glass is, and follow it from frame to frame. The tint, rim and shadow stay in this view,
///   above them, under the glass's own content.
/// - The filters work in that parent layer's own coordinates, whichever way up they are, so
///   they're placed again whenever the glass moves in it.
/// - Custom kernels and displacement maps don't run there, so the bend at the rim is built from
///   rings: each ring of the bezel is its own backdrop, magnified about the glass's middle by
///   enough that it shows what lies `shift` points further in, falling in a straight line from
///   `reach` at the rim to nothing at the bezel's inner edge, as iOS's does. Rings are drawn
///   outermost first and the middle last, so each magnifies content nothing has filtered yet.
@MainActor
final class MacGlassView: NSView {
  struct Config: Equatable {
    var clear = false
    var tint: NSColor?
    var shape: GlassShape = .capsule
    var dark = false
    var opaque = false
    /// Out of sight, but still in place.
    var hidden = false
  }

  var config = Config() { didSet { if config != oldValue { drawn = nil; refresh() } } }

  var pressed = false {
    didSet {
      guard pressed != oldValue else { return }
      // The pointer's feel from the web version: grows 6 points, quick in, softer out.
      spring.target = pressed ? 1 : 0
      if pressed { spring.stiffness = 417.6; spring.damping = 29.2 } else { spring.stiffness = 230; spring.damping = 23.7 }
    }
  }

  /// The rings and the middle, which live beside SwiftUI's wrapper, not in this view.
  private var glassLayers: [CALayer] = []
  private let shadowLayer = CALayer()
  private let shadowCut = CAShapeLayer()
  private let chrome = NSView()
  private let tintLayer = CAShapeLayer()
  private let lightLayer = CAShapeLayer()
  private let rimLayer = CALayer()
  private var rimFor: (size: CGSize, radius: CGFloat, scale: CGFloat, clear: Bool)?
  private var spring = Spring()
  private var link: CADisplayLink?
  private var lastTime: CFTimeInterval = 0
  private var drawn: Drawn?

  private struct Drawn: Equatable {
    var placed: CGRect
    var local: CGRect
    var scale: CGFloat
    var config: Config
    var progress: Double
    var opacity: Float
    var hidden: Bool
  }

  /// Extra room the rim's hairline reaches outside the glass.
  private let margin: CGFloat = 2

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    shadowLayer.mask = shadowCut
    shadowCut.fillRule = .evenOdd
    layer?.addSublayer(shadowLayer)
    chrome.wantsLayer = true
    chrome.layer?.masksToBounds = false
    addSubview(chrome)
    for l in [tintLayer, lightLayer] { l.fillColor = nil; chrome.layer?.addSublayer(l) }
    lightLayer.fillColor = NSColor.white.cgColor
    lightLayer.opacity = 0
    rimLayer.contentsGravity = .resize
    chrome.layer?.addSublayer(rimLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { removeGlass() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    link?.invalidate()
    link = nil
    guard window != nil else { return }
    // The glass has to follow its place in its parent, which changes when anything around it
    // does, not only when its own frame changes. Comparing a rectangle a frame is cheap.
    let l = displayLink(target: self, selector: #selector(step(_:)))
    l.add(to: .main, forMode: .common)
    link = l
    lastTime = 0
    drawn = nil
  }

  override func layout() {
    super.layout()
    refresh()
  }

  @objc private func step(_ link: CADisplayLink) {
    let now = link.timestamp
    let dt = lastTime == 0 ? 1.0 / 60 : min(now - lastTime, 1.0 / 30)
    lastTime = now
    if !spring.isResting { spring.advance(dt) }
    refresh()
  }

  private func removeGlass() {
    for l in glassLayers { l.removeFromSuperlayer() }
    glassLayers = []
    drawn = nil
  }

  /// SwiftUI's wrapper round this view, and the layer it sits in: where the glass goes.
  ///
  /// SwiftUI sometimes puts the wrapper in a group of its own, as it does for content laid over
  /// other content, with nothing drawn under it. Glass in there would have nothing to see, so it
  /// goes below the group instead, as long as the group adds nothing of its own: no fill, mask,
  /// filters or clipping.
  private var anchor: (wrapper: CALayer, parent: CALayer)? {
    guard var wrapper = superview?.layer ?? layer?.superlayer, var parent = wrapper.superlayer else { return nil }
    let root = window?.contentView?.layer
    while parent !== root, let up = parent.superlayer, Self.isBare(parent),
      parent.sublayers?.first(where: { $0.name != "liquidglass" }) === wrapper
    {
      wrapper = parent
      parent = up
    }
    return (wrapper, parent)
  }

  private static func isBare(_ group: CALayer) -> Bool {
    group.backgroundColor == nil && group.contents == nil && group.mask == nil && !group.masksToBounds
      && (group.filters?.isEmpty ?? true) && (group.backgroundFilters?.isEmpty ?? true)
      && group.compositingFilter == nil
  }

  private func refresh() {
    guard let window, let own = layer, bounds.width > 0, bounds.height > 0, let (wrapper, parent) = anchor else { return }
    let progress = spring.value
    let long = max(bounds.width, bounds.height)
    let grow = 1 + CGFloat(progress) * 6 / long
    let local = CGRect(
      x: bounds.midX - bounds.width * grow / 2, y: bounds.midY - bounds.height * grow / 2,
      width: bounds.width * grow, height: bounds.height * grow)
    let placed = parent.convert(local, from: own)
    // The glass sits outside the layers between it and `parent`, so it takes on their fading itself.
    var opacity = own.opacity
    var hidden = false
    var up = own.superlayer
    while let l = up, l !== parent {
      opacity *= l.opacity
      hidden = hidden || l.isHidden
      up = l.superlayer
    }
    let next = Drawn(
      placed: placed, local: local, scale: window.backingScaleFactor, config: config, progress: progress,
      opacity: opacity, hidden: hidden || isHiddenOrHasHiddenAncestor || config.hidden)
    let misplaced = glassLayers.isEmpty || !inPlace(wrapper: wrapper, parent: parent)
    if next == drawn && !misplaced { return }
    let resized = misplaced || drawn.map { $0.local.size != local.size || $0.config != config || $0.scale != next.scale } ?? true
    drawn = next

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    chrome.frame = bounds
    chrome.isHidden = next.hidden
    shadowLayer.isHidden = next.hidden
    if resized { layOut(local: local, scale: next.scale, wrapper: wrapper, parent: parent) }
    for l in glassLayers {
      l.frame = placed
      l.opacity = next.opacity
      l.isHidden = next.hidden
    }
    placeFilters(size: local.size, placed: placed, parent: parent)
    lightLayer.opacity = Float(max(progress, 0) * 0.18)
    CATransaction.commit()
  }

  /// Whether the rings are still right below SwiftUI's wrapper, in order. SwiftUI may move the
  /// wrapper, or reorder what's round it.
  private func inPlace(wrapper: CALayer, parent: CALayer) -> Bool {
    guard let subs = parent.sublayers, let w = subs.firstIndex(where: { $0 === wrapper }) else { return false }
    let n = glassLayers.count
    guard w >= n else { return false }
    for (i, l) in glassLayers.enumerated() where subs[w - n + i] !== l { return false }
    return true
  }

  /// Everything that depends on the glass's size and style, not on where it is.
  private func layOut(local: CGRect, scale: CGFloat, wrapper: CALayer, parent: CALayer) {
    let size = local.size
    let short = min(size.width, size.height)
    let radius = config.shape.radius(for: size)
    let box = CGRect(origin: .zero, size: size)
    let full = Contour.path(in: box, radius: radius)

    // Shadow, cut away under the glass so the glass doesn't see it.
    let shadow = Optics.shadow(short: short, dark: config.dark)
    shadowLayer.frame = local
    shadowLayer.shadowPath = full
    shadowLayer.shadowColor = NSColor.black.cgColor
    shadowLayer.shadowOpacity = config.opaque ? max(shadow.opacity, 0.05) : shadow.opacity
    shadowLayer.shadowRadius = shadow.radius
    shadowLayer.shadowOffset = CGSize(width: 0, height: shadow.offset)
    let cut = CGMutablePath()
    cut.addRect(box.insetBy(dx: -80, dy: -80))
    cut.addPath(full)
    shadowCut.frame = box
    shadowCut.path = cut

    // The rings and the middle, put back right below the wrapper.
    let bezel = Optics.bezel(short)
    // Each ring is a step of `reach / rings` in the bend. Regular glass's blur hides steps of
    // several points; clear glass shows them, but its blur is so slight that more rings cost little.
    let rings = config.opaque ? 0
      : config.clear ? min(max(Int((bezel / 0.75).rounded()), 3), 16)
      : min(max(Int((bezel / 1.5).rounded()), 2), 6)
    let wanted = rings + 1
    while glassLayers.count < wanted {
      let l = CALayer()
      l.mask = CAShapeLayer()
      l.name = "liquidglass"
      glassLayers.append(l)
    }
    while glassLayers.count > wanted { glassLayers.removeLast().removeFromSuperlayer() }
    for l in glassLayers { l.removeFromSuperlayer() }
    for l in glassLayers { parent.insertSublayer(l, below: wrapper) }

    // The masks are drawn in the rings' own coordinates, which may be flipped from this view's.
    let flip = parent.contentsAreFlipped() != (layer?.contentsAreFlipped() ?? false)
    let overlap: CGFloat = 1
    for (i, l) in glassLayers.enumerated() {
      let mask = l.mask as! CAShapeLayer
      mask.frame = box
      mask.isGeometryFlipped = flip
      if i < rings {
        let outer = bezel * CGFloat(i) / CGFloat(rings)
        // Each ring runs a little under the next, which is drawn over it, so their edges'
        // smoothing doesn't leave a hairline of unfiltered backdrop between them.
        let inner = bezel * CGFloat(i + 1) / CGFloat(rings) + overlap
        let ring = CGMutablePath()
        ring.addPath(Contour.path(in: box, radius: radius, inset: outer))
        ring.addPath(Contour.path(in: box, radius: radius, inset: inner))
        mask.fillRule = .evenOdd
        mask.path = ring
        l.backgroundColor = nil
      } else {
        mask.fillRule = .nonZero
        mask.path = rings == 0 ? full : Contour.path(in: box, radius: radius, inset: bezel)
        l.backgroundColor = config.opaque
          ? (config.dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
          : nil
      }
    }

    tintLayer.frame = local
    tintLayer.path = full
    if let tint = config.tint {
      let a = tint.alphaComponent >= 1 ? 0.72 : tint.alphaComponent
      tintLayer.fillColor = tint.withAlphaComponent(a).cgColor
    } else {
      tintLayer.fillColor = nil
    }
    lightLayer.frame = local
    lightLayer.path = full

    // The rim only needs drawing again when the size changes by more than a sliver.
    let stale = rimFor.map {
      abs($0.size.width - size.width) > 0.75 || abs($0.size.height - size.height) > 0.75
        || $0.radius != radius || $0.scale != scale || $0.clear != config.clear
    } ?? true
    if stale {
      rimLayer.contents = Rim.image(size: size, radius: radius, scale: scale, margin: margin, shine: 1, clear: config.clear ? 1 : 0)
      rimFor = (size, radius, scale, config.clear)
    }
    rimLayer.frame = local.insetBy(dx: -margin, dy: -margin)
  }

  /// The filters, which work in the parent's coordinates, so they follow the glass as it moves.
  private func placeFilters(size: CGSize, placed: CGRect, parent: CALayer) {
    guard !config.opaque else {
      for l in glassLayers { l.backgroundFilters = nil }
      return
    }
    let short = min(size.width, size.height)
    let bezel = Optics.bezel(short)
    let reach = Optics.reach(short)
    let rings = glassLayers.count - 1
    let tone = config.dark && !config.clear
      ? [Filters.darkCube(size: Optics.sizeCurve(short))]
      : Filters.tone(Optics.tone(short: short, dark: config.dark, clear: config.clear))
    let blur = Filters.blur(Optics.blur(clear: config.clear))
    // The filters count in the parent layer's own coordinates, whichever way up they are.
    let middle = CGPoint(x: placed.midX, y: placed.midY)
    let hw = size.width / 2, hh = size.height / 2
    for (i, l) in glassLayers.enumerated() {
      var chain: [CIFilter] = []
      if i < rings {
        // Each ring shows what lies `shift` further in, at its own middle depth.
        let depth = bezel * (CGFloat(i) + 0.5) / CGFloat(rings)
        let shift = reach * (1 - depth / bezel)
        let kx = max(0.05, 1 - shift / max(hw - depth, 1))
        let ky = max(0.05, 1 - shift / max(hh - depth, 1))
        chain.append(Filters.magnify(about: middle, x: 1 / kx, y: 1 / ky))
      }
      chain.append(blur)
      chain.append(contentsOf: tone)
      l.backgroundFilters = chain
    }
  }
}

/// The built-in Core Image filters the window server runs on a backdrop.
@MainActor
enum Filters {
  /// Which colour space the tone's matrix is worked in. CSS filters, which liquidglass's numbers
  /// were fitted with, work on sRGB-encoded values, so by default the matrix runs between curves
  /// that take the backdrop there and back. `LIQUIDGLASS_TONE=linear` turns that off, for measuring.
  static let encoded = ProcessInfo.processInfo.environment["LIQUIDGLASS_TONE"] != "linear"

  static func blur(_ sigma: CGFloat) -> CIFilter {
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(sigma, forKey: kCIInputRadiusKey)
    return f
  }

  static func magnify(about c: CGPoint, x: CGFloat, y: CGFloat) -> CIFilter {
    var t = AffineTransform(translationByX: -c.x, byY: -c.y)
    t.append(AffineTransform(scaleByX: x, byY: y))
    t.append(AffineTransform(translationByX: c.x, byY: c.y))
    let f = CIFilter(name: "CIAffineTransform")!
    f.setValue(NSAffineTransform(transform: t), forKey: kCIInputTransformKey)
    return f
  }

  private static var cubes: [Int: Data] = [:]

  /// Dark glass's tone as a colour cube, worked in sRGB, since no matrix can follow it. Sizes are
  /// taken in quarters of the curve, as the web version does, and each cube is made once.
  static func darkCube(size: CGFloat) -> CIFilter {
    let step = Int((size * 4).rounded())
    let n = 24
    let data = cubes[step] ?? {
      var values = [Float]()
      values.reserveCapacity(n * n * n * 4)
      for b in 0..<n { for g in 0..<n { for r in 0..<n {
        let rgb = [r, g, b].map { Double($0) / Double(n - 1) }
        values += Optics.dark(rgb, size: Double(step) / 4).map(Float.init) + [1]
      } } }
      let made = values.withUnsafeBufferPointer { Data(buffer: $0) }
      cubes[step] = made
      return made
    }()
    let f = CIFilter(name: "CIColorCubeWithColorSpace")!
    f.setValue(n, forKey: "inputCubeDimension")
    f.setValue(data, forKey: "inputCubeData")
    f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
    return f
  }

  static func tone(_ tone: Optics.Tone) -> [CIFilter] {
    let m = Optics.matrix(tone)
    let matrix = CIFilter(name: "CIColorMatrix")!
    let keys = ["inputRVector", "inputGVector", "inputBVector"]
    for (row, key) in zip(m.rows, keys) {
      matrix.setValue(CIVector(x: row[0], y: row[1], z: row[2], w: 0), forKey: key)
    }
    matrix.setValue(CIVector(x: m.bias, y: m.bias, z: m.bias, w: 0), forKey: "inputBiasVector")
    let clamp = CIFilter(name: "CIColorClamp")!
    guard encoded else { return [matrix, clamp] }
    return [CIFilter(name: "CILinearToSRGBToneCurve")!, matrix, clamp, CIFilter(name: "CISRGBToneCurveToLinear")!]
  }
}
#endif
