#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// The menu that's open, drawn over the host's content.
struct GlassMenuOverlay: View {
  let presenter: GlassMenuPresenter
  static let radius: CGFloat = 33

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        if let current = presenter.current {
          TimelineView(.animation(minimumInterval: nil, paused: !presenter.moving)) { context in
            // A paused clock keeps the last frame it drew, which may be short of the end.
            let date = presenter.moving ? context.date : .distantFuture
            menu(current, at: date)
          }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      .onAppear {
        presenter.bounds = geometry.size
        Filters.warm()
      }
      .onChange(of: geometry.size) { presenter.bounds = geometry.size }
    }
  }

  @ViewBuilder
  private func menu(_ current: GlassMenuPresenter.Presentation, at date: Date) -> some View {
    let minWidth = current.minWidth
    ZStack(alignment: .topLeading) {
      // A press anywhere else closes the menu, and goes no further, as on iOS.
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { presenter.close() }
        // Closing, it lets the next press through at once, as iOS does: a press made while the
        // menu shrinks away goes to what's under it.
        .allowsHitTesting(presenter.goal == .open)
        .accessibilityHidden(true)

      if let size = presenter.size, let place = presenter.place() {
        let pose = presenter.pose(at: date, place: place, radius: Self.radius)
        let press = presenter.pressPose(at: date)
        let glass = CGRect(
          x: pose.glass.midX - pose.glass.width * press.scale / 2 + press.offset.width,
          y: pose.glass.midY - pose.glass.height * press.scale / 2 + press.offset.height,
          width: pose.glass.width * press.scale, height: pose.glass.height * press.scale)
        let corner = pose.corner * press.scale

        Color.clear
          .frame(width: max(1, glass.width), height: max(1, glass.height))
          .liquidGlass(.regular, in: .rect(cornerRadius: corner), hidden: !pose.showsGlass)
          .opacity(pose.opacity)
          .offset(x: glass.minX, y: glass.minY)
          .allowsHitTesting(false)

        // Pressed, the glass catches a little more light.
        ContinuousGlassShape(.rect(cornerRadius: corner))
          .fill(LinearGradient(
            colors: [.white.opacity(0.11), .white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(width: max(1, glass.width), height: max(1, glass.height))
          .opacity(press.light * pose.opacity)
          .offset(x: glass.minX, y: glass.minY)
          .allowsHitTesting(false)

        if let face = current.face {
          face
            .frame(width: current.trigger.width, height: current.trigger.height)
            .opacity(pose.showsGlass ? pose.face : 0)
            .blur(radius: 4 * (1 - pose.face))
            .offset(x: current.trigger.minX, y: current.trigger.minY)
            .allowsHitTesting(false)
        }

        MenuBody(
          entries: current.entries(upward: place.midY < current.trigger.midY), minWidth: minWidth, presenter: presenter,
          scrollHeight: place.height < size.height - 0.5 ? place.height : nil)
          .frame(width: place.width, height: place.height, alignment: .top)
          .scaleEffect(pose.zoom * press.scale, anchor: pose.anchor)
          .offset(x: place.minX + press.offset.width, y: place.minY + pose.shift + press.offset.height)
          .opacity(pose.showsGlass ? pose.rows * pose.opacity : 0)
          .blur(radius: pose.soft)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .mask(alignment: .topLeading) {
            ContinuousGlassShape(.rect(cornerRadius: corner))
              .frame(width: max(1, glass.width), height: max(1, glass.height))
              .offset(x: glass.minX, y: glass.minY)
          }
          .allowsHitTesting(pose.interactive)
      } else {
        // Laid out once out of sight, to learn its size.
        MenuRows(entries: current.entries, minWidth: minWidth, presenter: presenter, reports: false)
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { presenter.measured($0) }
      }
    }
  }
}

/// The rows, scrolling when the window hasn't room for them all, and answering the pointer.
struct MenuBody: View {
  let entries: [GlassMenuEntry]
  let minWidth: CGFloat
  let presenter: GlassMenuPresenter
  let scrollHeight: CGFloat?

  var body: some View {
    Group {
      if let scrollHeight {
        ScrollView(.vertical) {
          MenuRows(entries: entries, minWidth: minWidth, presenter: presenter, reports: true)
        }
        .scrollIndicators(.automatic)
        .frame(height: scrollHeight)
      } else {
        MenuRows(entries: entries, minWidth: minWidth, presenter: presenter, reports: true)
      }
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: GlassMenuHost.coordinates)
        .onChanged { presenter.press(at: $0.location, from: $0.startLocation) }
        .onEnded { presenter.pressEnded(at: $0.location) })
    .onContinuousHover(coordinateSpace: GlassMenuHost.coordinates) { phase in
      switch phase {
      case .active(let point): presenter.hover(point)
      case .ended: presenter.hover(nil)
      }
    }
  }
}

struct MenuRows: View {
  let entries: [GlassMenuEntry]
  let minWidth: CGFloat
  let presenter: GlassMenuPresenter
  /// Whether these rows tell the presenter where they are. The copy laid out to be measured doesn't.
  let reports: Bool
  @Environment(\.colorScheme) private var scheme
  @FocusState private var focused: Bool
  @Namespace private var plate

  private var dark: Bool { scheme == .dark }

  #if os(macOS)
  static let takesKeys = true
  #else
  static let takesKeys = false
  #endif
  private var highlight: Color { dark ? Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.13) : Color(.sRGB, red: 60 / 255, green: 60 / 255, blue: 67 / 255, opacity: 0.09) }
  private var separator: Color { dark ? Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.16) : Color(.sRGB, white: 0, opacity: 0.1) }
  private var muted: Color { dark ? Color(.sRGB, red: 235 / 255, green: 235 / 255, blue: 245 / 255, opacity: 0.6) : Color(.sRGB, red: 60 / 255, green: 60 / 255, blue: 67 / 255, opacity: 0.6) }
  // A menu's destructive row is a truer red than a button's.
  private var destructive: Color { dark ? Color(.sRGB, red: 1, green: 82 / 255, blue: 84 / 255) : Color(.sRGB, red: 220 / 255, green: 30 / 255, blue: 48 / 255) }

  private var choices: Bool {
    entries.contains { if case .item(let item) = $0 { item.isChecked != nil } else { false } }
  }

  /// Every row that can be chosen, in order, for the arrow keys.
  private var order: [RowID] {
    entries.indices.flatMap { index -> [RowID] in
      switch entries[index] {
      case .item(let item): item.isDisabled ? [] : [RowID(entry: index)]
      case .palette(let items): items.indices.filter { !items[$0].isDisabled }.map { RowID(entry: index, cell: $0) }
      default: []
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(entries.indices, id: \.self) { index in
        switch entries[index] {
        case .divider:
          Rectangle().fill(separator).frame(height: 1).padding(.vertical, 10).padding(.horizontal, 16)
            .accessibilityHidden(true)
        case .heading(let title):
          Text(title).font(.system(size: 13)).foregroundStyle(muted).lineLimit(1)
            .padding(EdgeInsets(top: 8, leading: 20, bottom: 3, trailing: 20))
            .accessibilityAddTraits(.isHeader)
        case .item(let item):
          row(item, RowID(entry: index))
        case .palette(let items):
          HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { cell in
              paletteCell(items[cell], RowID(entry: index, cell: cell))
            }
          }
          .padding(.vertical, 2)
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 8)
    .frame(minWidth: minWidth, alignment: .leading)
    .fixedSize()
    .animation(.easeOut(duration: 0.1), value: presenter.highlighted)
    // The keys need the keyboard's focus. A Mac app's menu takes it, as the Mac's own menus do;
    // in an iPhone or iPad app on a Mac, taking it would take it from whatever was being typed
    // in, which iOS's menus never do, so there the menu leaves it where it is.
    .focusable(reports && Self.takesKeys)
    .focusEffectDisabled()
    .focused($focused)
    .onAppear { if reports && Self.takesKeys { focused = true } }
    .onKeyPress(.escape) { presenter.close(); return .handled }
    .onKeyPress(.downArrow) { move(1); return .handled }
    .onKeyPress(.upArrow) { move(-1); return .handled }
    .onKeyPress(.rightArrow) { sideways(1) }
    .onKeyPress(.leftArrow) { sideways(-1) }
    .onKeyPress(.return) {
      if let id = presenter.highlighted { presenter.choose(id) }
      return .handled
    }
    .onKeyPress(.space) {
      if let id = presenter.highlighted { presenter.choose(id) }
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Menu")
  }

  /// Up and down go from row to row, and over a palette as one row.
  private func move(_ by: Int) {
    let rows = order.reduce(into: [RowID]()) { rows, id in
      if id.cell <= 0 || rows.last?.entry != id.entry { rows.append(id) }
    }
    guard !rows.isEmpty else { return }
    if let now = presenter.highlighted, let i = rows.firstIndex(where: { $0.entry == now.entry }) {
      presenter.highlighted = rows[(i + by + rows.count) % rows.count]
    } else {
      presenter.highlighted = by > 0 ? rows.first : rows.last
    }
  }

  /// Left and right go along a palette.
  private func sideways(_ by: Int) -> KeyPress.Result {
    guard let now = presenter.highlighted, now.cell >= 0 else { return .ignored }
    let cells = order.filter { $0.entry == now.entry }
    guard let i = cells.firstIndex(of: now) else { return .ignored }
    presenter.highlighted = cells[min(max(i + by, 0), cells.count - 1)]
    return .handled
  }

  private func plateBehind(_ id: RowID, enabled: Bool, radius: CGFloat) -> some View {
    ZStack {
      if presenter.highlighted == id && enabled {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(highlight)
          .matchedGeometryEffect(id: "plate", in: plate)
      }
    }
  }

  private func report(_ id: RowID, _ item: GlassMenuItem) -> some View {
    Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: GlassMenuHost.coordinates) } action: { frame in
      if reports { presenter.rows[id] = (frame, item) }
    }
  }

  private func row(_ item: GlassMenuItem, _ id: RowID) -> some View {
    HStack(spacing: 12) {
      if choices {
        // A choice keeps the room for its checkmark, chosen or not, so the labels line up.
        Image(systemName: "checkmark")
          .font(.system(size: 14, weight: .semibold))
          .frame(width: 16, height: 16)
          .opacity(item.isChecked == true ? 1 : 0)
          .padding(.trailing, -2)
      }
      if let image = item.image {
        image.resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle())
      } else if let symbol = item.systemImage {
        Image(systemName: symbol).font(.system(size: 18)).frame(width: 24, height: 24)
      }
      Text(item.title).font(.system(size: 17)).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
    .foregroundStyle(item.role == .destructive ? destructive : Color.primary)
    .opacity(item.isDisabled ? 0.38 : 1)
    .background { plateBehind(id, enabled: !item.isDisabled, radius: 21) }
    .background { report(id, item) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(item.isChecked == true ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { presenter.choose(item) }
  }

  private func paletteCell(_ item: GlassMenuItem, _ id: RowID) -> some View {
    VStack(spacing: 5) {
      if let image = item.image {
        // A face is drawn bigger than a symbol, as iOS draws the account in a menu's palette.
        image.resizable().scaledToFill().frame(width: 30, height: 30).clipShape(Circle())
      } else if let symbol = item.systemImage {
        Image(systemName: symbol).font(.system(size: 19)).frame(height: 24)
      }
      Text(item.title).font(.system(size: 12)).lineLimit(1)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 62)
    .foregroundStyle(item.role == .destructive ? destructive : Color.primary)
    .opacity(item.isDisabled ? 0.38 : 1)
    .background { plateBehind(id, enabled: !item.isDisabled, radius: 18) }
    .background { report(id, item) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { presenter.choose(item) }
  }
}

#if os(macOS)
/// Catches right-clicks and Control-clicks, and lets every other click through to SwiftUI.
struct SecondaryClick: NSViewRepresentable {
  var action: (CGPoint) -> Void

  func makeNSView(context: Context) -> Catcher { Catcher() }
  func updateNSView(_ view: Catcher, context: Context) { view.action = action }

  final class Catcher: NSView {
    var action: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }

    private static func isSecondary(_ event: NSEvent?) -> Bool {
      guard let event else { return false }
      return event.type == .rightMouseDown || event.type == .rightMouseUp
        || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      Self.isSecondary(NSApp.currentEvent) ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
      action?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
      if event.modifierFlags.contains(.control) { action?(convert(event.locationInWindow, from: nil)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }
  }
}
#endif

#if os(iOS)
/// Catches right-clicks and Control-clicks on an iPhone or iPad app running on a Mac, and lets
/// every other touch and click through to SwiftUI.
struct SecondaryClick: UIViewRepresentable {
  var action: (CGPoint) -> Void

  func makeUIView(context: Context) -> Catcher {
    let view = Catcher()
    let tap = UITapGestureRecognizer(target: view, action: #selector(Catcher.clicked(_:)))
    tap.buttonMaskRequired = .secondary
    view.addGestureRecognizer(tap)
    return view
  }

  func updateUIView(_ view: Catcher, context: Context) { view.action = action }

  final class Catcher: UIView {
    var action: ((CGPoint) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      guard let event, event.buttonMask.contains(.secondary) else { return nil }
      return super.hitTest(point, with: event)
    }

    @objc func clicked(_ tap: UITapGestureRecognizer) { action?(tap.location(in: self)) }
  }
}

/// Where an iPhone or iPad app running on a Mac shows its open menu: a view of its own, laid over
/// the window while the menu is open, with the glass in the window's layer just below it.
///
/// Glass can't stand among SwiftUI's own layers there (see `LiquidGlassModifier`), and a backdrop
/// sees only what its own parent layer has drawn beneath it. In the window's layer, right below
/// this view, what's beneath is the whole app, sheets included. It covers the window, and the
/// menu and its buttons count in the window's coordinates (`GlassMenuHost.coordinates`), so a
/// button in a sheet, which is outside the host's own views, opens its menu in the right place.
struct MenuWindow: UIViewRepresentable {
  let presenter: GlassMenuPresenter
  let isOpen: Bool
  /// False while the menu is closing: presses go straight through to the app.
  var takesInput = true
  let scheme: ColorScheme

  func makeUIView(context: Context) -> Holder { Holder() }

  func updateUIView(_ view: Holder, context: Context) {
    view.presenter = presenter
    view.scheme = scheme
    view.show(isOpen, takesInput: takesInput)
  }

  static func dismantleUIView(_ view: Holder, coordinator: ()) { view.show(false) }

  final class Holder: UIView {
    var presenter: GlassMenuPresenter?
    var scheme: ColorScheme = .light
    private var host: UIHostingController<AnyView>?
    private var built: ColorScheme?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The view is made once, as soon as there's a window, and kept, hidden while no menu is
    /// open: making it as a menu opens cost that menu its first frames.
    func show(_ open: Bool, takesInput: Bool = false) {
      guard let window, let presenter else { return }
      let made: UIHostingController<AnyView>
      if let host {
        made = host
      } else {
        made = UIHostingController(rootView: AnyView(EmptyView()))
        made.view.backgroundColor = .clear
        made.safeAreaRegions = []
        made.view.frame = window.bounds
        made.view.isHidden = true
        window.addSubview(made.view)
        host = made
        Filters.warm()
      }
      if built != scheme {
        made.rootView = AnyView(
          GlassMenuOverlay(presenter: presenter)
            .environment(\.glassInWindow, true)
            .environment(\.colorScheme, scheme)
            .ignoresSafeArea()
            .coordinateSpace(.named(GlassMenuHost.space)))
        built = scheme
      }
      if open {
        // Over anything shown since, a sheet say, which UIKit puts in the window above it.
        if made.view.superview !== window { window.addSubview(made.view) }
        window.bringSubviewToFront(made.view)
        made.view.frame = window.bounds
      }
      made.view.isHidden = !open
      made.view.isUserInteractionEnabled = open && takesInput
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { show(false) }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      if let made = host, let window { made.view.frame = window.bounds }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
      super.willMove(toWindow: newWindow)
      if newWindow == nil {
        host?.view.removeFromSuperview()
        host = nil
        built = nil
      }
    }
  }
}
#endif
#endif
