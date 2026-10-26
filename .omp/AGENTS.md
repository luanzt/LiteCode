# LiteCode

A lightweight native macOS code editor (SwiftUI + AppKit, Swift Package Manager): file explorer,
tabbed editor with regex syntax highlighting, VS Code-style find, workspace search, git Source
Control with side-by-side diffs and hunk staging, and an integrated terminal (SwiftTerm).

## Commands

```sh
swift build                     # debug build
swift test                      # LiteCodeCore unit tests (swift-testing)
./scripts/bundle.sh             # release build → build/LiteCode.app (version = latest tag)
./scripts/bundle.sh --install   # also copies it to /Applications
./scripts/package.sh 1.2.3      # → build/LiteCode-1.2.3.dmg
./scripts/generate-appcast.sh 1.2.3  # signs the DMG (Sparkle EdDSA, Keychain) → build/appcast.xml
```

Releases go through the project skill `release-app` (`.omp/skills/release-app/SKILL.md`): tag,
GitHub Release with the DMG, then the signed `appcast.xml` committed on `main`, which installed
copies read via Sparkle (**Check for Updates…**). Never regenerate the `litecode-ed25519` key: its
public half is baked into every shipped build as `SUPublicEDKey`.

## Layout

- `Sources/LiteCodeCore/` — pure, UI-free logic, covered by `Tests/LiteCodeCoreTests/`:
  `LineDiff` (row alignment, hunks, intra-line spans), `GitStatus` (porcelain parser with
  staged/unstaged stages), `GutterDiff`, `TextSearch`, `FuzzyMatch`, `IconThemeManifest`,
  `PathOrder` (VS Code's path order for search results and changes), `CodeStructure` (JSX
  element and bracket-pair scanners the highlighter runs after its regexes).
  Put new logic here when it can be tested without AppKit.
- `Sources/LiteCode/` — the app:
  - `Editor/` — `EditorDocument` (one per open file; owns its text storage, undo, dirty state,
    highlighting, auto save), `CodeTextView` (+ `LineNumberRuler`, indent guides, diff
    decorations), `SyntaxHighlighter`, `FindModel`.
  - `Diff/` — `DiffDocument`/`DiffPane`/`DiffLayout` (full-file side-by-side diff; the
    working-tree pane is a second view onto the file's `EditorDocument` storage), `DiffGutter`
    (block revert/stage/unstage buttons, overview ruler), `DiffView`.
  - `Workspace/` — `Workspace` (one open folder: tree, tabs, git state, staging actions,
    terminals), `Workspaces` (title-bar workspace tabs, persistence), `FileNode`, `SearchModel`.
  - `Views/` — SwiftUI chrome: `ContentView`, `Sidebar`, `EditorArea`, `FindWidget`,
    `SearchView`, `WorkspaceTabs`, `ThemeScroll`, `LucideIcon`, `MaterialIcons`.
  - `Git.swift` (git CLI wrapper), `Theme.swift` (all colors), `Settings/`, `Terminal/`.

## Constraints that have bitten before

- Keep the deployment target at **macOS 14** (`Package.swift`). Linking against macOS 15 made
  SwiftUI stop presenting the main window at launch. Gate macOS 15 APIs with `#available`
  (see `ThemedScrollView`).
- The editor is **TextKit 1** on purpose: the line-number ruler, indent guides, and diff gaps walk
  `NSLayoutManager` line fragments.
- Hand-drawn `NSView`s must set `clipsToBounds = true` and fill only
  `dirtyRect.intersection(bounds)`: views don't clip by default and the dirty rect can extend past
  the bounds, which once painted over the diff panes and the tab bar.
- Diff panes use **contiguous layout** (`makeScrollView(storage:contiguousLayout: true)`): rows line
  up across panes by exact y offsets, which non-contiguous height estimates break. Filler rows are
  layout-manager paragraph spacing, never inserted text, so the right pane stays the real file.
  `makeScrollView` attaches the storage only after configuring the view, then lays a contiguous
  view out in one `ensureLayout` pass: configuring a view that already holds text (notably
  `textContainerInset`) made the 1,400-line diff pane take 280ms instead of 45ms.
- An `NSScrollView` with a floating vertical ruler uses a negative-x content inset: scroll the clip
  view to `x = -contentInsets.left`, not 0. Subviews added directly to an `NSScrollView` are not
  autoresized; position overlays in the parent.
- A shared `NSTextStorage` keeps every attached layout manager alive and laid out: diff tabs must
  `close()` (detach their pane) when the tab closes.
- Per-keystroke paths are hot (2,500-line files): read `CodeTextView.characters` (no String
  bridging), compare `NSString`s for dirty checks, write `@Observable` properties only when the value
  changes, tokenize highlighting off the main thread.
- Colors come from `Theme.swift` (Oh My Dark theme keys noted per color). UI icons are Lucide SVG
  markup embedded in `LucideIcon.swift`; file icons are Material Icon Theme, vendored under
  `Resources/MaterialIcons` with its MIT `LICENSE.txt`.
- Paths: workspace and repository roots are canonicalized (`/private/var/...`, not `/var/...`);
  compare against those, not raw input paths.

## Verifying UI changes

- Run a **copy** of the bundle with a different bundle identifier so real user defaults
  (workspaces, open tabs, settings) are untouched:
  `cp -R build/LiteCode.app /tmp/LCTest.app`, set `CFBundleIdentifier` to
  `dev.luan.litecode.smoketest` with `PlistBuddy`, `codesign --force --sign -`, then launch its
  binary directly. Afterwards delete the copy and `defaults delete dev.luan.litecode.smoketest`.
- Drive scenarios from a temporary env-gated `Sources/LiteCode/SmokeScaffold.swift` hooked at the end
  of `applicationDidFinishLaunching`, logging to a file and capturing the window with
  `view.cacheDisplay(in:to:)`. Use copies of files in a temp git repo, never real projects.
  Remove the scaffold file and its hook before committing.
- Never synthesize events with `NSEvent()` (it corrupted memory and crashed the app). Call model
  methods or `insertText(_:replacementRange:)` instead.
- Scaffolds that edit a document must leave it clean before `NSApp.terminate`, or the quit
  confirmation alert blocks the run.
