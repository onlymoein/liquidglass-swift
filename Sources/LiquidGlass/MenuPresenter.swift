#if os(macOS) || os(iOS)
import SwiftUI

// MARK: - The motion

/// The glass's shape as it opens and closes, one row a frame at 60fps, read from iOS 27 by the
/// web version. Width, height and centre are how far along from the button (0) to the menu (1).
/// The width goes well below 0: the pill squeezes into a ball as it drops, and the ball swells
/// into the menu. Then how much the rows are zoomed, and how round the corners are, from as round
/// as the shape allows (1) to the menu's own (0).
enum MenuMotion {
  typealias Row = (width: Double, height: Double, centre: Double, zoom: Double, round: Double)

  static let opening: [Row] = [
    (0, 0, 0, 0.7, 1), (-0.43, 0, 0.01, 0.7, 1), (-1.28, 0.04, 0.15, 0.7, 1), (-1.48, 0.435, 0.73, 0.75, 1),
    (-1.22, 0.53, 0.88, 0.85, 1), (-0.97, 0.6, 1, 0.95, 1), (-0.52, 0.73, 1.2, 1.08, 1), (-0.14, 0.81, 1.33, 1.19, 1),
    (0.21, 0.88, 1.4, 1.25, 0.92), (0.45, 0.91, 1.4, 1.27, 0.83), (0.66, 0.95, 1.365, 1.28, 0.75),
    (0.8, 0.97, 1.31, 1.25, 0.66), (0.93, 0.99, 1.25, 1.2, 0.58), (1.03, 1.01, 1.2, 1.16, 0.49),
    (1.07, 1.02, 1.14, 1.12, 0.41), (1.1, 1.02, 1.087, 1.09, 0.32), (1.1, 1.02, 1.052, 1.06, 0.24),
    (1.1, 1.02, 1.035, 1.04, 0.15), (1.07, 1.02, 1.017, 1.03, 0.1), (1.07, 1.02, 1, 1.02, 0.05),
    (1.07, 1.01, 0.99, 1.01, 0.02), (1.03, 1.01, 0.99, 1, 0), (1.02, 1.01, 0.99, 1, 0), (1.01, 1, 0.99, 1, 0),
    (1, 1, 1, 1, 0),
  ]

  static let closing: [Row] = [
    (1, 1, 1, 1, 0), (0.86, 0.98, 1.226, 1, 0.2), (0.64, 0.94, 1.41, 0.98, 0.5), (0.33, 0.9, 1.44, 0.95, 0.75),
    (-0.02, 0.86, 1.365, 0.92, 1), (-0.38, 0.81, 1.21, 0.9, 1), (-0.72, 0.74, 1.02, 0.88, 1),
    (-1.05, 0.66, 0.82, 0.86, 1), (-1.34, 0.57, 0.63, 0.84, 1), (-1.59, 0.49, 0.47, 0.82, 1),
  ]

  /// As the glass runs back into it, the button's width as a share of its own, and its lift in points.
  static let landing: [(scaleX: Double, lift: Double)] = [
    (0.61, -3), (0.69, -5), (0.76, -6), (0.81, -7), (0.865, -7), (0.9, -6), (0.93, -6), (0.96, -5), (0.98, -5),
    (0.99, -4), (1, -4), (1.01, -3), (1.016, -2), (1.02, -2), (1.02, -1), (1.016, -1), (1.016, -1), (1.01, 0),
    (1.008, 0), (1.004, 0), (1, 0),
  ]

  static var openFrames: Double { Double(opening.count - 1) }
  static var closeFrames: Double { Double(closing.count) }
  static var landFrames: Double { Double(landing.count - 1) }
  /// With Reduce Motion on, a menu fades in and out over this many frames instead.
  static let fadeFrames = 6.0

  static func row(_ table: [Row], _ at: Double) -> Row {
    let i = min(max(Int(at.rounded(.down)), 0), table.count - 1)
    let a = table[i], b = table[min(i + 1, table.count - 1)]
    let t = min(max(at - Double(i), 0), 1)
    func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
    return (mix(a.width, b.width), mix(a.height, b.height), mix(a.centre, b.centre), mix(a.zoom, b.zoom), mix(a.round, b.round))
  }

  /// The row whose height is closest, so one motion can take over from the other part-way.
  static func nearest(_ table: [Row], height: Double) -> Double {
    Double(table.indices.min { abs(table[$0].height - height) < abs(table[$1].height - height) } ?? 0)
  }

  static func landingRow(_ at: Double) -> (scaleX: Double, lift: Double) {
    let i = min(max(Int(at.rounded(.down)), 0), landing.count - 1)
    let a = landing[i], b = landing[min(i + 1, landing.count - 1)]
    let t = min(max(at - Double(i), 0), 1)
    return (a.scaleX + (b.scaleX - a.scaleX) * t, a.lift + (b.lift - a.lift) * t)
  }

  /// How a press drags the menu: a little at first, then hardly more, 7 points at most.
  static func resistance(_ value: CGFloat) -> CGFloat {
    (value < 0 ? -1 : 1) * 7 * (1 - exp(-abs(value) * 0.12 / 7))
  }
}

/// A spring let go at a moment, read at any later one. The spring's solution is exact, so it
/// needs no stepping frame by frame.
struct Settle {
  var from = 0.0
  var to = 0.0
  var stiffness = 600.0
  var damping = 30.0
  var start = Date.distantPast

  init(_ value: Double = 0) {
    from = value
    to = value
  }

  init(from: Double, to: Double, stiffness: Double, damping: Double, start: Date) {
    self.from = from
    self.to = to
    self.stiffness = stiffness
    self.damping = damping
    self.start = start
  }

  func value(at date: Date) -> Double {
    var spring = Spring(value: from, target: to, velocity: 0, stiffness: stiffness, damping: damping)
    spring.advance(max(0, date.timeIntervalSince(start)))
    return spring.value
  }

  /// From wherever it is now, towards a new value.
  func retarget(_ to: Double, stiffness: Double, damping: Double, at now: Date) -> Settle {
    Settle(from: value(at: now), to: to, stiffness: stiffness, damping: damping, start: now)
  }

  /// How long it takes to come to rest.
  var duration: Double {
    var spring = Spring(value: from, target: to, velocity: 0, stiffness: stiffness, damping: damping)
    var t = 0.0
    while !spring.isResting && t < 2 {
      spring.advance(1.0 / 240)
      t += 1.0 / 240
    }
    return t
  }
}

/// Where a menu goes.
enum MenuPlacement {
  static let edge: CGFloat = 8

  /// As on iOS a button's menu covers it: it starts at the button's top and grows down, or,
  /// without room below, at its bottom and grows up, and keeps 8 points from the edges.
  static func place(trigger: CGRect, menu: CGSize, align: GlassMenuAlignment, in bounds: CGSize) -> CGRect {
    let lined: CGFloat = switch align {
    case .leading: trigger.minX
    case .center: trigger.midX - menu.width / 2
    case .trailing: trigger.maxX - menu.width
    }
    let x = max(edge, min(lined, bounds.width - edge - menu.width))
    let below = bounds.height - edge - max(trigger.minY, edge)
    let above = min(trigger.maxY, bounds.height - edge) - edge
    let down = menu.height <= below || below >= above
    let height = min(menu.height, max(0, down ? below : above))
    let y = down ? max(trigger.minY, edge) : min(trigger.maxY, bounds.height - edge) - height
    return CGRect(x: x, y: y, width: menu.width, height: height)
  }

  /// As on the Mac a context menu hangs from the pointer, or goes up or left of it where
  /// there isn't room.
  static func place(at point: CGPoint, menu: CGSize, in bounds: CGSize) -> CGRect {
    let height = min(menu.height, bounds.height - 2 * edge)
    var x = point.x
    if x + menu.width > bounds.width - edge { x = point.x - menu.width }
    var y = point.y
    if y + height > bounds.height - edge { y = point.y - height }
    x = max(edge, min(x, bounds.width - edge - menu.width))
    y = max(edge, min(y, bounds.height - edge - height))
    return CGRect(x: x, y: y, width: menu.width, height: height)
  }
}

struct MenuPose {
  var glass: CGRect = .zero
  var corner: CGFloat = 0
  var zoom: CGFloat = 1
  /// Where the rows are zoomed from, in the menu.
  var anchor = UnitPoint.center
  var shift: CGFloat = 0
  var rows: Double = 1
  var soft: CGFloat = 0
  var face: Double = 0
  var opacity: Double = 1
  var showsGlass = true
  var interactive = false
}

struct TriggerPose {
  var hidden = false
  var scaleX: CGFloat = 1
  var lift: CGFloat = 0
  static let rest = TriggerPose()
}

/// How a press is holding the open menu: swollen a little, pulled after the pointer, lit.
struct PressPose {
  var scale: CGFloat = 1
  var offset: CGSize = .zero
  var light: Double = 0
}

/// A row, or one button of a palette row.
struct RowID: Hashable, Comparable {
  var entry: Int
  var cell = -1
  static func < (a: RowID, b: RowID) -> Bool { (a.entry, a.cell) < (b.entry, b.cell) }
}

// MARK: - The presenter

@MainActor @Observable
final class GlassMenuPresenter {
  enum Kind {
    /// Grows out of this button.
    case button(CGRect)
    /// Grows out of the pointer, here.
    case point(CGPoint)
    /// Grows out of the corner of this control, which brings its own look and stays in view:
    /// a row, a form field, a toolbar icon.
    case anchor(CGRect)
  }

  struct Presentation {
    var id: UUID
    var kind: Kind
    var style: LiquidGlassStyle
    var align: GlassMenuAlignment
    /// The button's face, which the menu carries as it grows.
    var face: AnyView?
    var entries: [GlassMenuEntry]
    var reduceMotion: Bool

    var trigger: CGRect {
      switch kind {
      case .button(let rect), .anchor(let rect): rect
      case .point(let point): CGRect(origin: point, size: .zero)
      }
    }

    /// The rows in the order they're shown. A button's menu that opens upward is turned round, as
    /// iOS turns it, so its first row is nearest the button: the groups between dividers go in
    /// reverse, and so do the rows in each, but a heading stays at the top of its group.
    func entries(upward: Bool) -> [GlassMenuEntry] {
      // A context menu reads top to bottom wherever it opens, as iOS's does.
      if case .point = kind { return entries }
      return upward ? Self.turned(entries) : entries
    }

    static func turned(_ entries: [GlassMenuEntry]) -> [GlassMenuEntry] {
      var groups: [[GlassMenuEntry]] = [[]]
      for entry in entries {
        if case .divider = entry { groups.append([]) } else { groups[groups.count - 1].append(entry) }
      }
      let turned = groups.reversed().map { group -> [GlassMenuEntry] in
        if let first = group.first, case .heading = first { return [first] + group.dropFirst().reversed() }
        return group.reversed()
      }
      return Array(turned.filter { !$0.isEmpty }.joined(separator: [GlassMenuEntry.divider]))
    }

    /// The narrowest the menu is: iOS's 250 points, or as wide as the glass button it grows out of.
    var minWidth: CGFloat {
      if case .button(let rect) = kind { return max(250, rect.width) }
      return 250
    }

    /// Whether it morphs out of a button, iOS's way, rather than scaling out of a point.
    var morphs: Bool {
      if reduceMotion { return false }
      if case .button = kind { return true }
      return false
    }
  }

  enum Goal { case open, close }

  private(set) var current: Presentation?
  /// The menu's own size, measured once it's laid out, before it starts to grow.
  private(set) var size: CGSize?
  private(set) var goal = Goal.open
  /// Whether anything is moving, so the clocks that draw it can stop when nothing is.
  private(set) var moving = false
  /// The row the pointer or the keyboard is on.
  var highlighted: RowID?

  /// Where each row is in the host, and what choosing it does.
  @ObservationIgnored var rows: [RowID: (frame: CGRect, item: GlassMenuItem)] = [:]
  /// The size of the host, for placing the menu.
  @ObservationIgnored var bounds = CGSize.zero
  @ObservationIgnored private var start = Date()
  @ObservationIgnored private var startAt = 0.0
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var movingUntil = Date.distantPast
  /// A context menu's scale, from 0 to 1, on iOS's spring.
  @ObservationIgnored private var grow = Settle()
  @ObservationIgnored private var pressing = false
  @ObservationIgnored private var scrubbed = false
  @ObservationIgnored private var swell = Settle(1)
  @ObservationIgnored private var light = Settle()
  @ObservationIgnored private var pull = CGSize.zero
  @ObservationIgnored private var pullX = Settle()
  @ObservationIgnored private var pullY = Settle()

  private func at(_ date: Date) -> Double { startAt + max(0, date.timeIntervalSince(start)) * 60 }

  func moves(_ id: UUID) -> Bool { moving && current?.id == id }

  /// Keeps the clocks running for a while.
  private func animate(for seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    if until > movingUntil { movingUntil = until }
    moving = true
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds + 0.03))
      guard let self, Date() >= self.movingUntil, !self.pressing else { return }
      self.moving = false
    }
  }

  private var openSeconds: Double {
    guard let current else { return 0 }
    if current.reduceMotion { return MenuMotion.fadeFrames / 60 }
    return current.morphs ? (MenuMotion.openFrames - startAt) / 60 : grow.duration
  }

  // MARK: Opening and closing

  func open(_ presentation: Presentation) {
    let now = Date()
    let same = current?.id == presentation.id
    if same, goal == .close, presentation.morphs, at(now) < MenuMotion.closeFrames {
      // Opened again before it had closed: carry on from the shape it's in.
      startAt = MenuMotion.nearest(MenuMotion.opening, height: MenuMotion.row(MenuMotion.closing, at(now)).height)
    } else {
      startAt = 0
    }
    if !same {
      size = nil
      rows = [:]
    }
    grow = (same ? grow : Settle()).retarget(1, stiffness: 443, damping: 24.8, at: now)
    highlighted = nil
    scrubbed = false
    current = presentation
    goal = .open
    start = now
    generation += 1
    animate(for: openSeconds)
  }

  func measured(_ measured: CGSize) {
    guard size == nil else { return }
    size = measured
    start = Date()
    grow = Settle().retarget(1, stiffness: 443, damping: 24.8, at: start)
    animate(for: openSeconds)
  }

  func close() {
    guard let current, goal == .open else { return }
    guard size != nil else {
      self.current = nil
      return
    }
    let now = Date()
    let at = at(now)
    let seconds: Double
    if current.reduceMotion {
      startAt = at < MenuMotion.fadeFrames ? MenuMotion.fadeFrames - at : 0
      seconds = (MenuMotion.fadeFrames - startAt) / 60
    } else if current.morphs {
      startAt = at < MenuMotion.openFrames
        ? MenuMotion.nearest(MenuMotion.closing, height: MenuMotion.row(MenuMotion.opening, at).height) : 0
      seconds = (MenuMotion.closeFrames + MenuMotion.landFrames - startAt) / 60
    } else {
      startAt = 0
      // A context menu goes quickly, on a stiffer spring.
      grow = grow.retarget(0, stiffness: 900, damping: 60, at: now)
      seconds = grow.duration
    }
    goal = .close
    start = now
    pressing = false
    highlighted = nil
    generation += 1
    let generation = generation
    animate(for: seconds)
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds + 0.03))
      guard let self, self.generation == generation else { return }
      self.current = nil
      self.size = nil
      self.rows = [:]
    }
  }

  func choose(_ item: GlassMenuItem) {
    guard !item.isDisabled else { return }
    close()
    item.action()
  }

  func choose(_ id: RowID) {
    if let item = rows[id]?.item { choose(item) }
  }

  // MARK: The pointer

  /// The menu, placed in the host.
  func place() -> CGRect? {
    guard let current, let size else { return nil }
    switch current.kind {
    case .button(let trigger), .anchor(let trigger):
      return MenuPlacement.place(trigger: trigger, menu: size, align: current.align, in: bounds)
    case .point(let point): return MenuPlacement.place(at: point, menu: size, in: bounds)
    }
  }

  private func row(at point: CGPoint) -> RowID? {
    guard let place = place(), place.contains(point) else { return nil }
    return rows.first { $0.value.frame.contains(point) && !$0.value.item.isDisabled }?.key
  }

  func hover(_ point: CGPoint?) {
    guard !pressing, goal == .open else { return }
    highlighted = point.flatMap(row(at:))
  }

  /// A press that began on the button, sliding about. Once it has moved, it lights the row it's
  /// on, and letting go there chooses it.
  func scrub(to point: CGPoint, from origin: CGPoint) {
    guard current != nil, goal == .open else { return }
    if hypot(point.x - origin.x, point.y - origin.y) > 6 { scrubbed = true }
    if scrubbed { highlighted = row(at: point) }
  }

  func scrubEnded(at point: CGPoint) {
    defer { scrubbed = false }
    guard scrubbed, goal == .open, let id = row(at: point) else { return }
    choose(id)
  }

  /// A press on the open menu: the glass swells a little and follows the pointer a few points,
  /// as it does under a finger, and the row under it lights.
  func press(at point: CGPoint, from origin: CGPoint) {
    guard goal == .open, let place = place() else { return }
    let now = Date()
    if !pressing {
      pressing = true
      moving = true
      swell = swell.retarget(1 + 5 / max(place.width, place.height, 200), stiffness: 650, damping: 36, at: now)
      light = light.retarget(1, stiffness: 900, damping: 60, at: now)
    }
    pull = CGSize(width: MenuMotion.resistance(point.x - origin.x), height: MenuMotion.resistance(point.y - origin.y))
    highlighted = row(at: point)
  }

  func pressEnded(at point: CGPoint) {
    guard pressing else { return }
    pressing = false
    let now = Date()
    swell = swell.retarget(1, stiffness: 650, damping: 36, at: now)
    light = light.retarget(0, stiffness: 900, damping: 60, at: now)
    pullX = Settle(from: pull.width, to: 0, stiffness: 600, damping: 30, start: now)
    pullY = Settle(from: pull.height, to: 0, stiffness: 600, damping: 30, start: now)
    pull = .zero
    animate(for: max(swell.duration, pullX.duration, pullY.duration))
    if let id = row(at: point) { choose(id) }
  }

  func pressPose(at date: Date) -> PressPose {
    PressPose(
      scale: swell.value(at: date),
      offset: pressing ? pull : CGSize(width: pullX.value(at: date), height: pullY.value(at: date)),
      light: max(0, light.value(at: date)))
  }

  // MARK: Poses

  func triggerPose(_ id: UUID, at date: Date) -> TriggerPose {
    guard let current, current.id == id, size != nil else { return .rest }
    let at = at(date)
    if !current.morphs {
      return TriggerPose(hidden: false)
    }
    if goal == .open || at < MenuMotion.closeFrames { return TriggerPose(hidden: true) }
    let land = MenuMotion.landingRow(at - MenuMotion.closeFrames)
    return TriggerPose(hidden: false, scaleX: land.scaleX, lift: land.lift)
  }

  /// The glass and its rows at a moment, for a menu placed at `place`.
  func pose(at date: Date, place: CGRect, radius: CGFloat) -> MenuPose {
    guard let current else { return MenuPose(showsGlass: false) }
    func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
    let at = at(date)

    if current.reduceMotion {
      let shown = goal == .open ? clamp(at / MenuMotion.fadeFrames) : clamp(1 - at / MenuMotion.fadeFrames)
      return MenuPose(glass: place, corner: radius, opacity: shown, showsGlass: shown > 0, interactive: goal == .open)
    }

    let grows: CGPoint? = switch current.kind {
    case .point(let point): point
    // Out of the control's corner on the side it's aligned to, at the edge the menu leaves from.
    case .anchor(let rect):
      CGPoint(
        x: current.align == .leading ? rect.minX : current.align == .trailing ? rect.maxX : rect.midX,
        y: place.midY >= rect.midY ? rect.minY : rect.maxY)
    case .button: nil
    }
    if let point = grows {
      // Out of the pointer, as a context menu grows on iOS: from a third its size, on a spring.
      let v = grow.value(at: date)
      let s = 0.3 + 0.7 * max(0, v)
      let shown = min(1, clamp(v) * 3)
      let anchor = CGPoint(x: min(max(point.x, place.minX), place.maxX), y: min(max(point.y, place.minY), place.maxY))
      let glass = CGRect(
        x: anchor.x + (place.minX - anchor.x) * s, y: anchor.y + (place.minY - anchor.y) * s,
        width: place.width * s, height: place.height * s)
      return MenuPose(
        glass: glass, corner: radius * s, zoom: s,
        anchor: UnitPoint(x: (anchor.x - place.minX) / place.width, y: (anchor.y - place.minY) / max(place.height, 1)),
        opacity: shown, showsGlass: shown > 0.001, interactive: goal == .open)
    }

    let from = current.trigger
    let row: MenuMotion.Row
    var pose = MenuPose()
    if goal == .open {
      if at >= MenuMotion.openFrames {
        return MenuPose(glass: place, corner: radius, showsGlass: true, interactive: true)
      }
      row = MenuMotion.row(MenuMotion.opening, at)
      pose.rows = clamp((at - 1) / 6)
      pose.soft = 5 * clamp(1 - (at - 2) / 14)
      pose.face = clamp(1 - at / 2.5)
      // A press can choose a row before the menu has quite settled.
      pose.interactive = at > 8
    } else {
      guard at < MenuMotion.closeFrames else { return MenuPose(showsGlass: false) }
      row = MenuMotion.row(MenuMotion.closing, at)
      pose.rows = clamp(1 - at / 4)
      pose.soft = 4 * clamp(at / 4)
      pose.face = clamp((at - 5) / 3)
    }
    // The sizes were measured for a 192 x 52 button and a 250 x 167 menu. Past either end of the
    // range they're kept as a share of the size they run from.
    let w = row.width, h = row.height
    let width = max(from.height * 0.8, w < 0 ? from.width * (1 + 0.302 * w)
      : w > 1 ? place.width * (1 + 0.232 * (w - 1)) : from.width + (place.width - from.width) * w)
    let height = h > 1 ? place.height * (1 + 0.69 * (h - 1)) : from.height + (place.height - from.height) * h
    let x = from.midX + (place.midX - from.midX) * clamp(w) - width / 2
    let cy = from.midY + (place.midY - from.midY) * row.centre
    let roundest = min(1, radius / (min(place.width, place.height) / 2))
    pose.glass = CGRect(x: x, y: cy - height / 2, width: width, height: height)
    pose.corner = (roundest + (1 - roundest) * row.round) * min(width, height) / 2
    pose.zoom = row.zoom
    // The rows ride lower than the glass, and swell as they go through its middle.
    pose.shift = (cy - place.midY) * 0.45
    return pose
  }
}
#endif
