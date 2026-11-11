import SwiftUI

/// What a piece of glass is like. Mirrors SwiftUI's `Glass`, so on iOS it is Apple's own.
public struct LiquidGlassStyle: Sendable, Hashable {
  public enum Variant: Sendable, Hashable {
    /// Frosted glass: blurred, lifted and saturated.
    case regular
    /// Clear glass: barely blurred, for glass over media.
    case clear
  }

  public var variant: Variant
  public var tint: Color?
  public var isInteractive: Bool

  public init(variant: Variant = .regular, tint: Color? = nil, isInteractive: Bool = false) {
    self.variant = variant
    self.tint = tint
    self.isInteractive = isInteractive
  }

  public static var regular: LiquidGlassStyle { LiquidGlassStyle() }
  public static var clear: LiquidGlassStyle { LiquidGlassStyle(variant: .clear) }

  /// Glass tinted with a colour. An opaque colour is laid on at iOS's strength.
  public func tint(_ color: Color?) -> LiquidGlassStyle {
    var copy = self
    copy.tint = color
    return copy
  }

  /// Glass that answers the pointer or a finger: it grows a little and lightens while pressed.
  public func interactive(_ isInteractive: Bool = true) -> LiquidGlassStyle {
    var copy = self
    copy.isInteractive = isInteractive
    return copy
  }
}

extension View {
  /// Sets the view on a piece of iOS 27 Liquid Glass.
  ///
  /// On iOS 26 and later this is Apple's `glassEffect`. On the Mac the package draws the glass
  /// itself, as iOS draws it, over whatever the window draws behind the view, and so it does for
  /// an iPhone or iPad app running on a Mac.
  public func liquidGlass(_ style: LiquidGlassStyle = .regular, in shape: GlassShape = .capsule) -> some View {
    modifier(LiquidGlassModifier(style: style, shape: shape))
  }

  /// Glass that can be put out of sight without taking it out of the layout, as a menu's button is
  /// while the menu that grew out of it is open.
  func liquidGlass(_ style: LiquidGlassStyle, in shape: GlassShape, hidden: Bool) -> some View {
    modifier(LiquidGlassModifier(style: style, shape: shape, hidden: hidden))
  }
}

/// A SwiftUI shape with iOS's continuous corners, for clipping or hit-testing alongside glass.
public struct ContinuousGlassShape: Shape {
  public var shape: GlassShape
  public init(_ shape: GlassShape) { self.shape = shape }
  public func path(in rect: CGRect) -> Path {
    Path(Contour.path(in: rect, radius: shape.radius(for: rect.size)))
  }
}

struct LiquidGlassModifier: ViewModifier {
  let style: LiquidGlassStyle
  let shape: GlassShape
  var hidden = false

  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @GestureState private var pressed = false

  func body(content: Content) -> some View {
    #if os(macOS)
    drawn(content)
    #else
    // An iPhone or iPad app on a Mac: the Mac's window server, so the package's glass, as iOS
    // draws it, rather than the flatter glass Apple draws for these apps there.
    if MacGlassView.onMac { drawn(content) } else { native(content) }
    #endif
  }

  @ViewBuilder
  private func drawn(_ content: Content) -> some View {
    let config = MacGlassView.Config(
      clear: style.variant == .clear,
      tint: style.tint.map { GlassColor($0) },
      shape: shape,
      dark: scheme == .dark,
      // As on iOS: glass is solid for someone who asked for less transparency or more contrast.
      opaque: reduceTransparency || contrast == .increased,
      hidden: hidden)
    let glass = content
      .background(MacGlass(config: config, pressed: pressed && style.isInteractive))
      .contentShape(ContinuousGlassShape(shape))
    if style.isInteractive {
      glass.simultaneousGesture(
        DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
    } else {
      glass
    }
  }

  #if os(iOS)
  @ViewBuilder
  private func native(_ content: Content) -> some View {
    if #available(iOS 26, *) {
      content.glassEffect(appleGlass, in: nativeShape).opacity(hidden ? 0 : 1)
    } else {
      content.background(.ultraThinMaterial, in: nativeShape).opacity(hidden ? 0 : 1)
    }
  }

  @available(iOS 26, *)
  private var appleGlass: Glass {
    var glass: Glass = style.variant == .clear ? .clear : .regular
    if let tint = style.tint { glass = glass.tint(tint) }
    if style.isInteractive { glass = glass.interactive() }
    return glass
  }

  private var nativeShape: AnyShape {
    switch shape {
    case .capsule: AnyShape(Capsule())
    case .circle: AnyShape(Circle())
    case .rect(let r): AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
    }
  }
  #endif
}

#if os(macOS)
struct MacGlass: NSViewRepresentable {
  var config: MacGlassView.Config
  var pressed: Bool

  func makeNSView(context: Context) -> MacGlassView { MacGlassView(frame: .zero) }

  func updateNSView(_ view: MacGlassView, context: Context) {
    view.config = config
    view.pressed = pressed
  }
}
#else
struct MacGlass: UIViewRepresentable {
  var config: MacGlassView.Config
  var pressed: Bool

  func makeUIView(context: Context) -> MacGlassView { MacGlassView(frame: .zero) }

  func updateUIView(_ view: MacGlassView, context: Context) {
    view.config = config
    view.pressed = pressed
  }
}
#endif
