# Compact Ranked Search Visual QA (2026-08-18)

## Visual truth

- User reference: `audit/design-qa/search-reference.png` (807 × 602).
- Target state: compact dark floating search panel, a single-line search header, top-right utility icons, ranked application rows, a narrow action/detail pane and an inset bottom action shelf.
- Existing search, preview, index-state and file-operation content is retained; HapiGo-specific actions and branding are not copied.

## Implementation and interaction checks

- The default category remains `全部`; its visible result order is `应用结果` followed by `文档结果`.
- Application rows use compact native icons, visible rank badges and a blue selected state. Arrow-key navigation continues through the same grouped visible order.
- Category and hidden-file controls moved into the top-right options menu instead of occupying a second header row.
- The right pane keeps real application actions, text/image/folder previews, System Settings entries and metadata. The bottom eight actions remain functional in a rounded inset shelf.
- Successful application opens are persisted locally as count plus last-open time. Empty searches rank applications by usage; typed searches keep text relevance primary and use frequency only for equal-score ordering.
- Debug build-for-testing succeeded and direct XCTest passed 168/168 tests with zero failures before the final lexical-path optimization; the final targeted rebuild is recorded during packaging.

## Visual comparison status

- Chronicle was verified running, but both latest recorded displays were stale/locked and did not contain the newly opened PEEK window.
- The Product Design computer-control capture tool is unavailable in this runtime, so a trustworthy implementation screenshot and side-by-side comparison could not be produced. No visual pass is claimed from code inspection alone.

final compact ranked search result: blocked on live visual capture

# PEEK Brand Visual QA

## Visual truth

- Selected visual: `audit/peek-brand-2026-08-17/reference.png` (1487 × 1058), the user's third blue-purple squircle direction with the white winking page mascot.
- Production app icon: `PEEK/Resources/BrandSources/PEEK-AppIconSource.png` (1024 × 1024, true alpha).
- Production menu-bar icon: `PEEK/Resources/Assets.xcassets/PEEKMenuBarIcon.imageset/PEEKMenuBarIcon.png` and `PEEKMenuBarIcon@2x.png` (18 × 18 and 36 × 36, true alpha, template rendering intent).
- Same-input visual comparison: `audit/peek-brand-2026-08-17/comparison.png` (1800 × 980).
- Product name: `PEEK`. The source board's concept label is intentionally not copied; only the selected mascot and blue-purple visual direction are retained.

## Comparison and corrections

- The production app icon retains the reference's rounded blue-to-purple squircle, soft dimensional lighting, white page mascot, single open eye, wink and curved smile.
- The first generated export encoded transparency as a checkerboard. Visual comparison caught the defect; the asset generator now removes both connected checker tones and clears premultiplied RGB together with alpha. The final comparison shows clean transparent corners.
- The menu-bar asset reduces the same mascot to a monochrome template silhouette. macOS can therefore tint it correctly in light, dark, active and inactive menu-bar states instead of displaying a fixed-color mini app icon.
- The visible product name, Xcode project, target, executable, generated filenames, preferences, database namespace and TCC identity all use `PEEK` / `com.shawnshoper.peek`. This identity is intentionally new, so the first launch requires fresh macOS permissions.

## Build and runtime verification

- Asset catalog compilation contains `AppIcon` plus both 1× and 2× `PEEKMenuBarIcon` renditions; all three inspected source PNGs report alpha.
- The compiled app reports `CFBundleDisplayName = PEEK`, `CFBundleName = PEEK`, `CFBundleIconFile = AppIcon`, and a locally configured signing team.
- `testPEEKBrandUsesExpectedDisplayNameAndTemplateMenuIcon` loads the compiled asset from the test-host app bundle and verifies its AppKit template flag.
- Fresh Debug build-for-testing succeeded; direct XCTest passed 153/153 tests with one environment-dependent QR test skipped and zero failures.
- Fresh Apple Development Debug build succeeded and the latest process was restarted from `.build/SignedDerivedData/Build/Products/Debug/PEEK.app`.

final result: passed

# Grouped Search and Dynamic Preview Visual QA (2026-08-18)

## Visual truth

- User reference: `audit/search-redesign-2026-08-18/reference.png`.
- Final native implementation: `audit/search-redesign-2026-08-18/implementation-chinese-final.jpeg`.
- Same-state comparison: `audit/search-redesign-2026-08-18/comparison.jpeg`.
- State: dark appearance, `全部` selected, real pinyin query `wei xin`, a real indexed application selected, right preview and bottom action rail visible.

## Layout and interaction verification

- `全部` now renders separate `应用结果` and `文档结果` sections. Applications are globally first; relevance remains deterministic inside each section.
- A fresh query selects its first visible result. Up and Down move through the visible grouped order; the native arrow-key `function` flag is no longer misclassified as a conflicting modifier.
- The right pane is selected-item driven: text files show readable leading content, images use a large Quick Look preview, folders list their children, applications show actions, and System Settings exposes curated local deep links.
- Browser history is not read through private or sandbox-bypassing paths. Browser results state that recent pages require a browser extension and separate user authorization.
- The bottom English action rail uses a fixed control width, two-line fallback, consistent icon alignment and horizontal overflow instead of uneven compression.
- Chinese and English windows were inspected from the installed Apple Development build. The stored raw index type is now mapped to localized `应用程序 / 文件 / 文件夹` labels.

## Verification

- Real UI automation confirmed Down changes the selected row and synchronizes the right pane.
- Real UI inspection confirmed the System Settings catalog exposes Privacy & Security, Displays, Keyboard, Sound, Network and General.
- Debug build-for-testing and fresh unsigned Release build succeeded.
- Direct XCTest passed 160 tests with zero failures; one environment-dependent QR rendering test was skipped by the XCTest host.
- `/Applications/PEEK.app` is signed as `com.shawnshoper.peek` by a locally configured Apple Development identity and passes strict code-sign verification.

final grouped search result: passed

# File Search Visual QA

# Compact Screenshot Toolbar Option 1 Visual QA

## Visual truth

- Selected design: a local generated reference retained outside the repository (1659 × 948).
- Source toolbar crop: `audit/screenshot-toolbar-compact-option1-2026-08-17/reference-toolbar.png` (1600 × 360).
- Final native implementation: `audit/screenshot-toolbar-compact-option1-2026-08-17/implementation-toolbar-final-focused.png` (1600 × 278 normalized crop from a 5120 × 2880 Retina screenshot).
- Same-input comparison: `audit/screenshot-toolbar-compact-option1-2026-08-17/comparison-final.png` (1600 × 708).
- Viewport: 2560 × 1440 points at 2× display density; implementation capture is 5120 × 2880 pixels.
- State: dark appearance, pen selected, inline style palette open, black color selected, 4-point width selected, fill selected, no undo history.

## Comparison history

### Round 1

- P2: the first implementation's context palette began too close to the main bar's left edge and occupied too much horizontal space compared with the selected design.
- P2: an independent Save icon left four actions in the third group while the selected compact option shows three.
- P2: the width controls used long horizontal strokes instead of the selected design's increasing dot scale, and the pen selection fill was visually stronger than the reference.

Fixes:

- Set the palette indent and width to the same proportions as the selected design, reduced swatches and option controls, and tightened its internal spacing.
- Kept Share as the visible action and moved Save PNG to that button's right-click menu, preserving the operation without enlarging the main rail.
- Replaced line previews with five increasing dots and reduced the selected-tool fill while retaining its accent outline.

### Round 2

- Rebuilt and captured the native AppKit toolbar in the same dark, pen-selected state.
- The final comparison shows no actionable P0/P1/P2 difference. The final main rail is intentionally about eight percent narrower and lower than the enlarged ideation render because the user's explicit goal was to reduce toolbar size; control order, grouping and visual rhythm remain the same.

## Required fidelity surfaces

- Typography: the only visible text glyph is the native `T`; its size and optical weight match the surrounding 18-point SF Symbols. No labels or prompt text leak into the compact rail.
- Spacing and layout: the main rail uses a 44-point height, 34 × 34 hit targets, 3-point group rhythm, 10-point radius and restrained separators. The palette begins at the same relative pen-tool offset as the source.
- Colors and tokens: dark HUD material, subtle white border, system accent outline, black swatch accent ring, red cancel and green completion states match the selected direction in both dark contrast and semantic meaning.
- Assets and icon quality: native SF Symbols remain sharp at Retina density, and the existing `ToolbarColorWheel` asset is reused rather than approximated. The native disabled undo/OCR treatment is an expected real-state difference from the static render.
- Copy and content: visible controls follow the selected sequence. Tooltips and accessibility labels preserve the Chinese function names; Save remains available from the Share button's right-click menu.

## Interaction verification

- Rectangle, ellipse, counter, arrow/line, pen/highlighter, mosaic and text still select real annotation tools.
- Scroll capture, OCR, copy, undo, pin, share, cancel and complete retain their original handlers.
- Right-click on Share exposes Save PNG; right-click on arrow and pen preserves their alternate tools.
- Double-click, Return and the green check still render and copy the completed screenshot.
- Fresh Debug build and build-for-testing succeeded after the final visual refinement; direct XCTest passed 134/134 tests with zero failures.

final result: passed

## Baseline

- Reference: a local generated image retained outside the repository.
- Reference pixels: 1586 × 992
- Implementation: `/private/tmp/PEEK-file-search-implementation.png`
- Implementation pixels: 2344 × 1584 (Retina capture of a 1060 × 680 point window)
- Side-by-side comparison: `/private/tmp/PEEK-file-search-comparison.png`
- State: dark appearance, pinyin query `wei xin`, application result selected, detail preview visible, default action bar visible.

## Comparison rounds

### Round 1

- The first implementation used a previously persisted 900 × 622 window frame, making the result and preview columns feel compressed compared with the selected design.
- An automatically restored screenshot settings window was also visible behind the search panel, violating the menu-bar-only launch requirement.

Fixes:

- Versioned the search panel frame persistence key and explicitly applied the 1060 × 680 default content size before centering.
- Added launch-time cleanup for automatically restored application windows; normal launch now leaves only the menu-bar item visible.
- Kept a Debug-only UI-test launch argument so the search panel can be captured without changing production launch behavior.

### Round 2

- Re-captured the native search panel at 1060 × 680 points.
- Compared the reference and implementation in the same side-by-side image.
- Header hierarchy, category chips, result/detail split, blue selected row, large native application icon, metadata separators, eight-action footer, dark material, spacing, and bottom index status align with the reference direction.
- The implementation intentionally shows only the committed Applications generation in this state; files and folders appear after their authorized roots commit. This matches the application-first indexing requirement rather than using mock results.

## Interaction checks

- Search input is focused when the panel opens.
- Pinyin fuzzy query `wei xin` resolves the real `微信.app` entry.
- Category and hidden-file filters are interactive.
- Arrow-key selection, Return-to-open, Escape-to-close, and the bottom action controls remain wired.
- The panel is resizable and persists the new versioned frame after the redesigned default is established.
- Normal app launch restores no screenshot history/main window; the search panel is opened only by an explicit shortcut/menu action.

final result: passed

# OCR Reference Window Visual QA

## Visual truth

- User reference: `audit/ocr-reference-2026-08-16/reference.png` (2458 × 1000).
- Final native implementation: `audit/ocr-reference-2026-08-16/implementation-window-compact.png` (2440 × 1000).
- Same-state stacked comparison: `audit/ocr-reference-2026-08-16/comparison.png`.
- State: dark appearance, real local Vision OCR result, recognized region overlay enabled, layout-preserving text mode enabled.

## Match review

- The window now uses the reference's wide 1220 × 500-point geometry, transparent titlebar, compact 40-point toolbar, native traffic lights, dark split canvas and narrow editable result pane.
- Toolbar grouping follows the reference: region navigation, zoom controls, fit, rotate, overlay editing, formatted/plain-text mode, layout regeneration, export, more actions and pin-to-top.
- The left pane displays the source image and real OCR geometry; the right pane is an editable monospaced text surface. The split divider remains draggable.
- The final comparison was generated from the provided reference and a screenshot of the compiled macOS app at the same 1000-pixel height. The earlier overly tall 1220 × 720 window was rejected and corrected before final acceptance.

## Format reconstruction and interaction verification

- Vision rectangles are grouped into rows and columns to retain line breaks, paragraph gaps, indentation and horizontal spacing. Plain text remains available as a fallback.
- Copy places both UTF-8 plain text and monospaced RTF on the pasteboard. Export supports TXT and RTF.
- Previous/next region, zoom, fit, rotate, overlay toggle, format toggle, regenerate layout, save, more menu and pin all invoke real behavior rather than placeholder actions.
- Exact source fonts, syntax colors and arbitrary rich document styling are not inferred because Vision does not provide those attributes; geometry-based layout is preserved without fabricating style metadata.

## Verification

- Fresh Debug build succeeded.
- Fresh build-for-testing succeeded.
- Direct XCTest passed 121/121 tests with zero failures, including two OCR layout/RTF tests.
- Fresh unsigned Release build succeeded. Three existing Swift 6 concurrency migration warnings remain outside the visual/layout acceptance boundary.

final OCR result: passed

# Photo Reference Screenshot Toolbar Visual QA

## Visual truth

- User photo reference: `audit/screenshot-toolbar-photo-reference-2026-08-16/reference.jpg` (4032 × 634).
- Final native implementation: `audit/screenshot-toolbar-photo-reference-2026-08-16/implementation-toolbar-with-palette-final.png` (1900 × 540 Retina capture).
- Same-state comparison artifact: `audit/screenshot-toolbar-photo-reference-2026-08-16/comparison.png`.
- State: dark appearance, pen selected, contextual color/width/fill rail visible, undo disabled because the preview has no annotation history.

## Match review

- Replaced the previous text-heavy and blue split-completion design with the photo's single long, icon-only dark HUD.
- Matched the primary order and grouping: rectangle, ellipse, counter, arrow, pen, mosaic, text; copy, OCR, scroll capture; undo, save, pin, share; red cancel and green complete.
- Matched the photo's compact vertical separators, monochrome SF Symbol weight, dense horizontal rhythm, restrained 12-point corner radius, border, shadow and dark translucent material.
- The selected pen uses one subtle neutral selection tile so the active annotation mode remains discoverable without adding labels or changing the reference hierarchy.
- The contextual style rail stays above the primary toolbar, matching the reference's upper formatting strip while preserving real color, width and fill controls.
- The source is a photographed display with perspective, moire and no reliable point scale. Fidelity was therefore evaluated on visible control order, relative spacing, grouping, color states and silhouette rather than copying camera distortion.

## Functional verification

- Rectangle, ellipse, counter, arrow, pen, mosaic and text select real annotation tools; right-click menus preserve line and highlighter access without adding visible controls absent from the reference.
- Copy writes eager PNG/TIFF clipboard data; OCR, rolling capture, save, pin and share invoke real application workflows.
- Undo tracks document history; the red X cancels; the green check, Return and double-click render and copy the completed image.
- Debug build and test build succeeded; direct XCTest passed 119/119 tests with zero failures.
- Fresh unsigned Release build succeeded.

final photo-reference toolbar result: passed

# Settings Visual QA

## Reference audit

- HapiGo settings screenshots: `audit/hapigo-settings-2026-08-14/01-general.png` through `07-appearance.png`.
- Reused design principles: native macOS toolbar categories, grouped forms, compact explanatory copy, search-specific secondary navigation, immediate persistence, and clear permission/status feedback.
- Intentionally omitted: HapiGo-specific extensions, translation, document preview, network/account features, and unsupported language controls.

## PEEK implementation check

- Runtime build: `/private/tmp/PEEKSettingsDerivedData/Build/Products/Debug/PEEK.app`.
- Checked the real SwiftUI settings window in dark appearance at 860 × 640 points.
- Top toolbar exposes `通用 / 搜索 / 快捷键 / 截图 / 外观 / 关于` without clipping.
- Search page exposes only `文档搜索 / 应用搜索 / 搜索排除`; the two-column split remains readable and the detail side scrolls rather than overflowing.
- Initial-index ETA and connection/maintenance status remain visible in the sidebar footer without exposing database internals as a separate settings page.
- Capture page clearly states clipboard-only default output and keeps permission/readiness controls visible above scrolling options.
- Normal production launch still has no `WindowGroup`; settings are only shown after an explicit menu action. The `--show-settings-for-ui-testing` path is Debug-only.

final settings result: passed

# Simple Search Settings Visual QA

## Visual truth

- Reference: `audit/simple-search-settings/reference-application-search.png` (760 × 654).
- Final implementation: `audit/simple-search-settings/implementation-application-search-final.png` (900 × 708).
- Side-by-side comparison: `audit/simple-search-settings/comparison-application-search-final.png`.
- Document defaults state: `audit/simple-search-settings/implementation-document-search-final.png` (900 × 708).
- State: dark appearance, `应用搜索` selected, default application roots visible.

## Comparison and iteration

- Preserved the reference hierarchy: compact native toolbar, three-item search sidebar, selected blue row, right-side title/actions, alternating root rows, bottom status and explanatory footer.
- Corrected the first capture's reversed alternating-row sequence so the first row is plain and the second row is shaded, matching the reference.
- Removed the default sidebar material tint so the split view uses the same restrained dark native background as the reference.
- Intentionally reduced the long reference list to three product-owned defaults: `/Applications`, `/System/Applications`, and `/System/Library/CoreServices/Applications`. This keeps the first-use surface understandable and avoids exposing internal system paths.
- Intentionally uses PEEK's six real toolbar destinations instead of copying HapiGo-only categories.

## Interaction and state checks

- `文档搜索` initially lists 文稿、桌面、下载、用户目录 as explicit authorization suggestions; each row remains outside the index until the user confirms it through the system directory picker.
- `应用搜索` shows deletable defaults, supports adding custom directories, and exposes `恢复默认` even after every default is removed.
- `搜索排除` is initially empty and only shows paths explicitly added by the user; there are no visible default exclusions, suffix rules, or folder-name rules.
- The three sidebar destinations, add actions, delete controls, reauthorization warning, footer state and immediate persistence are wired to real stores rather than mock data.
- No destructive delete/add action was performed during visual QA, so the user's current root configuration was not modified.

final simple search settings result: passed

# Reference Search Settings Visual QA

## Visual truth

- User reference: `/var/folders/0w/cnq2c8gs1n7dwvq33lvpd2l00000gn/T/codex-clipboard-59dbb97a-cf11-447f-9e08-87bb047ef9fc.png` (1417 × 1111).
- Native implementation capture: `audit/reference-search-settings/implementation-document-search-active.png` (900 × 708).
- Same-state side-by-side comparison: `audit/reference-search-settings/comparison-document-search.png` (1800 × 708).
- State: dark appearance, `搜索 > 文档搜索`, first directory selected, background index currently updating.

## Match review

- The native Settings toolbar now matches the six reference destinations and symbols: `通用 / 搜索 / 快捷键 / 截图 / 外观 / 关于`; the active search item uses the macOS accent color and selected toolbar background.
- The search page preserves the reference hierarchy: left settings sidebar, title and actions, three-column directory table, selected blue row, right directory inspector, connection footer, and real-time-save footer.
- Directory rows show real permission and index states rather than mock labels. The inspector reuses the selected row's title, shortened path, permission, index state and supported actions.
- The four default document entries remain visible after authorizing the user home directory. Child defaults display `已包含`; the user directory displays `已授权`, preventing duplicate scans without hiding the defaults.
- Pending and expired authorizations use direct text actions (`授权` / `重新授权`) rather than a warning-only affordance. `恢复默认` restores the four visible defaults independently of current bookmarks.
- Controls remain native SwiftUI/AppKit components, so keyboard focus, VoiceOver semantics, dark/light appearance and system accent colors are preserved.

## Functional verification

- Debug build-for-testing succeeded.
- Direct XCTest run passed 116/116 tests with no failures.
- The real compiled macOS window was launched, navigated through the top `搜索` toolbar item, captured and compared against the provided reference.
- No mock directory rows or screenshots were used in the implementation state.

final reference search settings result: passed

# Settings Trailing Alignment Visual QA

## Visual truth

- User-reported failure: `/var/folders/0w/cnq2c8gs1n7dwvq33lvpd2l00000gn/T/codex-clipboard-d3431e31-be5b-43ad-84f7-95b0e36ef467.png`.
- Final general settings capture: `audit/settings-alignment-2026-08-15/01-general.png`.
- Additional captures: `02-shortcuts.png`, `03-capture.png`, `04-capture-lower.png`, `05-appearance.png`, `06-about.png`, `07-search.png`.
- State: dark appearance, real compiled SwiftUI settings window at its 980-point minimum width.

## Comparison and fix

- The failed layout aligned controls only inside the narrower content proposal supplied by `Form(.grouped)`, leaving roughly 100–130 points between controls and the section edge.
- Non-search settings pages now use a full-width scroll layout with explicit native section cards. Each row receives the card's complete inner width.
- Popup pickers also align their intrinsic control at the trailing edge of their fixed layout slot, rather than centering inside it.
- In the final general settings capture, the section card ends at approximately x=956 and the popup controls end at approximately x=935: a consistent 21-point inner margin.
- Shortcut states, capture controls, steppers, segmented controls, toggles and diagnostic buttons use the same trailing guide.

## Functional verification

- All six toolbar destinations remain accessible and visually stable.
- Capture settings remain vertically scrollable at the minimum window size.
- Search retains its dedicated split/table layout and index progress presentation.
- Debug build and test build succeeded; direct XCTest passed 117/117 tests.
- Fresh unsigned Release build succeeded.

final settings trailing alignment result: passed

# Screenshot Inline Toolbar Redesign Visual QA

## Visual truth

- Selected reference: a local generated image retained outside the repository (1672 × 941).
- Final native implementation: `audit/screenshot-toolbar-redesign-2026-08-15/implementation-toolbar-exact-final.png` (806 × 125).
- Final same-state comparison: `audit/screenshot-toolbar-redesign-2026-08-15/comparison-toolbar-exact-final.png` (1400 × 680).
- State: dark appearance, pen selected, black color, line width 4, filled shape option, contextual rail open.
- The source is an enlarged design rendering. At native macOS metrics, its toolbar normalizes to roughly 794 × 134 points; the final implementation is 806 × 125 points.

## Comparison and iteration

- Round 1 failed the strict comparison: it was only 746 × 98, omitted fill/outline, exposed four widths instead of five, used a different color order, retained native double chevrons, and had no contextual pointer.
- Round 2 corrected the hierarchy and dimensions, but native segmented controls rendered blue-filled selections instead of the reference's dark controls with blue outlines.
- Round 3 replaced those segmented controls with custom native buttons and matched the reference's two-level HUD rails, 64-point secondary indent, pointer location, color order, real source color-wheel asset, five width choices, fill/outline pair, grouped undo/redo, action separators, and blue split completion control.
- A final visible-difference pass changed the selection glyph to a dashed square, rendered the first width as a dot, removed blue fill from selected tools, and aligned OCR/copy typography with the source.
- The implementation uses SF Symbols for the closest maintainable native equivalents; the selected pen is the nearest monochrome system pencil glyph rather than a raster copy of the rendered reference icon.

## Functional verification

- Shape popup exposes `矩形 / 椭圆`; arrow popup is wired to `箭头 / 直线`.
- Selecting a swatch updates the annotation color; all five width buttons update the single-choice line-width state.
- `填充形状 / 仅描边` are real rendering modes. The pixel-level rectangle test verifies that the filled option changes interior pixels while outline does not.
- Undo and redo track document history. Pin, OCR, copy, save, cancel, and done invoke the existing screenshot workflows rather than placeholder handlers.
- The completion dropdown exposes `保存为 PNG… / 取消截图`; `完成`, double-click, and Return render the annotations and copy the final image.
- Clipboard output is produced eagerly as PNG and TIFF so it survives dismissal of the transient overlay.
- Accessibility inspection exposes labels for every primary action, every swatch, the color wheel, all five width choices, and both fill choices.
- The real compiled app was used to open both popup menus and toggle fill/outline; no static mock was used for interaction verification.
- Final Debug build succeeded. The post-refinement complete XCTest bundle passed 119/119 tests with zero failures, and the fresh unsigned Release build succeeded.

final result: passed
