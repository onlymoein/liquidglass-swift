import AppKit
import LiquidGlass
import SwiftUI

// The demo: iOS 27 glass on the Mac over a real scroll view, next to Apple's own macOS glass.
//
//   swift run LiquidGlassDemo
//
// Arguments, for checking it without a person at the screen:
//   -scene feed|grey      what's behind the glass (grey: flat black, grey and white, for reading tone)
//   -renderer ours|apple  whose glass
//   -variant regular|clear
//   -appearance light|dark
//   -capture /path.png    photograph the window after it settles, then quit
//   -pane x,y             start the pane that far from the middle
//   -animate 1            circle the pane, to watch the glass keep up
//   -open more|sort|add|layout   click that menu's button once the window is up
//   -then "x,y@s;..."     then click there (top-left, in points) that long after the menu's click;
//                         "rx,y@s" right-clicks, "dx,y>x,y@s" presses, drags and lets go
//   -openCapture s[,s...] photograph that long after the menu's click, instead of after 2.5s
//   -captureDelay s       photograph that long after launch
//   -dumpLayers 1         print the layer tree when photographing
//   -stress s,r           instead of the demo, s sections of r rows with two pieces of glass each,
//                         all but one section kept alive at opacity 0, as an app keeps its tabs
//   -stressScroll 1       and scroll the showing one up and down without end
//   -stressScrollFor s    or for that long, then stop

@main
struct DemoApp: App {
  @NSApplicationDelegateAdaptor(Delegate.self) private var delegate

  var body: some Scene {
    WindowGroup("liquidglass for macOS") {
      if let stress = UserDefaults.standard.string(forKey: "stress") {
        StressView(spec: stress).frame(minWidth: 600, minHeight: 680)
      } else {
        DemoView()
          .frame(minWidth: 960, minHeight: 680)
      }
    }
    .defaultSize(width: 1000, height: 720)
  }
}

final class Delegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if let path = UserDefaults.standard.string(forKey: "capture"), UserDefaults.standard.string(forKey: "openCapture") == nil {
      let delay = UserDefaults.standard.double(forKey: "captureDelay")
      DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 2.5)) { Capture.window(to: path) }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

enum Renderer: String, CaseIterable, Identifiable {
  case ours, apple
  var id: Self { self }
  var label: String { self == .ours ? "liquidglass (iOS)" : "Apple (macOS)" }
}

enum Sort: String, CaseIterable, Identifiable {
  case newest, oldest, name, size
  var id: Self { self }
  var title: String {
    switch self {
    case .newest: "Newest First"
    case .oldest: "Oldest First"
    case .name: "Name"
    case .size: "Size"
    }
  }
}

enum Layout: String, CaseIterable, Identifiable {
  case grid, list, gallery
  var id: Self { self }
  var title: String { rawValue.capitalized }
  var symbol: String {
    switch self {
    case .grid: "square.grid.2x2"
    case .list: "list.bullet"
    case .gallery: "rectangle.stack"
    }
  }
}

extension View {
  /// For photographing a menu: clicks this view's button when asked to.
  @ViewBuilder
  func opensOn(_ flag: Bool) -> some View {
    background(ClickWhen(flag: flag))
  }
}

/// Clicks the button it's behind once `flag` turns on, as a person would.
struct ClickWhen: NSViewRepresentable {
  var flag: Bool
  final class Coordinator { var fired = false }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    // Once: SwiftUI updates the view again whenever anything around it changes.
    guard flag, !context.coordinator.fired, let window = view.window else { return }
    context.coordinator.fired = true
    let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    // In front first: a window behind another app's takes its first click to come forward.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        {
          window.sendEvent(event)
        }
      }
      // -then "x,y@s;..." clicks there, in the photograph's top-left points, that long after.
      for step in (UserDefaults.standard.string(forKey: "then") ?? "").split(separator: ";") {
        Script.run(String(step), in: window)
      }
      // Several times, comma-separated, photograph a series: path-0.png, path-1.png...
      let times = (UserDefaults.standard.string(forKey: "openCapture") ?? "").split(separator: ",").compactMap { Double($0) }
      if !times.isEmpty, let path = UserDefaults.standard.string(forKey: "capture") {
        for (i, t) in times.enumerated() {
          DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            let last = i == times.count - 1
            Capture.window(to: times.count == 1 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png"), exit: last)
          }
        }
      }
    }
  }
}

/// Clicks, right-clicks and drags for -then, posted to the app's queue as a person's would be.
@MainActor
enum Script {
  /// "x,y@s" clicks, "rx,y@s" right-clicks, "dx,y>x,y@s" presses, drags and lets go.
  static func run(_ step: String, in window: NSWindow) {
    let parts = step.split(separator: "@")
    guard parts.count == 2, let at = Double(parts[1]) else { return }
    var spec = Substring(parts[0])
    let kind = spec.first == "r" || spec.first == "d" || spec.first == "h" ? spec.removeFirst() : "c"
    let points = spec.split(separator: ">").map { pair -> CGPoint in
      let v = pair.split(separator: ",").compactMap { Double($0) }
      return CGPoint(x: v.first ?? 0, y: window.frame.height - (v.last ?? 0))
    }
    guard let first = points.first else { return }
    func post(_ type: NSEvent.EventType, _ p: CGPoint, after: Double) {
      DispatchQueue.main.asyncAfter(deadline: .now() + at + after) {
        guard let event = NSEvent.mouseEvent(
          with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        NSApp.postEvent(event, atStart: false)
      }
    }
    switch kind {
    case "r":
      post(.rightMouseDown, first, after: 0)
      post(.rightMouseUp, first, after: 0.05)
    case "d", "h":
      // "h" holds on for two seconds before letting go.
      let last = points.last ?? first
      let up = kind == "h" ? 2.5 : 0.8
      post(.leftMouseDown, first, after: 0)
      for i in 1...12 {
        let t = Double(i) / 12
        post(.leftMouseDragged, CGPoint(x: first.x + (last.x - first.x) * t, y: first.y + (last.y - first.y) * t), after: 0.45 + t * 0.25)
      }
      post(.leftMouseUp, last, after: up)
    default:
      post(.leftMouseDown, first, after: 0)
      post(.leftMouseUp, first, after: 0.05)
    }
  }
}

enum Appearance: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: Self { self }
  var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

struct DemoView: View {
  @State private var renderer = Renderer(rawValue: UserDefaults.standard.string(forKey: "renderer") ?? "") ?? .ours
  @State private var clear = UserDefaults.standard.string(forKey: "variant") == "clear"
  @State private var appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
  @State private var tinted = false
  @State private var offset: CGSize = {
    // -pane x,y starts the pane that far from the middle.
    let v = (UserDefaults.standard.string(forKey: "pane") ?? "0,0").split(separator: ",").compactMap { Double($0) }
    return v.count == 2 ? CGSize(width: v[0], height: v[1]) : .zero
  }()
  @State private var dragStart: CGSize?
  @State private var sort = Sort.newest
  @State private var layout = Layout.grid
  @State private var favourite = false
  @State private var said = "Pick something from a menu"
  @State private var openRequest: String?
  @State private var font = "New York"
  static let fonts = [
    "SF Pro", "New York", "Helvetica", "Avenir", "Futura", "Georgia", "Gill Sans", "Menlo", "Optima", "Palatino",
    "Rockwell", "Didot", "Baskerville", "Charter", "Courier", "Times",
  ]
  private let scene = UserDefaults.standard.string(forKey: "scene") ?? "feed"

  private var style: LiquidGlassStyle { clear ? .clear : .regular }

  var body: some View {
    ZStack {
      if scene == "grey" { GreyScene(renderer: renderer, style: style) } else { Feed { said = $0 } }

      if scene != "grey" {
        VStack(spacing: 0) {
          toolbar.padding(.top, 18)
          Spacer()
          // What the last menu did.
          Text(said).font(.system(size: 13, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 32)
            .demoGlass(renderer, style, in: .capsule)
            .padding(.bottom, 10)
          controls.padding(.bottom, 22)
        }
        .padding(.horizontal, 24)

        pane
          .offset(offset)
          .gesture(
            DragGesture()
              .onChanged { g in
                let start = dragStart ?? offset
                dragStart = start
                offset = CGSize(width: start.width + g.translation.width, height: start.height + g.translation.height)
              }
              .onEnded { _ in dragStart = nil })
      }
    }
    // Apple's side shows the Mac's own menus, for comparing.
    .glassMenuHost(renderer == .ours)
    .preferredColorScheme(appearance.scheme)
    .task {
      // -open menu|more|add|sort opens that menu, for photographing it.
      if let which = UserDefaults.standard.string(forKey: "open") {
        try? await Task.sleep(for: .milliseconds(900))
        openRequest = which
      } else if let steps = UserDefaults.standard.string(forKey: "then"), let window = NSApp.windows.first(where: { $0.isVisible }) {
        // Without -open, -then runs from launch.
        try? await Task.sleep(for: .milliseconds(900))
        for step in steps.split(separator: ";") { Script.run(String(step), in: window) }
      }
      // -animate 1 circles the pane, for checking the glass keeps up as it moves.
      guard UserDefaults.standard.bool(forKey: "animate") else { return }
      let start = Date()
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(8))
        let t = Date().timeIntervalSince(start)
        offset = CGSize(width: cos(t * 1.5) * 260, height: sin(t * 1.5) * 170)
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      HStack(spacing: 4) {
        ForEach(["chevron.left", "square.and.arrow.up", favourite ? "heart.fill" : "heart"], id: \.self) { name in
          Button {} label: {
            Image(systemName: name).font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 4)
      .demoGlass(renderer, style, in: .capsule)

      // A button with several things it can do.
      GlassMenu(style: style, in: .circle, align: .leading) {
        GlassMenuPalette {
          GlassMenuItem("Copy", systemImage: "doc.on.doc") { said = "Copy" }
          GlassMenuItem("Share", systemImage: "square.and.arrow.up") { said = "Share" }
          GlassMenuItem(favourite ? "Unfavourite" : "Favourite", systemImage: favourite ? "heart.slash" : "heart") {
            favourite.toggle()
            said = favourite ? "Favourite" : "Unfavourite"
          }
        }
        GlassMenuDivider()
        GlassMenuItem("Duplicate", systemImage: "plus.square.on.square") { said = "Duplicate" }
        GlassMenuItem("Rename", systemImage: "pencil") { said = "Rename" }
        GlassMenuItem("Print", systemImage: "printer", isDisabled: true) {}
        GlassMenuDivider()
        GlassMenuItem("Delete", systemImage: "trash", role: .destructive) { said = "Delete" }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
      }
      .opensOn(openRequest == "more")

      Spacer()

      // A button to choose with: it shows what's chosen.
      GlassPicker(selection: $sort, options: Sort.allCases, style: style, title: \.title)
        .opensOn(openRequest == "sort")

      Spacer()

      GlassMenu(style: style, in: .circle, align: .trailing) {
        GlassMenuHeading("New")
        GlassMenuItem("Note", systemImage: "note.text") { said = "New note" }
        GlassMenuItem("Folder", systemImage: "folder") { said = "New folder" }
        GlassMenuItem("Photo", systemImage: "photo") { said = "New photo" }
        GlassMenuDivider()
        GlassMenuHeading("Show as")
        for option in Layout.allCases {
          GlassMenuItem(option.title, systemImage: option.symbol, isChecked: layout == option) {
            layout = option
            said = "Show as \(option.title)"
          }
        }
      } label: {
        Image(systemName: "plus").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44)
      }
      .opensOn(openRequest == "add")
    }
  }

  private var pane: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Drag me", systemImage: "hand.draw").font(.system(size: 22, weight: .bold))
      Text("A pane of glass 300 × 170 points. Its rim bends what's under it, and the bend follows it as it moves.")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(22)
    .frame(width: 300, height: 170, alignment: .topLeading)
    .demoGlass(renderer, style, in: .rect(cornerRadius: 34))
  }

  private var controls: some View {
    VStack(spacing: 14) {
      HStack(spacing: 18) {
        Picker("Glass", selection: $renderer) {
          ForEach(Renderer.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
        Picker("Variant", selection: $clear) {
          Text("Regular").tag(false)
          Text("Clear").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 160)
        Picker("Appearance", selection: $appearance) {
          ForEach(Appearance.allCases) { Text($0.rawValue.capitalized).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
      }
      .labelsHidden()

      HStack(spacing: 12) {
        Toggle("Tint", isOn: $tinted).toggleStyle(.switch)
        GlassPicker("Show as", selection: $layout, options: Layout.allCases, style: style, title: \.title, systemImage: \.symbol)
          .opensOn(openRequest == "layout")
        GlassPicker("Font", selection: $font, options: Self.fonts, style: style, title: { $0 })
          .opensOn(openRequest == "font")
        Spacer()
        demoButton("Cancel", tint: nil)
        demoButton("Done", tint: tinted ? .blue : nil)
        demoButton("Delete", tint: tinted ? .red : nil)
      }
    }
    .padding(18)
    .frame(width: 720)
    .demoGlass(renderer, style, in: .rect(cornerRadius: 30))
  }

  private func demoButton(_ title: String, tint: Color?) -> some View {
    Button {} label: {
      Text(title).font(.system(size: 15, weight: .medium))
        .foregroundStyle(tint == nil ? Color.primary : Color.white)
        .padding(.horizontal, 18).frame(height: 36)
    }
    .buttonStyle(.plain)
    .demoGlass(renderer, style.tint(tint).interactive(), in: .capsule)
  }
}

extension View {
  /// Our glass, or Apple's macOS glass with the same settings, for comparing them.
  @ViewBuilder
  func demoGlass(_ renderer: Renderer, _ style: LiquidGlassStyle, in shape: GlassShape) -> some View {
    if renderer == .ours {
      liquidGlass(style, in: shape)
    } else if #available(macOS 26, *) {
      glassEffect(appleGlass(style), in: appleShape(shape))
    } else {
      background(.ultraThinMaterial, in: appleShape(shape))
    }
  }
}

@available(macOS 26, *)
private func appleGlass(_ style: LiquidGlassStyle) -> Glass {
  var glass: Glass = style.variant == .clear ? .clear : .regular
  if let tint = style.tint { glass = glass.tint(tint) }
  if style.isInteractive { glass = glass.interactive() }
  return glass
}

private func appleShape(_ shape: GlassShape) -> AnyShape {
  switch shape {
  case .capsule: AnyShape(Capsule())
  case .circle: AnyShape(Circle())
  case .rect(let r): AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
  }
}

/// A long, busy page in a real ScrollView: hard edges and text show the bend, colour shows the tone.
struct Feed: View {
  var did: (String) -> Void = { _ in }
  private let tiles: [(String, Color, Color)] = [
    ("sun.max.fill", .orange, .pink), ("leaf.fill", .green, .teal), ("drop.fill", .blue, .cyan),
    ("flame.fill", .red, .orange), ("moon.stars.fill", .indigo, .purple), ("bolt.fill", .yellow, .orange),
    ("snowflake", .cyan, .blue), ("heart.fill", .pink, .red), ("star.fill", .purple, .pink),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        ZStack(alignment: .bottomLeading) {
          LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
          VStack(alignment: .leading, spacing: 6) {
            Text("Liquid Glass").font(.system(size: 64, weight: .heavy))
            Text("as iOS 27 draws it, on the Mac").font(.system(size: 24, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(32)
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

        Stripes().frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
          ForEach(0..<18, id: \.self) { i in
            let t = tiles[i % tiles.count]
            ZStack {
              LinearGradient(colors: [t.1, t.2], startPoint: .top, endPoint: .bottom)
              VStack(spacing: 8) {
                Image(systemName: t.0).font(.system(size: 44, weight: .bold))
                Text("Tile \(i + 1)").font(.system(size: 18, weight: .bold))
              }
              .foregroundStyle(.white)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // Right-click a tile.
            .glassContextMenu {
              GlassMenuPalette {
                GlassMenuItem("Copy", systemImage: "doc.on.doc") { did("Copied tile \(i + 1)") }
                GlassMenuItem("Share", systemImage: "square.and.arrow.up") { did("Shared tile \(i + 1)") }
                GlassMenuItem("Pin", systemImage: "pin") { did("Pinned tile \(i + 1)") }
              }
              GlassMenuDivider()
              GlassMenuItem("Open", systemImage: "arrow.up.forward.app") { did("Opened tile \(i + 1)") }
              GlassMenuItem("Rename", systemImage: "pencil") { did("Renamed tile \(i + 1)") }
              GlassMenuItem("Get Info", systemImage: "info.circle") { did("Info for tile \(i + 1)") }
              GlassMenuDivider()
              GlassMenuItem("Delete", systemImage: "trash", role: .destructive) { did("Deleted tile \(i + 1)") }
            }
          }
        }

        ForEach(0..<6, id: \.self) { i in
          VStack(alignment: .leading, spacing: 8) {
            Text("Paragraph \(i + 1)").font(.system(size: 22, weight: .bold))
            Text(String(repeating: "Glass bends the light behind it at the rim, lifts and saturates what it frosts, and catches a line of light along the edges that face it. ", count: 3))
              .font(.system(size: 16))
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
      }
      .padding(.horizontal, 28)
      .padding(.top, 90)
      .padding(.bottom, 200)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

struct Stripes: View {
  var body: some View {
    Canvas { ctx, size in
      let colors: [Color] = [.black, .white, .red, .white, .blue, .white]
      var x: CGFloat = 0
      var i = 0
      while x < size.width {
        ctx.fill(Path(CGRect(x: x, y: 0, width: 14, height: size.height)), with: .color(colors[i % colors.count]))
        x += 14; i += 1
      }
    }
  }
}

/// Flat black, mid grey and white, each with a panel and a button, for reading the tone.
struct GreyScene: View {
  let renderer: Renderer
  let style: LiquidGlassStyle

  var body: some View {
    HStack(spacing: 0) {
      ForEach([0.0, 128.0 / 255, 1.0], id: \.self) { v in
        ZStack {
          Color(.sRGB, white: v, opacity: 1)
          VStack(spacing: 40) {
            Color.clear.frame(width: 220, height: 160).demoGlass(renderer, style, in: .rect(cornerRadius: 34))
            Color.clear.frame(width: 140, height: 44).demoGlass(renderer, style, in: .capsule)
          }
        }
      }
    }
  }
}

/// The window photographs itself. A process may always capture its own windows, so this needs
/// no Screen Recording permission. `CGWindowListCreateImage` is unavailable to Swift in current
/// SDKs but still present, and is the only call that captures what the window server composited,
/// backdrop filters included, without asking.
enum Capture {
  /// Prints the layer tree, marking the glass's layers, for finding where they've landed.
  @MainActor
  static func dump(_ layer: CALayer, _ depth: Int) {
    let subs = layer.sublayers ?? []
    let glass = subs.filter { $0.name == "liquidglass" }.count
    let name = String(describing: type(of: layer)) + (layer.delegate.map { " <\(type(of: $0))>" } ?? "")
    print(String(repeating: "  ", count: depth) + name + " \(Int(layer.frame.minX)),\(Int(layer.frame.minY)) \(Int(layer.frame.width))x\(Int(layer.frame.height))" + (glass > 0 ? "  [\(glass) glass]" : "") + (layer.mask != nil ? " mask" : "") + (layer.opacity < 1 ? " a=\(layer.opacity)" : ""))
    for s in subs where s.name != "liquidglass" && depth < 14 { dump(s, depth + 1) }
    // Every piece of glass should sit exactly where the wrapper just above it is.
    for (i, s) in subs.enumerated() where s.name != "liquidglass" && i > 0 && subs[i - 1].name == "liquidglass" {
      let glass = subs[i - 1]
      if glass.frame.integral != s.frame.integral {
        print("MISPLACED glass \(glass.frame) under \(s.frame)")
      } else {
        placedRight += 1
      }
    }
    if glass > 0 {
      // The order, one letter a layer: g glass, W a glass's wrapper, . anything else.
      print("ORDER " + subs.map { $0.name == "liquidglass" ? "g" : String(describing: $0.delegate.map { type(of: $0) }).contains("MacGlass") ? "W" : "." }.joined())
    }
    if depth == 0 { print("glass in place: \(placedRight)") }
  }

  @MainActor static var placedRight = 0

  private static let queue = DispatchQueue(label: "capture", qos: .userInteractive)

  @MainActor
  static func window(to path: String, exit quit: Bool = true) {
    guard let window = NSApp.windows.first(where: { $0.isVisible }) else { exit(2) }
    if UserDefaults.standard.bool(forKey: "dumpLayers"), let root = window.contentView?.layer { dump(root, 0) }
    let number = UInt32(window.windowNumber)
    // Off the main thread, so the window keeps drawing while it's photographed.
    queue.async {
      typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
      let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
      guard let symbol = dlsym(handle, "CGWindowListCreateImage") else { exit(3) }
      let create = unsafeBitCast(symbol, to: Fn.self)
      // Just this window, without its frame.
      guard let image = create(.null, 8, number, 1)?.takeRetainedValue() else { exit(4) }
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      try? data?.write(to: URL(fileURLWithPath: path))
      print("captured \(image.width)x\(image.height) \(path) at \(ProcessInfo.processInfo.systemUptime)")
      if quit { exit(0) }
    }
  }
}

/// Many pieces of glass at once, as an app with glass on every screen has: `sections` scroll
/// views of `rows` rows, a capsule and a circle on each, every section but the first kept alive
/// at opacity 0, the way an app keeps the tabs it has been to.
struct StressView: View {
  let sections: Int
  let rows: Int
  @State private var offset: CGFloat = 0

  init(spec: String) {
    let n = spec.split(separator: ",").compactMap { Int($0) }
    sections = n.first ?? 4
    rows = n.count > 1 ? n[1] : 40
  }

  var body: some View {
    ZStack {
      ForEach(0..<sections, id: \.self) { s in
        ScrollViewReader { _ in
          ScrollView {
            LazyVStack(spacing: 10) {
              ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 12) {
                  Text("Section \(s + 1), row \(r + 1)")
                    .padding(.horizontal, 18).frame(height: 40)
                    .liquidGlass(.regular, in: .capsule)
                  Spacer()
                  Image(systemName: "heart").frame(width: 40, height: 40)
                    .liquidGlass(.regular.interactive(), in: .circle)
                }
                .padding(.horizontal, 16).frame(height: 64)
                .background(Color(hue: Double(r % 12) / 12, saturation: 0.6, brightness: 0.9))
              }
            }
          }
          .modifier(ScrolledIfAble(y: s == 0 ? offset : nil))
        }
        .opacity(s == 0 ? 1 : 0)
        .allowsHitTesting(s == 0)
      }
    }
    .task {
      // -stressScroll: the showing section scrolls up and down without end, 12 points a frame.
      guard UserDefaults.standard.bool(forKey: "stressScroll") else { return }
      try? await Task.sleep(for: .seconds(1))
      var step: CGFloat = 12
      let until = UserDefaults.standard.double(forKey: "stressScrollFor")
      let start = Date()
      while !Task.isCancelled, until == 0 || Date().timeIntervalSince(start) < until {
        offset += step
        if offset >= 1440 || offset <= 0 { step = -step }
        try? await Task.sleep(for: .milliseconds(16))
      }
    }
  }
}

/// Scrolls to `y` through SwiftUI's own scroll position, where the system has one.
private struct ScrolledIfAble: ViewModifier {
  let y: CGFloat?
  func body(content: Content) -> some View {
    if #available(macOS 15, *) { content.modifier(Scrolled(y: y)) } else { content }
  }
}

@available(macOS 15, *)
private struct Scrolled: ViewModifier {
  let y: CGFloat?
  @State private var position = ScrollPosition(edge: .top)

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onChange(of: y) { _, y in if let y { position.scrollTo(y: y) } }
  }
}
