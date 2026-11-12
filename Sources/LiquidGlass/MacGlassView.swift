#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
typealias GlassBaseView = NSView
typealias GlassColor = NSColor
#else
import UIKit
typealias GlassBaseView = UIView
typealias GlassColor = UIColor
#endif
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
///
/// An iPhone or iPad app running on a Mac is drawn by the same window server, so the same view,
/// in UIKit, draws the same glass there (`onMac`). On an iPhone or iPad the window server is
/// iOS's, which runs none of these filters, and the modifier uses Apple's own glass instead.
@MainActor
final class MacGlassView: GlassBaseView {
  /// Whether this app draws the package's glass: a Mac app, or an iPhone or iPad app on a Mac.
  nonisolated static var onMac: Bool {
    #if os(macOS)
    true
    #else
    ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp
    #endif
  }

  struct Config: Equatable {
    var clear = false
    var tint: GlassColor?
    var shape: GlassShape = .capsule
    var dark = false
    var opaque = false
    /// Out of sight, but still in place.
    var hidden = false
    /// In a view laid over the whole window, whose glass goes in the window below it.
    var inWindow = false
  }

  var config = Config() { didSet { if config != oldValue { drawn = nil; refresh() } } }

  var pressed = false {
    didSet {
      guard pressed != oldValue else { return }
      // The pointer's feel from the web version: grows 6 points, quick in, softer out.
      spring.target = pressed ? 1 : 0
      if pressed { spring.stiffness = 417.6; spring.damping = 29.2 } else { spring.stiffness = 230; spring.damping = 23.7 }
      animate()
    }
  }

  /// The rings and the middle, which live beside SwiftUI's wrapper, not in this view.
  private var glassLayers: [CALayer] = []
  private let shadowLayer = CALayer()
  private let shadowCut = CAShapeLayer()
  private let chrome = GlassBaseView()
  private let tintLayer = CAShapeLayer()
  private let lightLayer = CAShapeLayer()
  private let rimLayer = CALayer()
  private var rimFor: (size: CGSize, radius: CGFloat, scale: CGFloat, clear: Bool)?
  private var rimDrawnAt: CFTimeInterval = 0
  private var rimDrawing = 0
  private var rimPending = false
  private var spring = Spring()
  /// Runs only while the glass is pressed or letting go; nothing runs while it is still.
  private var link: CADisplayLink?
  private var lastTime: CFTimeInterval = 0
  private var drawn: Drawn?
  /// Where SwiftUI's wrapper was last found among its parent's layers, so finding it again is
  /// one look rather than a search.
  private var wrapperIndex: Int?
  /// The blur and the tone, which don't change as the glass moves, made once per size and style.
  private var filtersFor: (short: CGFloat, config: Config, blur: CIFilter, tone: [CIFilter])?
  private var middleFor: CGPoint?

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

  /// This view's own layer, which AppKit makes optional and UIKit doesn't.
  private var own: CALayer? { layer }
  private var chromeLayer: CALayer? { chrome.layer }

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if os(macOS)
    wantsLayer = true
    chrome.wantsLayer = true
    #else
    isUserInteractionEnabled = false
    chrome.isUserInteractionEnabled = false
    #endif
    own?.masksToBounds = false
    shadowLayer.mask = shadowCut
    shadowCut.fillRule = .evenOdd
    own?.addSublayer(shadowLayer)
    chromeLayer?.masksToBounds = false
    addSubview(chrome)
    for l in [tintLayer, lightLayer] { l.fillColor = nil; chromeLayer?.addSublayer(l) }
    lightLayer.fillColor = GlassColor.white.cgColor
    lightLayer.opacity = 0
    rimLayer.contentsGravity = .resize
    chromeLayer?.addSublayer(rimLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  #if os(macOS)
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { removeGlass() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    follow()
  }

  private func makeLink() -> CADisplayLink { displayLink(target: self, selector: #selector(step(_:))) }

  override func layout() {
    super.layout()
    refresh()
  }

  private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
  private var rootLayer: CALayer? { window?.contentView?.layer }
  #else
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil { removeGlass() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    follow()
  }

  private func makeLink() -> CADisplayLink { CADisplayLink(target: WeakStep(self), selector: #selector(WeakStep.step(_:))) }

  override func layoutSubviews() {
    super.layoutSubviews()
    refresh()
  }

  private var scale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
  private var rootLayer: CALayer? { window?.layer }
  #endif

  /// The glass has to follow its place in its parent, which changes when anything around it
  /// does, not only when its own frame changes. `GlassSync` looks once each time the app has
  /// done something, after it is laid out; while the app is idle, nothing runs at all.
  private func follow() {
    drawn = nil
    wrapperIndex = nil
    if window != nil {
      GlassSync.shared.add(self)
      refresh()
      animate()
    } else {
      GlassSync.shared.remove(self)
      link?.invalidate()
      link = nil
    }
  }

  /// A display link for the press's spring, for as long as it moves.
  private func animate() {
    guard link == nil, window != nil, !spring.isResting else { return }
    let l = makeLink()
    l.add(to: .main, forMode: .common)
    link = l
    lastTime = 0
  }

  @objc fileprivate func step(_ link: CADisplayLink) {
    let now = link.timestamp
    let dt = lastTime == 0 ? 1.0 / 60 : min(now - lastTime, 1.0 / 30)
    lastTime = now
    spring.advance(dt)
    refresh()
    if spring.isResting {
      link.invalidate()
      self.link = nil
    }
  }

  private func removeGlass() {
    for l in glassLayers { l.removeFromSuperlayer() }
    glassLayers = []
    drawn = nil
    wrapperIndex = nil
    middleFor = nil
  }

  /// Puts the glass back in step with SwiftUI's wrapper, if anything about it has changed.
  func sync() { refresh() }

  /// SwiftUI's wrapper round this view, and the layer it sits in: where the glass goes.
  ///
  /// SwiftUI sometimes puts the wrapper in a group of its own, as it does for content laid over
  /// other content, with nothing drawn under it. Glass in there would have nothing to see, so it
  /// goes below the group instead, as long as the group adds nothing of its own: no fill, mask,
  /// filters or clipping.
  private var anchor: (wrapper: CALayer, parent: CALayer)? {
    #if os(iOS)
    // Over the whole window: right below that view, in the window's own layer, where SwiftUI
    // keeps nothing and what the app draws is beneath.
    if config.inWindow {
      var v: UIView = self
      while let up = v.superview, !(up is UIWindow) { v = up }
      guard let window = v.superview else { return nil }
      return (v.layer, window.layer)
    }
    #endif
    guard var wrapper = superview?.layer ?? own?.superlayer, var parent = wrapper.superlayer else { return nil }
    let root = rootLayer
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
    guard window != nil, let own, bounds.width > 0, bounds.height > 0, let (wrapper, parent) = anchor else { return }
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
    // Faded all the way out, as the screens an app keeps behind the one showing are: hidden, so
    // the window server has no backdrop to filter for it. Anything above `parent` that hides or
    // fades it hides its rings too, since they are inside it.
    let next = Drawn(
      placed: placed, local: local, scale: scale, config: config, progress: progress,
      opacity: opacity, hidden: hidden || opacity <= 0.001 || config.hidden)
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
      if l.frame != placed { l.frame = placed }
      if l.opacity != next.opacity { l.opacity = next.opacity }
      if l.isHidden != next.hidden { l.isHidden = next.hidden }
    }
    if !next.hidden { placeFilters(size: local.size, placed: placed, parent: parent, resized: resized) }
    lightLayer.opacity = Float(max(progress, 0) * 0.18)
    CATransaction.commit()
  }

  /// Whether the rings are still right below SwiftUI's wrapper, in order. SwiftUI may move the
  /// wrapper, or reorder what's round it. Where the wrapper was last time is looked at first.
  private func inPlace(wrapper: CALayer, parent: CALayer) -> Bool {
    let n = glassLayers.count
    guard n > 0, glassLayers[n - 1].superlayer === parent, let subs = parent.sublayers else { return false }
    func fits(_ w: Int) -> Bool {
      guard w >= n, w < subs.count, subs[w] === wrapper else { return false }
      for (i, l) in glassLayers.enumerated() where subs[w - n + i] !== l { return false }
      return true
    }
    if let w = wrapperIndex, fits(w) { return true }
    guard let w = subs.firstIndex(where: { $0 === wrapper }) else { return false }
    wrapperIndex = w
    return fits(w)
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
    shadowLayer.shadowColor = GlassColor.black.cgColor
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
    // Each ring is a step of `reach / rings` in the bend, and each is a backdrop of its own that
    // the window server filters again whenever anything under it changes, so as few as the eye
    // allows. Regular glass's blur, 15 points across, hides steps of a dozen points, so three
    // rings at most; clear glass shows its steps, so it takes up to eight.
    let rings = config.opaque ? 0
      : config.clear ? min(max(Int((bezel / 1.5).rounded()), 2), 8)
      : min(max(Int((bezel / 3).rounded()), 1), 3)
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
    wrapperIndex = nil
    middleFor = nil

    // The masks are drawn in the rings' own coordinates, which may be flipped from this view's.
    let flip = parent.contentsAreFlipped() != (own?.contentsAreFlipped() ?? false)
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
          ? (config.dark ? GlassColor(white: 0.16, alpha: 1) : GlassColor(white: 0.96, alpha: 1)).cgColor
          : nil
      }
    }

    tintLayer.frame = local
    tintLayer.path = full
    if let tint = config.tint {
      let alpha = tint.cgColor.alpha
      let a = alpha >= 1 ? 0.72 : alpha
      tintLayer.fillColor = tint.withAlphaComponent(a).cgColor
    } else {
      tintLayer.fillColor = nil
    }
    lightLayer.frame = local
    lightLayer.path = full

    // The rim only needs drawing again when the size changes by more than a sliver. Drawing it
    // takes milliseconds, so while the glass is changing size, as a menu does as it grows, it is
    // drawn at most every eighth of a second and stretched in between, its corners kept as they
    // are; once the glass settles it is drawn again at its size.
    if rimIsStale(size: size, radius: radius, scale: scale) {
      if rimFor == nil {
        drawRim(size: size, radius: radius, scale: scale)
      } else if CACurrentMediaTime() - rimDrawnAt > 0.12 {
        drawRim(size: size, radius: radius, scale: scale, later: true)
      } else if !rimPending {
        rimPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
          guard let self else { return }
          self.rimPending = false
          guard let drawn = self.drawn else { return }
          let size = drawn.local.size
          let radius = self.config.shape.radius(for: size)
          guard self.rimIsStale(size: size, radius: radius, scale: drawn.scale) else { return }
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          self.drawRim(size: size, radius: radius, scale: drawn.scale, later: true)
          CATransaction.commit()
        }
      }
    }
    rimLayer.frame = local.insetBy(dx: -margin, dy: -margin)
  }

  private func rimIsStale(size: CGSize, radius: CGFloat, scale: CGFloat) -> Bool {
    rimFor.map {
      abs($0.size.width - size.width) > 0.75 || abs($0.size.height - size.height) > 0.75
        || abs($0.radius - radius) > 0.25 || $0.scale != scale || $0.clear != config.clear
    } ?? true
  }

  /// `later`: drawn away from the main thread, and put up when it's ready, so a frame that asks for
  /// a new rim doesn't wait milliseconds for it. The old one stretches until then.
  private func drawRim(size: CGSize, radius: CGFloat, scale: CGFloat, later: Bool = false) {
    let clear = config.clear
    rimFor = (size, radius, scale, clear)
    rimDrawnAt = CACurrentMediaTime()
    // Any rim drawn now outdates one still being drawn.
    rimDrawing += 1
    guard later else {
      put(rim: Rim.image(size: size, radius: radius, scale: scale, margin: margin, shine: 1, clear: clear ? 1 : 0), size: size, radius: radius)
      return
    }
    let ticket = rimDrawing, margin = margin
    DispatchQueue.global(qos: .userInteractive).async {
      let image = Rim.image(size: size, radius: radius, scale: scale, margin: margin, shine: 1, clear: clear ? 1 : 0)
      let made = UncheckedImage(image: image)
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          // Only the newest one asked for: an older one finishing late would put up the wrong size.
          guard let self, self.rimDrawing == ticket else { return }
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          self.put(rim: made.image, size: size, radius: radius)
          CATransaction.commit()
        }
      }
    }
  }

  private func put(rim image: CGImage?, size: CGSize, radius: CGFloat) {
    rimLayer.contents = image
    // Stretched, only the straight runs between the corners grow: the corners stay as drawn.
    let w = size.width + margin * 2, h = size.height + margin * 2
    let inset = margin + min(radius, min(size.width, size.height) / 2)
    rimLayer.contentsCenter = CGRect(
      x: inset / w, y: inset / h, width: max(0, w - inset * 2) / w, height: max(0, h - inset * 2) / h)
  }

  /// The filters, which work in the parent's coordinates, so they follow the glass as it moves.
  /// Only the bend depends on where the glass is; the blur and the tone are kept from last time
  /// unless the size or style changed, and nothing is set again if the glass hasn't moved.
  private func placeFilters(size: CGSize, placed: CGRect, parent: CALayer, resized: Bool) {
    guard !config.opaque else {
      for l in glassLayers where l.backgroundFilters != nil { l.backgroundFilters = nil }
      middleFor = nil
      return
    }
    // The filters count in the parent layer's own coordinates, whichever way up they are.
    let middle = CGPoint(x: placed.midX, y: placed.midY)
    if !resized, middleFor == middle { return }
    middleFor = middle
    let short = min(size.width, size.height)
    let bezel = Optics.bezel(short)
    let reach = Optics.reach(short)
    let rings = glassLayers.count - 1
    let made: (blur: CIFilter, tone: [CIFilter])
    // The tone moves with the size only up to 120 points and by little, so it's kept for steps of
    // 4 points rather than made again at every size a growing menu passes through.
    if let f = filtersFor, abs(f.short - short) < 4 || (f.short >= 120 && short >= 120), f.config == config {
      made = (f.blur, f.tone)
    } else {
      let tone = config.dark && !config.clear
        ? [Filters.darkCube(size: Optics.sizeCurve(short))]
        : Filters.tone(Optics.tone(short: short, dark: config.dark, clear: config.clear))
      made = (Filters.blur(Optics.blur(clear: config.clear)), tone)
      filtersFor = (short, config, made.blur, made.tone)
    }
    let blur = made.blur, tone = made.tone
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
      // The backdrop ends at the layer's edge, and a blur reaching past it would average in
      // nothing, darkening the rings at the rim against the middle: a faint inner outline that
      // iOS's glass doesn't have. Clamped, the edge's own colour runs on outward instead.
      chain.append(Filters.clamp())
      chain.append(blur)
      chain.append(contentsOf: tone)
      l.backgroundFilters = chain
    }
  }
}

#if os(iOS)
/// UIKit's display link holds its target strongly, so it holds this instead, which lets the
/// glass go when its view does.
@MainActor
private final class WeakStep: NSObject {
  weak var view: MacGlassView?
  init(_ view: MacGlassView) { self.view = view }
  @objc func step(_ link: CADisplayLink) {
    guard let view else { link.invalidate(); return }
    view.step(link)
  }
}
#endif

/// Keeps every piece of glass beside SwiftUI's wrapper, with no timer.
///
/// SwiftUI moves a wrapper without telling the view inside it, so the glass has to look. It looks
/// once each time the main run loop has done something and is about to sleep, just after Core
/// Animation has laid out and committed what the app changed, and sends its own changes in a
/// transaction of their own, so they reach the screen in the same frame. An app that does nothing
/// wakes nothing: no display link runs while the glass is still.
@MainActor
final class GlassSync {
  static let shared = GlassSync()

  private let views = NSHashTable<MacGlassView>.weakObjects()
  private var observer: CFRunLoopObserver?

  func add(_ view: MacGlassView) {
    views.add(view)
    guard observer == nil else { return }
    // Core Animation commits at order 2,000,000; this runs after it.
    let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_100) { _, _ in
      MainActor.assumeIsolated { GlassSync.shared.sync() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    observer = o
  }

  func remove(_ view: MacGlassView) {
    views.remove(view)
    if views.count == 0, let o = observer {
      CFRunLoopObserverInvalidate(o)
      observer = nil
    }
  }

  private func sync() {
    for view in views.allObjects { view.sync() }
  }
}

/// A drawn rim, handed from the queue that drew it to the main thread. A `CGImage` is immutable.
private struct UncheckedImage: @unchecked Sendable { let image: CGImage? }

/// The built-in Core Image filters the window server runs on a backdrop.
@MainActor
enum Filters {
  /// Which colour space the tone's matrix is worked in. CSS filters, which liquidglass's numbers
  /// were fitted with, work on sRGB-encoded values, so by default the matrix runs between curves
  /// that take the backdrop there and back. `LIQUIDGLASS_TONE=linear` turns that off, for measuring.
  static let encoded = ProcessInfo.processInfo.environment["LIQUIDGLASS_TONE"] != "linear"

  /// Carries the image's edge out forever, so a blur near the edge has something to blur.
  static func clamp() -> CIFilter { CIFilter(name: "CIAffineClamp")! }

  static func blur(_ sigma: CGFloat) -> CIFilter {
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(sigma, forKey: kCIInputRadiusKey)
    return f
  }

  static func magnify(about c: CGPoint, x: CGFloat, y: CGFloat) -> CIFilter {
    let f = CIFilter(name: "CIAffineTransform")!
    #if os(macOS)
    var t = AffineTransform(translationByX: -c.x, byY: -c.y)
    t.append(AffineTransform(scaleByX: x, byY: y))
    t.append(AffineTransform(translationByX: c.x, byY: c.y))
    f.setValue(NSAffineTransform(transform: t), forKey: kCIInputTransformKey)
    #else
    let t = CGAffineTransform(translationX: -c.x, y: -c.y)
      .concatenating(CGAffineTransform(scaleX: x, y: y))
      .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    f.setValue(NSValue(cgAffineTransform: t), forKey: kCIInputTransformKey)
    #endif
    return f
  }

  private static var cubes: [Int: Data] = [:]
  private nonisolated static let cubeSize = 24

  /// The cube for one quarter-step of the size curve. Some tens of milliseconds of arithmetic.
  private nonisolated static func cubeData(step: Int) -> Data {
    let n = cubeSize
    var values = [Float]()
    values.reserveCapacity(n * n * n * 4)
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
      let rgb = [r, g, b].map { Double($0) / Double(n - 1) }
      values += Optics.dark(rgb, size: Double(step) / 4).map(Float.init) + [1]
    } } }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  /// Makes every dark cube away from the main thread, so the first dark menu doesn't wait for one.
  static func warm() {
    guard cubes.count < 5, !warming else { return }
    warming = true
    Task.detached(priority: .utility) {
      let made = (0...4).map { (step: $0, data: cubeData(step: $0)) }
      await MainActor.run {
        for m in made where cubes[m.step] == nil { cubes[m.step] = m.data }
      }
    }
  }
  private static var warming = false

  /// Dark glass's tone as a colour cube, worked in sRGB, since no matrix can follow it. Sizes are
  /// taken in quarters of the curve, as the web version does, and each cube is made once.
  static func darkCube(size: CGFloat) -> CIFilter {
    let step = Int((size * 4).rounded())
    let data = cubes[step] ?? {
      let made = cubeData(step: step)
      cubes[step] = made
      return made
    }()
    let f = CIFilter(name: "CIColorCubeWithColorSpace")!
    f.setValue(cubeSize, forKey: "inputCubeDimension")
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
