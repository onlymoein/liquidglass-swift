import CoreGraphics
import Testing
@testable import LiquidGlass

@Suite struct ContourTests {
  @Test func straightEdgesMeasureFromTheNearestSide() {
    let e = Contour.edge(CGPoint(x: 0, y: -40), half: CGSize(width: 100, height: 50), radius: 20)
    #expect(abs(e.d - 10) < 1e-9)
    #expect(e.nx == 0 && e.ny == -1)
  }

  @Test func theRimIsAtDistanceZero() {
    let half = CGSize(width: 100, height: 60)
    let path = Contour.path(in: CGRect(x: -100, y: -60, width: 200, height: 120), radius: 34)
    // Points on the path sit on the rim, corners included.
    var worst = 0.0
    path.applyWithBlock { el in
      guard el.pointee.type == .addLineToPoint else { return }
      let p = el.pointee.points[0]
      worst = max(worst, abs(Contour.edge(p, half: half, radius: 34).d))
    }
    #expect(worst < 0.05)
  }

  @Test func aCapsuleStaysCircular() {
    let half = CGSize(width: 70, height: 22)
    let e = Contour.edge(CGPoint(x: 70 - 22 + 22 * cos(0.7), y: 22 * sin(0.7)), half: half, radius: 22)
    #expect(abs(e.d) < 1e-9)
  }
}

@Suite struct OpticsTests {
  /// The matrix has to agree with CSS's contrast, brightness and saturate run one after another.
  @Test func theMatrixMatchesTheCSSFilters() {
    let tone = Optics.Tone(contrast: 0.307, brightness: 1.554, saturation: 2.081)
    let m = Optics.matrix(tone)
    let rgb = [0.8, 0.3, 0.1]
    var css = rgb.map { (($0 - 0.5) * tone.contrast + 0.5) * tone.brightness }
    let grey = zip(css, Optics.luma).map(*).reduce(0, +)
    css = css.map { grey + ($0 - grey) * tone.saturation }
    for row in 0..<3 {
      let ours = zip(m.rows[row], rgb).map(*).reduce(0, +) + m.bias
      #expect(abs(ours - css[row]) < 1e-9)
    }
  }

  /// liquidglass's light panel over mid grey reads 196 to 198; iOS reads 197.
  @Test func aLightPanelOverGreyReadsAsIOSDoes() {
    let m = Optics.matrix(Optics.tone(short: 120, dark: false, clear: false))
    let v = 128.0 / 255
    let out = m.rows[0].reduce(0, +) * v + m.bias
    #expect(abs(out * 255 - 197) < 2)
  }

  /// Dark glass 120 points or taller reads 32 over black and 121 over white on iOS, and peaks over light grey.
  @Test func darkGlassFollowsIOSsCurve() {
    let level = { (v: Double) in Optics.dark([v, v, v], size: 1)[0] * 255 }
    #expect(abs(level(0) - 32) < 0.5)
    #expect(abs(level(1) - 121) < 0.5)
    #expect(level(0.75) > level(1))
  }

  @Test func aSpringSettlesOnItsTarget() {
    var s = Spring(value: 0, target: 1, velocity: 0, stiffness: 417.6, damping: 29.2)
    for _ in 0..<120 { s.advance(1.0 / 60) }
    #expect(s.value == 1)
  }
}

#if os(macOS)
import Foundation

@Suite struct MenuTests {
  let window = CGSize(width: 1000, height: 700)

  @Test func aMenuCoversItsButtonAndGrowsDown() {
    let button = CGRect(x: 400, y: 20, width: 150, height: 44)
    let place = MenuPlacement.place(trigger: button, menu: CGSize(width: 250, height: 188), align: .center, in: window)
    #expect(place.minY == button.minY)
    #expect(place.midX == button.midX)
  }

  @Test func withoutRoomBelowItGrowsUpFromTheButtonsBottom() {
    let button = CGRect(x: 400, y: 640, width: 150, height: 44)
    let place = MenuPlacement.place(trigger: button, menu: CGSize(width: 250, height: 188), align: .center, in: window)
    #expect(place.maxY == button.maxY)
  }

  @Test func aMenuKeepsItsDistanceFromTheEdges() {
    let button = CGRect(x: 960, y: 20, width: 36, height: 36)
    let place = MenuPlacement.place(trigger: button, menu: CGSize(width: 250, height: 188), align: .leading, in: window)
    #expect(place.maxX == window.width - MenuPlacement.edge)
  }

  @Test func aTallMenuIsCutToTheRoomThereIs() {
    let button = CGRect(x: 400, y: 640, width: 150, height: 44)
    let place = MenuPlacement.place(trigger: button, menu: CGSize(width: 250, height: 900), align: .center, in: window)
    #expect(place.minY == MenuPlacement.edge)
    #expect(place.height < 900)
  }

  @Test func aContextMenuGoesUpAndLeftWhereItMust() {
    let place = MenuPlacement.place(at: CGPoint(x: 900, y: 650), menu: CGSize(width: 250, height: 200), in: window)
    #expect(place.maxX == 900 && place.maxY == 650)
  }

  @Test func aPressPullsTheMenuSevenPointsAtMost() {
    #expect(abs(MenuMotion.resistance(10000) - 7) < 1e-6)
    #expect(MenuMotion.resistance(-30) < 0)
    #expect(MenuMotion.resistance(5) < 5)
  }

  @Test func aSettleRestsWhereItsGoing() {
    let start = Date()
    let s = Settle(from: 0, to: 1, stiffness: 443, damping: 24.8, start: start)
    #expect(s.value(at: start.addingTimeInterval(s.duration)) == 1)
    #expect(s.value(at: .distantFuture) == 1)
    #expect(s.duration > 0.2 && s.duration < 1)
  }

  @Test func theMorphEndsOnTheMenuAndTheButton() {
    #expect(MenuMotion.opening.last! == (1, 1, 1, 1, 0))
    #expect(MenuMotion.landing.last! == (1, 0))
  }

  @MainActor @Test func aMenuOutOfAPlainControlIsIOSsWidthNotTheControls() {
    let row = CGRect(x: 0, y: 100, width: 600, height: 50)
    let plain = GlassMenuPresenter.Presentation(
      id: UUID(), kind: .anchor(row), style: .regular, align: .trailing, face: nil, entries: [], reduceMotion: false)
    let glass = GlassMenuPresenter.Presentation(
      id: UUID(), kind: .button(row), style: .regular, align: .trailing, face: nil, entries: [], reduceMotion: false)
    #expect(plain.minWidth == 250)
    #expect(glass.minWidth == 600)
    // It doesn't morph: the control stays where it is, and the menu grows out of it.
    #expect(!plain.morphs)
    #expect(glass.morphs)
  }

  @MainActor @Test func aMenuOutOfAPlainControlOpensWhereAButtonsWould() {
    let presenter = GlassMenuPresenter()
    presenter.bounds = CGSize(width: 800, height: 600)
    let row = CGRect(x: 100, y: 100, width: 400, height: 50)
    presenter.open(.init(id: UUID(), kind: .anchor(row), style: .regular, align: .trailing, face: nil, entries: [], reduceMotion: false))
    presenter.measured(CGSize(width: 250, height: 200))
    let place = presenter.place()
    #expect(place == MenuPlacement.place(trigger: row, menu: CGSize(width: 250, height: 200), align: .trailing, in: presenter.bounds))
    #expect(place?.maxX == row.maxX)
  }

  @MainActor @Test func aMenuThatOpensUpwardIsTurnedRoundAsIOSTurnsIt() {
    func titles(_ entries: [GlassMenuEntry]) -> [String] {
      entries.map {
        switch $0 {
        case .item(let item): item.title
        case .heading(let title): "#" + title
        case .divider: "-"
        case .palette(let items): "[" + items.map(\.title).joined(separator: ",") + "]"
        }
      }
    }
    let entries: [GlassMenuEntry] = [
      .palette([GlassMenuItem("Me") {}, GlassMenuItem("Bell") {}]), .divider,
      .heading("Sections"), .item(GlassMenuItem("Home") {}), .item(GlassMenuItem("Jobs") {}),
    ]
    let up = GlassMenuPresenter.Presentation(
      id: UUID(), kind: .button(.zero), style: .regular, align: .leading, face: nil, entries: entries, reduceMotion: false)
    #expect(titles(up.entries(upward: true)) == ["#Sections", "Jobs", "Home", "-", "[Me,Bell]"])
    #expect(titles(up.entries(upward: false)) == ["[Me,Bell]", "-", "#Sections", "Home", "Jobs"])
    let context = GlassMenuPresenter.Presentation(
      id: UUID(), kind: .point(.zero), style: .regular, align: .leading, face: nil, entries: entries, reduceMotion: false)
    #expect(titles(context.entries(upward: true)) == titles(entries))
  }
}
#endif
