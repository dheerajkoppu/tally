# Apple design brief for macOS 26 Tahoe / macOS 27 Golden Gate (researched 2026-09-24)

Tags: [Apple] primary source, [3P] third party, [Inferred] our reasoning, [27] new in 27, [Verified locally] run on this Mac
(Xcode 27.0 27A266a, macOS 27.0 SDK). macOS 27 "Golden Gate" shipped September 14, 2026.

## 1. App icons

- [Apple] HIG App icons: "In iOS, iPadOS, and macOS, icons are square, and the system applies masking to produce rounded
  corners." "Produce appropriately shaped, unmasked layers… provide square layers." "Providing layers with pre-defined
  masking negatively impacts specular highlight effects and makes edges look jagged." 1024×1024 px layout.
  Appearances: Default, Dark, Clear Light, Clear Dark, Tinted Light, Tinted Dark.
  https://developer.apple.com/design/human-interface-guidelines/app-icons
- [Apple] "Irregularly shaped icons receive a system-provided background." [3P] The grey "squircle jail" container still
  applies in 27, even to some pre-rounded legacy icons. Ship a `.icon` (Icon Composer) file to avoid it.
- [Apple] Layers: a background layer and one or more foreground layers, at most four groups. "Prefer clearly defined edges
  in foreground layers." "Vary opacity in foreground layers." "Prefer vector graphics (SVG or PDF)." Background
  "full-bleed and opaque" or an Icon Composer fill. "Let the system handle blurring and other visual effects" — no baked
  highlights, shadows, bevels, blurs or glows. Convert text to outlines; do not export the mask.
- [Apple] "Embrace simplicity… a minimal number of shapes." "Include text only when it's essential." "Prefer
  illustrations to photos and avoid replicating UI components." "Keep your icon's features consistent across
  appearances." "Use your light app icon as the basis for your dark icon." Annotate Default, Dark and Mono (Mono drives
  clear and tinted); the system generates what you do not provide.
- [Apple][27] HIG updated June 8, 2026 ("Refined guidance for Liquid Glass"); Icon Composer 2. Specular highlights and
  Refraction render differently in 27; Icon Composer can compare 26 vs 27 rendering. Apple reduced translucency in its own
  icons this year and advises reviewing yours.
- [Apple] With a deployment target before 26, Xcode/actool generates flattened fallback images from the `.icon` file.

### Compiling without Xcode [Verified locally]

```
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" \
  --output-format human-readable-text --notices --warnings --errors \
  --output-partial-info-plist build/icon-partial.plist \
  --app-icon AppIcon --platform macosx --target-device mac \
  --minimum-deployment-target 15.0 --standalone-icon-behavior all
```

Produces `Assets.car` (icon stack in light, dark and tintable), flattened 16–1024 px fallbacks and `AppIcon.icns`
(`--standalone-icon-behavior all` gives the full size set). Info.plist: `CFBundleIconFile` = `AppIcon` and
`CFBundleIconName` = `AppIcon` (matching `--app-icon` and the `.icon` file name). Sign after copying.

Minimal `icon.json` that compiles (schema undocumented):

```
{"fill":{"automatic-gradient":"extended-srgb:0.1,0.6,0.4,1.0"},
 "groups":[{"layers":[{"image-name":"glyph.svg","name":"glyph"}]}],
 "supported-platforms":{"squares":"shared"}}
```

Previews: `/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool AppIcon.icon
--export-image --output-file out.png --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1
[--design-generation 26|27]`. Renditions: Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark.
A scratch example lives in the session scratchpad `icontest/`.

## 2. Liquid Glass

- [Apple] HIG Materials: "Don't use Liquid Glass in the content layer… use Standard materials for elements in the content
  layer, such as app backgrounds." "Use Liquid Glass effects sparingly." Glass is "a distinct functional layer for
  controls and navigation elements." WWDC26 SwiftUI lab: "we would encourage people to not use Liquid Glass inside the
  content area"; toolbar buttons already get glass; prefer `.buttonStyle(.glass)` / `.glassProminent` over `.glassEffect`
  on buttons. → Dashboard cards and charts stay plain.
- [Apple] APIs (macOS 26+, wrap in `if #available(macOS 26, *)`): `glassEffect(_:in:)` (`.regular`, `.clear`,
  `.identity`, `.tint()`, `.interactive()`), `GlassEffectContainer(spacing:)` for several glass views, `glassEffectID`,
  `glassEffectUnion`, `.buttonStyle(.glass)`, `.glassProminent`, `ToolbarSpacer`, `sharedBackgroundVisibility(_:)`,
  `scrollEdgeEffectStyle(_:for:)`, `scrollEdgeEffectHidden`, `safeAreaBar(edge:)`, `backgroundExtensionEffect()`,
  `ConcentricRectangle`, `containerShape(_:)`. AppKit: `NSGlassEffectView`, `NSButton.BezelStyle.glass`.
- [Apple] "Reduce your use of custom backgrounds in controls and navigation elements" (toolbars, title bar). "Audit the
  backgrounds of sheets and popovers… remove those custom background views."
- [Apple][27] Glass tuned automatically (darkened edge, brighter speculars); a new system slider from ultra clear to fully
  tinted; toolbars get a uniform background when content scrolls under them; HIG Scroll views: "Prefer the automatic
  scroll edge effect style"; on macOS custom glass elements can be `.interactive()`. No new or renamed glass modifiers in
  the 27 SDK. New 27 toolbar APIs: `contentMarginsRemoved(_:)`, `toolbarMinimizationBehavior`. In apps built with the 27
  SDK, `controlSize` and `buttonSizing` reset to defaults inside sheets and popovers.
- [Apple] `UIDesignRequiresCompatibility` is ignored when building for macOS 27; no opting out of the new look.

## 3. Windows, toolbars, menus, Settings, menu bar extras

- [Apple][27] Every window has a tighter corner radius; never hard-code the window radius. Custom components in bars
  need concentric radii (`ConcentricRectangle`, 27 adds `GeometryProxy.concentricCornerRadii`).
- [Apple] Toolbars: "Reduce the use of toolbar backgrounds and tinted controls"; at most three groups; one primary action;
  "Make every toolbar item available as a command in the menu bar."
- [Apple] Segmented controls (macOS): for view switching in a toolbar, a segmented control is appropriate, about five to
  seven segments at most. [Apple][27] New `.pickerStyle(.tabs)` (macOS 27 only): "VoiceOver reads it as 'tabs,' and on
  macOS it has a distinct visual appearance." AppKit: `NSSegmentedControl` tabs role. [Inferred] Use a `Picker` in the
  toolbar's principal slot with `.tabs` on 27 and `.segmented` on 15–26; mirror tabs in the View menu (⌘1…⌘n).
- [Apple][27] Menus: SwiftUI now hides menu item symbol images in most contexts; "Use menu item icons sparingly"; icons
  for all items in a group or none.
- [Apple] Settings windows: a noncustomizable toolbar that always shows the active pane; dim the minimize and zoom
  buttons; window title follows the pane; restore the last viewed pane; no settings button in the main toolbar.
- [Apple] Menu bar extras: use a menu unless the functionality is too complex (a chart panel qualifies); template image;
  the menu bar is 24 pt tall; "Let people — not your app — decide whether to put your menu bar extra in the menu bar"
  (provide a setting); do not rely on it being visible. [27] `NSStatusItem.expandedInterfaceSession` for keyboard focus
  in custom panels. [3P] 27 adds a native overflow for menu bar extras.
- [Apple] Popovers: one at a time; never for warnings. Sheets: use a panel for repeated input; [27] let non-essential
  sheets not block quitting.

## 4. Accessibility and motion

- [Apple] Meet contrast minimums (WCAG AA 4.5:1 for text up to 17 pt) or provide higher contrast under Increase
  Contrast; "Convey information with more than color alone."
- [Apple] Reduce Motion: tighten springs, replace transitions with fades, avoid blur animations; "Make motion optional."
- [Apple][27] Dedicated Show Borders setting on macOS 27 (`accessibilityShowBorders`); earlier it follows Increase
  Contrast. Also `accessibilityReduceTransparency`, `colorSchemeContrast`, `accessibilityDifferentiateWithoutColor`,
  `appearsActive` (dim custom UI in inactive windows).
- [Apple] Charts: "Make every chart in your app accessible"; give a title and summary (`accessibilityChartDescriptor`,
  macOS 12+); describe what the data means, not what it looks like; hide axis/tick labels from assistive tech; highlight
  important changes in other ways too; never require interaction to reveal critical information.
- [Inferred] For a live dashboard: one combined accessibility element per card with a text summary; announce threshold
  crossings only; no per-sample chart animation under Reduce Motion; pair colour with shape or line style per series.

## 5. Energy efficiency

- [Apple] Energy Efficiency Guide for Mac Apps: respond to events rather than polling; timers with tolerance (~10%);
  invalidate timers you do not need; `NSBackgroundActivityScheduler` for periodic maintenance; run at utility QoS or lower
  at least 90% of the time without user activity.
- [Apple] "Don't rely on App Nap"; "if your app creates a status item that's present in the menu bar, your app is
  considered visible" — throttle using window occlusion and popover visibility yourself.
- [Apple] WWDC26 Power lab: SwiftUI view over-invalidation is a "silent battery killer."
