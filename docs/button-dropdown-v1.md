# Button dropdowns — shared visual renderer, V1

Scope: Redesigned / Legacy Glass (iOS 16–25). Only button-triggered
`SGRMenuAnchor`/`SGRMenuFront` `UIMenu` sessions; long-press context menus,
share sheets and Spotify bottom sheets keep their existing implementation.
System iOS 26 menus are not repainted.

UI references inspected during development:
- `ContextControllerImpl/Sources/ContextControllerActionsStackNode.swift`
- `ContextControllerImpl/Sources/ContextActionsContainerNode.swift`
- `GlassBackgroundComponent` (reference API for context action stacks)

This patch is an original UIKit/Objective-C visual adaptation rather than a
verbatim copy of third-party GPL-v2-or-later Swift/AsyncDisplayKit code. The
referenced component requires AccountContext, ContextUI, Display,
GlassBackgroundComponent and other submodules. Importing it unmodified into
a Theos Logos tweak is not viable.

V1 visual geometry: up to 30pt continuous corners for the glass panel; 10pt
horizontal inset on the highlighted action; 20pt maximum highlight radius;
light translucent highlight; eased 160ms highlight transfer. The panel uses
Vitrine's own Legacy Glass blur, refraction and shared rim. The menu content,
items, icons, submenus, destructive roles, accessibility and actions remain
owned by UIKit and the existing Vitrine menu session. Other menu looks are
unchanged.

Not yet implemented: compositor-locked highlight tracking on fast drags;
source-button-to-panel morph on open/close; iOS 26 reference measurements.
The existing `SGRGlassBubbleOpen` first-menu transition remains for now.

Suggested simulator smoke test: player `⋯` -> initial items, More submenu,
fast finger drag without release, select a row, close without selection;
then entity page `⋯` with long menus and scroll, dark mode, Spotify sheet
fallback, and native/no-redesign mode. Compare iOS 18 screenshots against
iOS 26 reference measurements. Confirm actions still reach Spotify.
