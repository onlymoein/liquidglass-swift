import SwiftUI

// MARK: - What a menu holds

/// One row of a glass menu: an action, or one of a set of choices when it has a checkmark.
public struct GlassMenuItem {
  public var title: String
  public var systemImage: String?
  public var role: ButtonRole?
  /// `nil` for an action. For a choice, whether it's the one chosen.
  public var isChecked: Bool?
  public var isDisabled: Bool
  public var action: @MainActor () -> Void

  public init(
    _ title: String, systemImage: String? = nil, role: ButtonRole? = nil, isDisabled: Bool = false,
    action: @escaping @MainActor () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.role = role
    self.isChecked = nil
    self.isDisabled = isDisabled
    self.action = action
  }

  /// One of a set of choices, with a checkmark beside it when it's the one chosen.
  public init(
    _ title: String, systemImage: String? = nil, isChecked: Bool, isDisabled: Bool = false,
    action: @escaping @MainActor () -> Void
  ) {
    self.init(title, systemImage: systemImage, isDisabled: isDisabled, action: action)
    self.isChecked = isChecked
  }

  /// A picture in place of a symbol, such as a person's photo, drawn round as iOS draws one.
  public var image: Image?

  /// A row with a picture of its own, such as the photo of the person signed in.
  public init(
    _ title: String, image: Image, role: ButtonRole? = nil, isDisabled: Bool = false,
    action: @escaping @MainActor () -> Void
  ) {
    self.init(title, role: role, isDisabled: isDisabled, action: action)
    self.image = image
  }
}

/// A line between groups of rows.
public struct GlassMenuDivider {
  public init() {}
}

/// A section's title, in small grey type above the rows it introduces.
public struct GlassMenuHeading {
  public var title: String
  public init(_ title: String) { self.title = title }
}

/// A row of small buttons side by side, an icon over a word, as iOS puts the commonest
/// actions across the top of a menu.
public struct GlassMenuPalette {
  public var items: [GlassMenuItem]
  public init(@GlassMenuBuilder _ items: () -> [GlassMenuEntry]) {
    self.items = items().compactMap { if case .item(let item) = $0 { item } else { nil } }
  }
}

public enum GlassMenuEntry {
  case item(GlassMenuItem)
  case palette([GlassMenuItem])
  case heading(String)
  case divider
}

@resultBuilder
public enum GlassMenuBuilder {
  public static func buildExpression(_ item: GlassMenuItem) -> [GlassMenuEntry] { [.item(item)] }
  public static func buildExpression(_ palette: GlassMenuPalette) -> [GlassMenuEntry] { [.palette(palette.items)] }
  public static func buildExpression(_: GlassMenuDivider) -> [GlassMenuEntry] { [.divider] }
  public static func buildExpression(_ heading: GlassMenuHeading) -> [GlassMenuEntry] { [.heading(heading.title)] }
  public static func buildExpression(_ entries: [GlassMenuEntry]) -> [GlassMenuEntry] { entries }
  public static func buildBlock(_ parts: [GlassMenuEntry]...) -> [GlassMenuEntry] { parts.flatMap { $0 } }
  public static func buildOptional(_ part: [GlassMenuEntry]?) -> [GlassMenuEntry] { part ?? [] }
  public static func buildEither(first part: [GlassMenuEntry]) -> [GlassMenuEntry] { part }
  public static func buildEither(second part: [GlassMenuEntry]) -> [GlassMenuEntry] { part }
  public static func buildArray(_ parts: [[GlassMenuEntry]]) -> [GlassMenuEntry] { parts.flatMap { $0 } }
}

/// The edge of its button a menu lines up with as it opens across it.
public enum GlassMenuAlignment: Sendable {
  case leading, center, trailing
}

// MARK: - The button

/// A button on glass that opens a menu, which grows out of the button as iOS 27's does.
///
/// The menu opens as the button is pressed, so a press can slide onto a row and choose it by
/// letting go, or a click can open it and a second click choose.
///
/// On the Mac the menu is drawn in the window, over its content, and needs `.glassMenuHost()`
/// on a view that covers the window; so it is for an iPhone or iPad app running on a Mac, where
/// the system's own menu is the Mac's. Without a host, and on an iPhone or iPad, it's the
/// system's own menu, which there is iOS's.
public struct GlassMenu<Label: View>: View {
  /// The button's glass, or `nil` for a button that brings its own look, such as a row, a form
  /// field or a toolbar icon: its menu grows out of it on iOS's spring, and it stays in view.
  var style: LiquidGlassStyle?
  var shape: GlassShape
  var align: GlassMenuAlignment
  var primaryAction: (@MainActor () -> Void)?
  var items: () -> [GlassMenuEntry]
  var label: Label

  public init(
    style: LiquidGlassStyle? = .regular, in shape: GlassShape = .capsule, align: GlassMenuAlignment = .center,
    @GlassMenuBuilder items: @escaping () -> [GlassMenuEntry], @ViewBuilder label: () -> Label
  ) {
    self.style = style
    self.shape = shape
    self.align = align
    self.items = items
    self.label = label()
  }

  /// A button that does `primaryAction` when it's clicked or tapped, and opens its menu when it's
  /// held, as SwiftUI's `Menu(primaryAction:)` does. It brings its own look.
  public init(
    align: GlassMenuAlignment = .center, primaryAction: @escaping @MainActor () -> Void,
    @GlassMenuBuilder items: @escaping () -> [GlassMenuEntry], @ViewBuilder label: () -> Label
  ) {
    self.style = nil
    self.shape = .capsule
    self.align = align
    self.primaryAction = primaryAction
    self.items = items
    self.label = label()
  }

  @Environment(GlassMenuPresenter.self) private var presenter: GlassMenuPresenter?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var id = UUID()
  /// Where it is, kept where SwiftUI doesn't watch: it changes on every frame of a scroll, and
  /// the menu needs it only when it opens.
  @State private var place = Spot()
  private var frame: CGRect { place.frame }
  @State private var pressed = false

  public var body: some View {
    if let presenter {
      drawn(presenter)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: GlassMenuHost.coordinates) } action: { place.frame = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let primaryAction { primaryAction() } else { open(presenter) } }
        .accessibilityAction(named: "Show Menu") { open(presenter) }
    } else if let primaryAction {
      Menu { SystemMenuItems(entries: items()) } label: { label } primaryAction: { primaryAction() }
        .menuStyle(.button)
        .buttonStyle(.plain)
    } else {
      SystemMenu(style: style, shape: shape, entries: items(), label: label)
    }
  }

  @ViewBuilder
  private func drawn(_ presenter: GlassMenuPresenter) -> some View {
    if let primaryAction {
      // A click does the button's own thing; a hold opens the menu.
      label
        .contentShape(Rectangle())
        .gesture(
          LongPressGesture(minimumDuration: 0.4)
            .onEnded { _ in if isEnabled { open(presenter) } }
            .exclusively(before: TapGesture().onEnded { if isEnabled { primaryAction() } }))
    } else if let style {
      TimelineView(.animation(minimumInterval: nil, paused: !presenter.moves(id))) { context in
        // A paused clock keeps the last frame it drew, which may be short of the end.
        let pose = presenter.triggerPose(id, at: presenter.moves(id) ? context.date : .distantFuture)
        label
          .liquidGlass(style.interactive(), in: shape, hidden: pose.hidden)
          .opacity(pose.hidden ? 0 : 1)
          .scaleEffect(x: pose.scaleX, y: 1)
          .offset(y: pose.lift)
      }
      .simultaneousGesture(pressAndSlide(presenter))
    } else {
      label
        .contentShape(Rectangle())
        .simultaneousGesture(pressAndSlide(presenter))
    }
  }

  /// Pressing opens the menu; sliding onto a row and letting go there chooses it.
  private func pressAndSlide(_ presenter: GlassMenuPresenter) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: GlassMenuHost.coordinates)
      .onChanged { drag in
        guard isEnabled else { return }
        if pressed {
          presenter.scrub(to: drag.location, from: drag.startLocation)
        } else {
          pressed = true
          open(presenter)
        }
      }
      .onEnded { drag in
        pressed = false
        presenter.scrubEnded(at: drag.location)
      }
  }

  private func open(_ presenter: GlassMenuPresenter) {
    guard isEnabled else { return }
    let kind: GlassMenuPresenter.Kind = style == nil ? .anchor(frame) : .button(frame)
    presenter.open(.init(
      id: id, kind: kind, style: style ?? .regular, align: align, face: style == nil ? nil : AnyView(label),
      entries: items(), reduceMotion: reduceMotion))
  }
}

/// A button on glass that shows what's chosen, and opens a menu of the choices.
public struct GlassPicker<Value: Hashable>: View {
  var selection: Binding<Value>
  var options: [Value]
  var title: (Value) -> String
  var systemImage: ((Value) -> String?)?
  var heading: String?
  var style: LiquidGlassStyle

  public init(
    _ heading: String? = nil, selection: Binding<Value>, options: [Value], style: LiquidGlassStyle = .regular,
    title: @escaping (Value) -> String, systemImage: ((Value) -> String?)? = nil
  ) {
    self.heading = heading
    self.selection = selection
    self.options = options
    self.title = title
    self.systemImage = systemImage
    self.style = style
  }

  public var body: some View {
    GlassMenu(style: style, in: .capsule, align: .center) {
      if let heading { GlassMenuHeading(heading) }
      for option in options {
        GlassMenuItem(title(option), systemImage: systemImage?(option), isChecked: option == selection.wrappedValue) {
          selection.wrappedValue = option
        }
      }
    } label: {
      HStack(spacing: 8) {
        if let symbol = systemImage?(selection.wrappedValue) { Image(systemName: symbol) }
        Text(title(selection.wrappedValue))
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 12, weight: .semibold))
          .opacity(0.6)
      }
      .font(.system(size: 17))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 18)
      .frame(height: 44)
      .contentShape(Capsule())
    }
  }
}

// MARK: - Right-click menus

extension View {
  /// A glass menu that opens where the view is right-clicked, or Control-clicked, growing out
  /// of the pointer, on the Mac and in an iPhone or iPad app running on one. Without a
  /// `.glassMenuHost()`, and on an iPhone or iPad, it's the system's context menu.
  public func glassContextMenu(@GlassMenuBuilder _ items: @escaping () -> [GlassMenuEntry]) -> some View {
    modifier(GlassContextMenu(items: items))
  }
}

struct GlassContextMenu: ViewModifier {
  var items: () -> [GlassMenuEntry]

  @Environment(GlassMenuPresenter.self) private var presenter: GlassMenuPresenter?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var id = UUID()
  /// Where it is, kept where SwiftUI doesn't watch: it changes on every frame of a scroll, and
  /// the menu needs it only when it opens.
  @State private var place = Spot()
  private var frame: CGRect { place.frame }

  func body(content: Content) -> some View {
    if let presenter {
      content
        .overlay {
          SecondaryClick { point in
            presenter.open(.init(
              id: id, kind: .point(CGPoint(x: frame.minX + point.x, y: frame.minY + point.y)), style: .regular,
              align: .leading, face: nil, entries: items(), reduceMotion: reduceMotion))
          }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: GlassMenuHost.coordinates) } action: { place.frame = $0 }
        .accessibilityAction(named: "Show Menu") {
          presenter.open(.init(
            id: id, kind: .point(CGPoint(x: frame.midX, y: frame.midY)), style: .regular, align: .leading,
            face: nil, entries: items(), reduceMotion: reduceMotion))
        }
    } else {
      content.contextMenu { SystemMenuItems(entries: items()) }
    }
  }
}

// MARK: - The system's own

/// The system's own menu, for where there's no glass menu host, and on iOS.
struct SystemMenu<Label: View>: View {
  var style: LiquidGlassStyle?
  var shape: GlassShape
  var entries: [GlassMenuEntry]
  var label: Label

  private var systemShape: AnyShape {
    switch shape {
    case .capsule: AnyShape(Capsule())
    case .circle: AnyShape(Circle())
    case .rect(let r): AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
    }
  }

  var body: some View {
    let menu = Menu {
      SystemMenuItems(entries: entries)
    } label: {
      label
    }
    .menuIndicator(.hidden)
    if let style { styled(menu, style) } else { menu.menuStyle(.button).buttonStyle(.plain) }
  }

  @ViewBuilder
  private func styled(_ menu: some View, _ style: LiquidGlassStyle) -> some View {
    #if os(macOS)
    let plain = menu.menuStyle(.button).buttonStyle(.plain).fixedSize()
    if #available(macOS 26, *) {
      plain.glassEffect(style.variant == .clear ? .clear.interactive() : .regular.interactive(), in: systemShape)
    } else {
      plain.background(.ultraThinMaterial, in: systemShape)
    }
    #else
    if #available(iOS 26, *) {
      menu.buttonStyle(.glass)
    } else {
      menu.liquidGlass(style.interactive(), in: shape)
    }
    #endif
  }
}

struct SystemMenuItems: View {
  var entries: [GlassMenuEntry]

  var body: some View {
    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
      switch entry {
      case .divider: Divider()
      case .heading(let title): Section(title) {}
      case .item(let item): button(item)
      case .palette(let items):
        ControlGroup {
          ForEach(Array(items.enumerated()), id: \.offset) { _, item in button(item) }
        }
      }
    }
  }

  private func button(_ item: GlassMenuItem) -> some View {
    Button(role: item.role) { item.action() } label: {
      if item.isChecked == true {
        Label(item.title, systemImage: "checkmark")
      } else if let symbol = item.systemImage {
        Label(item.title, systemImage: symbol)
      } else {
        Text(item.title)
      }
    }
    .disabled(item.isDisabled)
  }
}

/// A view's frame, held by reference so that changing it redraws nothing.
final class Spot {
  var frame = CGRect.zero
}

// MARK: - The host

extension View {
  /// Lets the glass menus inside this view open over it, as iOS's do. Put it on a view that
  /// covers the window. Off, the menus are the system's own.
  public func glassMenuHost(_ isEnabled: Bool = true) -> some View {
    modifier(GlassMenuHost(isEnabled: isEnabled))
  }
}

struct GlassMenuHost: ViewModifier {
  nonisolated static let space = "liquidglass.menu-host"
  /// Where menus and their buttons are measured: the host's own space on the Mac; on an iPhone
  /// or iPad app running on a Mac, the window's, which reaches into sheets too (`MenuWindow`).
  nonisolated static var coordinates: CoordinateSpace {
    #if os(macOS)
    .named(space)
    #else
    .global
    #endif
  }
  var isEnabled: Bool

  @State private var presenter = GlassMenuPresenter()
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    // On an iPhone or iPad the system's menu is already iOS's, so the host steps aside.
    if isEnabled && MacGlassView.onMac {
      #if os(macOS)
      content
        .environment(presenter)
        .overlay { GlassMenuOverlay(presenter: presenter) }
        .coordinateSpace(.named(Self.space))
      #else
      // An iPhone or iPad app on a Mac: the open menu stands over the window (`MenuWindow`).
      content
        .environment(presenter)
        .background { MenuWindow(presenter: presenter, isOpen: presenter.current != nil, scheme: scheme) }
        .coordinateSpace(.named(Self.space))
      #endif
    } else {
      content
    }
  }
}
