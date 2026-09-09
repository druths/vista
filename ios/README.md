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
**Vista server address** is the first field on the sign-in screen. The session
token goes to the **Keychain**
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, out of
backups and iCloud Keychain).

### Recent sign-ins

Below the form, a **Recent** list remembers previous sign-ins so moving between
Vista backends doesn't mean retyping a server, an email, and a password
(modelled on Relay's saved-accounts list).

- An entry is recorded only **after a sign-in succeeds**, so a typo never lands
  in the history.
- Accounts are keyed by email **and** server, so the same person on two
  backends is two entries — which is what makes switching useful.
- Tapping an entry **fills the form** (including the password) rather than
  signing in outright, so you can see which account you're about to use. Then
  press Sign in.
- Editing the email or server afterwards drops the checkmark, since it's no
  longer the account you picked.
- The ✕ on a row forgets it, removing its Keychain password too.
- Signing out deliberately **keeps** the list — that's how you get back here to
  switch. Cached briefs are cleared, because the next server's briefs are not
  these.
- On a cold start the most recent account is pre-filled, so signing back into
  the server you were just using is one tap.

The list lives in `UserDefaults`; each password is in the Keychain under the
account's id, in a separate keychain service from the session token so clearing
a session never touches saved passwords. Ordering is by last use.

This is iOS-only. The web client has no server field to switch — its API base
is a build-time `VITE_API_BASE` — which is the same reason Relay's web frontend
has no saved-accounts list either.

### App Transport Security

A self-hosted Vista server is usually plain HTTP, which ATS blocks. Because the
address is typed in at sign-in, it can't be known at build time and so can't be
listed under `NSExceptionDomains`. `Vista-Info.plist` therefore sets
`NSAllowsArbitraryLoads`.

`NSAllowsLocalNetworking` — the narrower key, and the first thing tried here —
is not sufficient. ATS treats only single-label hostnames, `.local` names and
link-local addresses as "local". A Tailscale peer is neither: `100.64.0.0/10`
is carrier-grade NAT space, and a MagicDNS name like `host.tailnet.ts.net` (or
`host.t.internal` on Headscale) is an ordinary dotted name. Connections to
those were blocked outright.

The two keys must not both be present. Apple documents `NSAllowsArbitraryLoads`
as **ignored** on iOS 10+ whenever `NSAllowsLocalNetworking` appears alongside
it, so leaving the old key in place would have silently undone the fix.

What actually protects the traffic is the transport underneath: over Tailscale,
Vista rides an authenticated, encrypted WireGuard tunnel, so "cleartext" HTTP
isn't cleartext on the wire. If you ever expose Vista outside a private tunnel,
put TLS in front of it rather than relying on this.

Tailscale SaaS can issue a real certificate for a `*.ts.net` MagicDNS name
(`tailscale cert` + `tailscale serve`), which would let ATS be re-enabled
outright. That path isn't available on a Headscale tailnet with a custom
MagicDNS suffix, which is why it isn't used here.

iOS also prompts once for local network access when reaching a LAN address;
`NSLocalNetworkUsageDescription` supplies that prompt's text. A Tailscale
connection goes over the tunnel interface and generally doesn't trigger it.

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
    Keychain.swift          session token + saved-account passwords
    AccountStore.swift      recent sign-ins across backends
    BriefCache.swift        on-disk brief cache
  Views/
    RootView.swift          split-view navigation
    LoginView.swift         server address, credentials, recent sign-ins
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
