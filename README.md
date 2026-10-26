# LiteCode

A small native macOS code editor (SwiftUI + AppKit): file explorer, tabbed editor with
syntax highlighting and line numbers, side-by-side git diffs of changed files, and an
integrated terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)).

## Build

```sh
./scripts/bundle.sh            # build/LiteCode.app
./scripts/bundle.sh --install  # also copies it to /Applications
./scripts/package.sh 1.2.3     # build/LiteCode-1.2.3.dmg
swift test                     # diff alignment, git status parsing, fuzzy matching
```

Releases are published on GitHub with a signed [Sparkle](https://sparkle-project.org) appcast
(`appcast.xml` on `main`); installed copies update via **LiteCode ▸ Check for Updates…**. Builds
are not notarized, so the first manual install needs right-click ▸ Open.

Add folders as workspaces (⌘O or the `+` in the title bar), or `open -a LiteCode <folder>`.
Each workspace is a tab in the title bar; switching keeps its editor tabs, unsaved edits,
and terminals alive. The workspace list and each one's open files are restored on launch.

## Shortcuts

| Action | Keys |
| --- | --- |
| Add workspace / New file | ⌘O / ⌘N |
| Next / previous workspace | ⌥⌘] / ⌥⌘[ |
| Go to workspace 1–9 (title-bar order) | ⌘1 … ⌘9 |
| Save / Save all | ⌘S / ⌥⌘S |
| Close tab / Next, previous tab | ⌘W / ⇧⌘] ⇧⌘[ |
| Find / Replace in file / Next / Previous | ⌘F / ⌥⌘F / ⌘G / ⇧⌘G |
| Go to file (Quick Open: fuzzy file name search, recently opened first) | ⌘P |
| Search in workspace (a single-line selection seeds ⌘F and ⇧⌘F) | ⇧⌘F |
| Toggle comment / Indent / Outdent | ⌘/ / ⌘] / ⌘[ |
| Explorer / Changes | ⇧⌘E / ⌃⌘G |
| Toggle sidebar | ⌘L |
| Toggle terminal / New terminal | ⌘B / ⌃⇧\` |
| Font size / Settings | ⌘= ⌘- / ⌘, |

## Notes

- Colors follow the [Oh My Dark](https://open-vsx.org/extension/luanzt/oh-my-dark) VS Code
  theme (Cursor Dark UI + Dracula Soft syntax); the palette lives in `Sources/LiteCode/Theme.swift`.
- File and folder icons come from [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme)
  5.39.0 (MIT), vendored in `Sources/LiteCode/Resources/MaterialIcons`; sidebar mode icons are
  [Lucide](https://lucide.dev) (ISC).
- Switching to a tab (editor or diff) reveals its file in the explorer, as VS Code's
  `explorer.autoReveal` does: parent folders expand, the row is highlighted, and the tree
  scrolls just enough to show it.
- Source Control lists "Staged Changes" (shown when something is staged) above "Changes", as in
  VS Code; hovering a file or group header offers open, stage (+), unstage (−), and discard (↶,
  after confirmation; untracked files go to the Trash). The editor gutter's change markers
  (green = added, hatched orange = modified, red triangle = deleted) compare with the index.
  A diff tab shows both whole files side by side: staged changes as HEAD ↔ index ("(Index)"),
  unstaged ones as index ↔ working tree ("(Working Tree)"), scrolled together, with changed lines
  tinted, edited characters emphasized, and hatching where one side has no line; ↑/↓ in its
  header jump between changes, and a strip on the right edge marks where the changes are. The
  working-tree side is the file itself: editable (⌘S, undo, ⌘F) and shared with the file's
  editor tab, with the diff updating as you type. Beside each change, → reverts that block and
  + stages just that block; in an "(Index)" diff, − unstages it.
- ⌘F opens a VS Code-style find box in the editor's top-right corner (match case, whole word,
  regex; ↩ / ⇧↩ for next / previous, Esc to close); ⌥⌘F adds the replace row, where regex
  replacements may use `$1` groups and Replace All is a single undo step.
- Workspace search uses `git ls-files` (so .gitignore applies) in repositories, otherwise it
  walks the folder skipping `node_modules`, build output, and `.git`; files over 2 MB and
  binaries are skipped, and results stop at 5,000 matches.
- Settings (⌘,): editor font family and size, sidebar and tab bar font sizes, and auto save
  (VS Code's `files.autoSave`: off, afterDelay with a configurable delay, onFocusChange,
  onWindowChange). Auto-save failures leave the tab dirty silently; ⌘S reports them.
- Highlighting is regex-based and skipped for files over 400 KB.
- Opening a folder in LiteCode from Finder, the Dock, or another app (`open -a LiteCode <folder>`,
  as mTerm's ⌘R does) switches to that folder's workspace, adding it if needed. On a cold
  launch the saved workspaces are restored first, then the opened folder is handled.
- The folder is watched with FSEvents: the tree, git status, open diffs, and unmodified
  open files refresh when something changes on disk.
