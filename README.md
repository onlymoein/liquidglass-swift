# LiquidGlass for Swift

iOS 27's Liquid Glass for SwiftUI, on iOS and on the Mac. On iOS it is Apple's own glass. The Mac's own glass is tuned differently, flatter and greyer, so on the Mac this package draws the glass as iOS draws it, with the optics [liquidglass](https://github.com/onlymoein/liquidglass) measured on the iPhone simulator.

```swift
import LiquidGlass

Text("Done")
  .padding(.horizontal, 18).frame(height: 36)
  .liquidGlass(.regular.tint(.blue).interactive(), in: .capsule)
```

`LiquidGlassStyle` mirrors SwiftUI's `Glass`: `.regular` or `.clear`, `.tint(_:)` and `.interactive()`. Shapes are `.capsule`, `.circle` and `.rect(cornerRadius:)`, with iOS's continuous corners.

macOS 14 or later, iOS 17 or later. On iOS 26 and later it is `glassEffect`; before that, a material.

## Install

In Xcode, choose File → Add Package Dependencies and paste `https://github.com/onlymoein/liquidglass-swift`. In a `Package.swift`:

```swift
.package(url: "https://github.com/onlymoein/liquidglass-swift", from: "0.1.0"),
```

and add `.product(name: "LiquidGlass", package: "liquidglass-swift")` to your target.

## On the Mac

The glass bends, frosts, lifts and saturates whatever the window draws behind it, scroll views included, and draws iOS's rim and shadow. It uses only public API.

| Light glass, 120 pt | over black | over grey | over white |
| --- | --- | --- | --- |
| This package | 137 | 198 | 255 |
| iOS 27 | 135 | 197 | 254 |
| macOS 27's own glass | 102 | 171 | 236 |

Dark glass follows iOS's measured curve too: 32 over black and 121 over white at panel size.

How it works, and its limits:

- The window server runs Core Image's built-in filters on a layer's backdrop. It ignores custom Metal kernels and displacement maps, so the bend at the rim is built from rings, each magnified a little more toward the middle, as iOS's falls in a straight line across the bezel. Regular glass has up to 6 rings and clear glass up to 16.
- A layer's backdrop filters only see what its own parent drew beneath it. SwiftUI wraps hosted AppKit views in a container that has nothing beneath, so the glass's layers are placed beside that container and follow it each frame. Glass therefore sees what SwiftUI draws behind it within the same container: content in the same `ZStack`, a scroll view under a toolbar, cards in a scroll view. It doesn't see other windows or the desktop.
- Glass is solid when someone has asked their Mac to reduce transparency or increase contrast, as on iOS.
- Interactive glass grows 6 points and lightens while the pointer holds it, on the web version's pointer spring.

Not yet: glass that merges as it comes close (`GlassEffectContainer`), and the other controls.

## Menus

A button on glass that opens a menu, and a button to choose with, which shows what's chosen. The menu grows out of its button as iOS 27's does: the pill drops into a ball, the ball swells into the menu, and the rows come into focus. Closing runs it back, and the button lands with a little squash. The motion is the web version's, read from iOS frame by frame.

```swift
GlassMenu(in: .circle, align: .leading) {
  GlassMenuItem("Share", systemImage: "square.and.arrow.up") { share() }
  GlassMenuItem("Duplicate", systemImage: "plus.square.on.square") { duplicate() }
  GlassMenuDivider()
  GlassMenuItem("Delete", systemImage: "trash", role: .destructive) { delete() }
} label: {
  Image(systemName: "ellipsis").frame(width: 44, height: 44)
}

GlassPicker(selection: $sort, options: Sort.allCases, title: \.title)
```

Rows can have headings (`GlassMenuHeading`), checkmarks (`GlassMenuItem(_:isChecked:)`), and can be disabled. A `GlassMenuPalette` puts a row of small buttons across the menu, as iOS does with Copy and Share.

The menu opens as the button is pressed, so a press can slide onto a row and choose it by letting go, or a click can open it and a second click choose. Pressed, the menu swells a little, catches more light and leans a few points after the pointer, as it does under a finger on iOS. The pointer and the arrow keys light rows; Return chooses, Escape closes, and a press outside closes it too. A menu too tall for the window scrolls. With Reduce Motion on, menus fade in and out instead. VoiceOver reads each row as a button, with chosen ones marked.

`.glassContextMenu { … }` opens a glass menu where a view is right-clicked or Control-clicked, growing out of the pointer on iOS's context-menu spring.

```swift
Tile(photo).glassContextMenu {
  GlassMenuPalette {
    GlassMenuItem("Copy", systemImage: "doc.on.doc") { copy() }
    GlassMenuItem("Share", systemImage: "square.and.arrow.up") { share() }
  }
  GlassMenuItem("Delete", systemImage: "trash", role: .destructive) { delete() }
}
```

On the Mac, put `.glassMenuHost()` on a view that covers the window, so the menus can open over it. Without it, and on iOS, the menus are the system's own.

A menu is drawn in its window, so it can't reach past the window's edges; it moves in from them, and opens upward when there's no room below.

## Demo

```sh
swift run LiquidGlassDemo
```

A busy scroll view with a toolbar, a pane you can drag, menus, and a row of buttons on glass. The `…` and `+` buttons and the three pickers open menus, and the tiles have right-click menus. The first segmented control switches between this package's glass and Apple's macOS glass, so you can compare them.

## License

MIT. Copyright Moein Saharkhiz.
