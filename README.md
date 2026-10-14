# TheExplorer

A native macOS file explorer, built because Finder makes simple things hard: telling folders from files at a glance, seeing how big a folder actually is, and finding out what's eating your disk.

Written in SwiftUI. Spotlight powers search across the whole Mac, and a parallel fts(3) scanner measures disk usage.

## Features

- **Browse with real sizes.** Every folder's total size is calculated in the background and drawn as a bar, so the heavy folders stand out. Columns for name, size, kind, modified, created and item count (sortable, and you can hide them).
- **Folders vs. files, unmistakably.** Folders get a medium-weight name, a chevron and a tinted "Folder" kind. You can also filter the view to just folders or just files.
- **Get around fast.** Clickable breadcrumb path bar (⌘L to type a path, `~` works), back/forward history, and ⌘↑ for the enclosing folder.
- **Tabs.** Native macOS tabs, each with its own folder, history and search. ⌘T opens a new tab, and ⌘-double-click opens a folder in one. Tabs come back where you left them after you quit.
- **Search.**
  - *This Folder* walks the current folder and its subfolders, including hidden and unindexed files.
  - *Entire Mac* uses Spotlight, so it's instant but skips unindexed locations.
  - Results are ranked by relevance, with clutter like `Library`, `node_modules` and `.git` pushed down.
- **Storage breakdown.** Scan your home folder, the whole Mac, or any folder. Drill into a treemap and a ranked list with percentages, see the largest files, and compare against total disk usage. Moving something to the Trash updates the totals without a rescan.
- **Recents.** The newest files and folders in your home folder, by date created, modified or added, over the last 24 hours to 90 days. Grouped by day, updated live, with an option to hide clutter.
- **Favorites.** Pin files or folders to the sidebar with ⌘D or by dragging them in, and drag to reorder.
- **Inspector.** Size, size on disk, item count, created, modified and last-opened dates, and the full path for whatever is selected.
- **The basics.** Quick Look (Space), drag and drop out of the app, rename, new folder, Move to Trash, copy path, reveal in Finder, open in Terminal, and eject for removable drives.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain)

## Build and run

```sh
make run        # build a release .app into build/ and open it
make install    # copy it to /Applications
make clean
```

`make app` runs `scripts/build-app.sh`, which builds with SwiftPM and wraps the binary in an app bundle. Set `CONFIG=debug` for a debug build. To work on the code in Xcode, run `open Package.swift`.

## Permissions

- **Full Disk Access.** Without it, protected folders (Mail, Messages, other apps' data) are skipped and storage totals come out low. Grant it in System Settings › Privacy & Security › Full Disk Access; the Storage view has a button that takes you there.
- **Code signing.** By default the app is ad-hoc signed. macOS ties privacy permissions to the signature, so every rebuild loses Full Disk Access. To keep it, build with a stable identity:

  ```sh
  SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make install
  ```

  You can list your identities with `security find-identity -v -p codesigning`.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New tab / Open folder in new tab | ⌘T / ⌥⌘↓ (or ⌘-double-click) |
| Back / Forward / Enclosing folder | ⌘[ / ⌘] / ⌘↑ |
| Open selection | ⌘↓, Return, or double-click |
| Quick Look | Space or ⌘Y |
| Find | ⌘F |
| Go to path | ⌘L or ⇧⌘G |
| Recents / Storage | ⇧⌘F / ⇧⌘B |
| Home / Desktop / Documents / Downloads / Applications | ⇧⌘H / ⇧⌘D / ⇧⌘O / ⌥⌘L / ⇧⌘A |
| Add to or remove from Favorites | ⌘D |
| Show in enclosing folder / Reveal in Finder | ⌘R / ⌥⌘R |
| Copy path | ⌥⌘C |
| New folder / Rename | ⇧⌘N / ⇧⌘↩ |
| Move to Trash | ⌘⌫ |
| Inspector / Hidden files | ⌘I / ⇧⌘. |
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
open -n --env EXPLORER_SNAPSHOT_DIR=/tmp/shots --env EXPLORER_SNAPSHOT_QUIT=1 \
    --env "EXPLORER_SCENES=folder:~/Dev;newtab:~/Downloads;recents;search:swift;searchmac:swift;storage:~/Dev" \
    build/TheExplorer.app
```

Scenes are separated by `;`. The available scenes are `folder:<path>`, `select:<path>`, `newtab:<path>`, `plus`, `recents`, `search:<text>`, `searchmac:<text>`, `scope:mac|folder`, `storage[:<path>]` and `wait:<seconds>`. Launch with `open`; running the binary directly can leave the app without a window.
