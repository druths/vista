# Vista for iOS

Universal SwiftUI app (iPhone + iPad) over the same Vista API the web client
uses. iOS 17+, no third-party dependencies.

```bash
open ios/Vista.xcodeproj      # then ⌘R
```

Verified with `xcodebuild` against the iOS Simulator SDK in Debug and Release —
both build with no warnings.

## Signing

`DEVELOPMENT_TEAM` is deliberately empty so the project builds for anyone.
Xcode will ask you to pick a team the first time you run on a device; the
Simulator needs nothing. The bundle id is `com.derekruths.vista`.

## Pointing it at a server

Unlike the web client, an installed app has no build-time configuration, so the
**Vista server address** is the first field on the sign-in screen. It's kept in
`UserDefaults` for next launch; the session token goes to the **Keychain**
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, out of
backups and iCloud Keychain).

A Vista server on a LAN is usually plain HTTP, which App Transport Security
blocks by default. `Vista-Info.plist` sets `NSAllowsLocalNetworking`, which
permits cleartext to private/link-local addresses and `.local` names **without**
disabling ATS for the public internet. iOS also prompts once for local network
access; `NSLocalNetworkUsageDescription` supplies that prompt's text.

## Markup is the real Apple Markup

Marking up a brief presents `QLPreviewController` with
`editingModeFor` returning `.updateContents` — this is Apple's own Markup UI,
not a PencilKit reimplementation. Pen, highlighter, shapes, text boxes, ruler
and Apple Pencil behaviour all come from the system and keep improving with it.

Two copies keep the flow safe:

1. The brief is downloaded into a **cache** file (`BriefCache`).
2. Markup gets a **private throwaway copy**, because `.updateContents` edits
   the file in place and the cached original must stay pristine.
3. The edited bytes are uploaded, and the **server** writes them to
   `<name>.annotated.pdf` beside the original, which is never modified.

Markup always targets `pdf_path` — the original — so marking up an
already-annotated brief updates the same sidecar instead of stacking
`.annotated.annotated.pdf`. The reader offers *Show original* and *Discard
markup*.

Markup is enabled on iPhone as well as iPad; it's the same system editor, and
there was no reason to switch it off on a smaller screen.

## Layout

`NavigationSplitView` gives the sidebar/detail layout an iPad wants and
collapses to push navigation on iPhone, so one structure serves both without
branching on size class.

## Offline

Briefs are cached to the Caches directory, keyed by briefing, path **and file
size** — a republished brief of a different length is refetched rather than
served stale. A brief you've opened once reads on a plane. *Clear cached
briefs* is in Settings, and signing out clears the cache too.

## Structure

```
Vista/
  VistaApp.swift            entry point
  Models/APIModels.swift    wire types
  Services/
    VistaClient.swift       actor wrapping the API
    AppModel.swift          @Observable app state
    Keychain.swift          session token storage
    BriefCache.swift        on-disk brief cache
  Views/
    RootView.swift          split-view navigation
    LoginView.swift         server address + credentials
    BriefsView.swift        brief list, sorting
    BriefReaderView.swift   PDFKit reader + markup flow
    MarkupView.swift        QuickLook markup editor
    PDFViewer.swift         PDFKit wrapper
    NotesView.swift         note list, swipe to delete
    NoteEditorView.swift    editor with debounced autosave
    SettingsView.swift      Ark connection, notes folder, briefings
    FolderPickerView.swift  workspace folder browser
```

The Xcode project uses **file-system synchronized groups** (Xcode 16+), so new
files under `Vista/` join the target automatically — nothing to add to
`project.pbxproj`.

## Known gaps

- Notes save last-write-wins, matching the web client: Ark's `PUT` is a
  whole-file write with no compare-and-swap.
- No offline *editing* queue. Writes need connectivity; reads of cached briefs
  don't.
- The app has no icon art yet — `AppIcon` is an empty 1024pt slot.
