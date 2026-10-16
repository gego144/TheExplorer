# TheExplorer

A native macOS file explorer with its own look (dark "Workbench" theme in the Jestr colors, dense rows), built because Finder makes simple things hard: telling folders from files at a glance, seeing how big a folder actually is, and finding out what's eating your disk.

Written in SwiftUI. Spotlight powers search across the whole Mac, and a parallel fts(3) scanner measures disk usage.

## Features

- **Browse with real sizes.** Every folder's total size is calculated in the background and drawn as a bar, so the heavy folders stand out. Columns for name, size, kind, modified, created and item count (sortable, and you can hide them).
- **Folders vs. files, unmistakably.** Folders get a medium-weight name, a chevron and a tinted "Folder" kind. You can also filter the view to just folders or just files.
- **One bar for path and search.** The command bar shows where you are as clickable chips. Press ⌘K (or ⌘F, or click it) and type to search, or start with `/` or `~` to jump to a path with folder completion (↑↓ to choose, ⇥ to complete). ⌘L opens it with the current path ready to edit.
- **Get around fast.** Back/forward history, ⌘↑ for the enclosing folder, arrow keys and type-to-select in every list.
- **Expand folders in place.** Click a folder's arrow (or press →) to show its contents indented below it, as in Finder's list view. Press ← or click again to collapse. Double-click still opens the folder.
- **Tabs.** Browser-style tabs, each with its own folder, history and search. ⌘T opens one and ⌘-double-click opens a folder in one. Drop files on a tab to move them into its folder, or hover a drag over a tab to switch to it. Tabs come back where you left them after you quit.
- **Search.**
  - *This Folder* walks the current folder and its subfolders, including hidden and unindexed files.
  - *Entire Mac* uses Spotlight, so it's instant but skips unindexed locations.
  - Results are ranked by relevance, with clutter like `Library`, `node_modules` and `.git` pushed down.
- **Storage breakdown.** Scan your home folder, the whole Mac, or any folder. Drill into a treemap and a ranked list with percentages, see the largest files, and compare against total disk usage. Moving something to the Trash updates the totals without a rescan.
- **Recents.** Works like Finder's Recents: every document you've opened, newest first, grouped into Today, Yesterday, Previous 7 Days, Previous 30 Days and then by month. Folders and apps are left out. Covers all time by default, and column headers re-sort the list.
- **New.** The newest files and folders in your home folder, by date created, modified or added, over the last 24 hours to 90 days. Grouped by day, updated live, with an option to hide clutter. Scrolling to the bottom keeps loading older items. At the end of a range, one click widens it.
- **Default file browser.** In Settings, choose TheExplorer for other apps' "Show in Finder" and "Reveal" buttons (the `NSFileViewer` preference). It applies right away: revealed items open in a tab of your front window with the items selected, and TheExplorer's own reveal command becomes "Show in Enclosing Folder". Settings also shows which app opens folders from other apps, the Dock and Spotlight. macOS 26 keeps that as Finder (Launch Services rejects changes, and drops a hand-written handler entry at login), so use Open With › TheExplorer from Finder's right-click menu instead. Finder still runs the desktop.
- **Settings (⌘,).** Choose the default file browser, the terminal "Open in Terminal" uses (Terminal, cmux, Ghostty, iTerm, Warp, or any other app). cmux gets a new workspace in the folder. Also set where new windows start, the default sort, folders first, hidden files, and New's default range and clutter filter.
- **Pinned.** Pin files or folders to the sidebar with ⌘D or by dropping them on the "Pinned" heading. Dropping onto a pinned folder (or any sidebar place) moves items into it.
- **Inspector.** Size, size on disk, item count, created, modified and last-opened dates, and the full path for whatever is selected.
- **Previews.** Selecting a document, image, PDF, video, audio or text/code file shows a live preview at the top of the inspector. Space opens Quick Look, and the arrow keys then step through every file in the list.
- **Zip archives.** Selecting a zip lists what's inside as a folder tree with sizes, without unpacking it (only the archive's table of contents is read, so even huge zips list instantly). Double-click a file inside to preview it, or drag files and folders out to unpack just those.
- **Drag and drop.** Drag items between tabs, windows, or from Finder. Drop onto empty space to put them in the folder you're viewing, onto a folder row to put them inside it, or onto a path bar segment to send them up the tree. Like Finder, it moves within a disk and copies across disks; hold ⌥ to copy. If an item with the same name already exists, both are kept ("name 2") and nothing is overwritten.
- **Right-click anywhere.** Right-click empty space in a folder to create a new folder or file (you're asked for the name), open that folder in Terminal, copy its path, or favorite it. Right-click an item for open, open in new tab, Quick Look, rename, copy path, Terminal and more.
- **The basics.** Quick Look (Space), drag and drop out of the app, Move to Trash, reveal in Finder, and eject for removable drives.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain)

## Build and run

```sh
make run        # build, install to /Applications, and open it
make install    # build and install without opening
make test       # run the test suite
make clean
```

`make app` runs `scripts/build-app.sh`, which builds with SwiftPM and wraps the binary in an app bundle in `build/`. A debug build (`CONFIG=debug ./scripts/build-app.sh`) goes to `build/debug/` instead, so it never replaces the copy you use. To work on the code in Xcode, run `open Package.swift`.

## Permissions and signing

macOS remembers privacy permissions (Desktop, Documents, Downloads, Full Disk Access…) per app, identified by its code signature. An ad-hoc signature changes on every build, which makes macOS ask for permissions again after every rebuild. To avoid that, the build script signs with a stable identity:

1. `SIGN_IDENTITY`, if you set it (for example an Apple Development certificate).
2. Otherwise, a self-signed certificate called **TheExplorer Local Signing**, if it's in your keychain.
3. Otherwise, ad-hoc, with a warning.

To create the local certificate on a new Mac:

```sh
WORK=$(mktemp -d) && cd "$WORK"
printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=TheExplorer Local Signing\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > cert.cnf
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "TheExplorer Local Signing" -out id.p12 -passout pass:temp
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
cd - && rm -rf "$WORK"
```

It shows as "not trusted" in Keychain Access. That's expected for a self-signed certificate and doesn't stop it signing. To remove it, delete it in Keychain Access.

Grant **Full Disk Access** (System Settings › Privacy & Security › Full Disk Access) so the storage scan can include protected folders like Mail and Messages. The Storage view has a button that opens the right pane.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New tab / Close tab | ⌘T / ⌘W |
| Next / previous tab, jump to tab | ⌃Tab / ⌃⇧Tab, ⌘1…⌘9 |
| Open folder in new tab | ⌥⌘↓ (or ⌘-double-click) |
| Search or jump to a path | ⌘K or ⌘F |
| Back / Forward / Enclosing folder | ⌘[ / ⌘] / ⌘↑ |
| Open selection | ⌘↓, Return, or double-click |
| Quick Look (then ↑/↓ to step through the list) | Space or ⌘Y |
| Find | ⌘F |
| Edit the current path | ⌘L or ⇧⌘G |
| Recents / New / Storage | ⇧⌘F / ⇧⌘E / ⇧⌘B |
| Home / Desktop / Documents / Downloads / Applications | ⇧⌘H / ⇧⌘D / ⇧⌘O / ⌥⌘L / ⇧⌘A |
| Pin or unpin in the sidebar | ⌘D |
| Show in enclosing folder / Reveal in Finder | ⌘R / ⌥⌘R |
| Copy path | ⌥⌘C |
| New folder / New file / Rename | ⇧⌘N / ⌥⌘N / ⇧⌘↩ |
| Open current folder in Terminal | ⌃⌘T |
| Move to Trash | ⌘⌫ |
| Sidebar / Inspector / Hidden files | ⌥⌘S / ⌘I / ⇧⌘. |
| Refresh | ⇧⌘R |

## Project layout

```
Sources/TheExplorer/
  App/        App entry point, menu commands, tabs and session restore, debug screenshots
  Model/      Per-window browser state, search, recents, storage
  Services/   Disk scanner, folder size cache, favorites, Spotlight wrapper, directory watcher
  Views/      SwiftUI views (folder table, sidebar, search, recents, storage and treemap, inspector)
  Util/       Formatting and icon caching
Resources/    Info.plist
scripts/      build-app.sh
```

## Debug screenshots

Debug builds can drive themselves through a scripted set of scenes and save a screenshot of the window after each one. This is handy for checking UI changes without clicking through by hand:

```sh
CONFIG=debug ./scripts/build-app.sh
open -g -n --env EXPLORER_SNAPSHOT_DIR=/tmp/shots --env EXPLORER_SNAPSHOT_QUIT=1 \
    --env "EXPLORER_SCENES=folder:~/Dev;newtab:~/Downloads;recents;search:swift;searchmac:swift;storage:~/Dev" \
    build/debug/TheExplorer.app
```

Scenes are separated by `;`. The available scenes are `folder:<path>`, `select:<path>`, `newtab:<path>`, `tab:<n>`, `omnibox:<text>`, `expand:<path>`, `recents`, `new`, `range:<days>` (0 for all time), `more` (load the next page), `search:<text>`, `searchmac:<text>`, `scope:mac|folder`, `create:folder|file`, `drop:<source>><folder>`, `storage[:<path>]`, `settings` (shows the Settings window), `reveal:<path>[,<path>…]` (sends the app the reveal event other apps' "Show in Finder" uses), `viewer:<bundle id>` (sets the file viewer and logs it back; pass the current one to change nothing) and `wait:<seconds>`.

Scenes can also drive the app with real input:
- `key:<combo>`: a key press such as `key:cmd+k`, `key:down` or `key:esc`.
- `type:<text>`: types the text into whatever has focus.
- `click:<row name>`, `dblclick:<row name>`, `cmdclick:<row name>`: clicks a row in the list.
- `chevron:<row name>`: clicks a folder's expand arrow.
- `scroll[:<points>]`: scrolls the list one step per frame and reports frame times, hitches, and the longest wait at the bottom for the next page. Leave out the distance to scroll until the list stops growing; negative distances scroll up.

The events go only to the app's own window (see `App/InputDriver.swift`), so they never touch your mouse or keyboard and need no permissions. Use these to test interactions themselves (focus, gestures, scrolling), not just the code behind them. Launch with `open -g` so the app never takes focus; running the binary directly can leave the app without a window. To run fully hidden and just read the log, add `-j` and `--env EXPLORER_NO_CAPTURE=1`.

### Measuring speed

Scripted runs also watch the main thread. After each scene the log reports how long the scene took to show something, plus the worst main-thread stall during it. Anything over 250ms is also logged on its own line as `[hang]`:

```
[snapshot] recents timing: first content 0.08s, worst main-thread stall 49ms, stalls>100ms 0 · …
```

Debug builds aren't optimized, so build with `SWIFT_FLAGS="-Xswiftc -O" CONFIG=debug ./scripts/build-app.sh` to get numbers that match the release app. A folder with tens of thousands of files makes a good stress test. The rule the code follows is that anything proportional to the number of files (listing, sorting, Spotlight results, folder sizes, path suggestions) runs off the main thread, or runs once and is cached, never per redraw.

## App icon

The icon is drawn in code. After changing `scripts/make-icon.swift`, regenerate it with:

```sh
swift scripts/make-icon.swift   # writes Resources/AppIcon.icns
```

## Tests

```sh
make test
```
