# Developing TheExplorer

How to build, test and work on TheExplorer. For using the app, see [GUIDE.md](GUIDE.md).

## Building

TheExplorer builds from source with SwiftPM. You need macOS 15 or later and Xcode 16 or later (Swift 6 toolchain).

```sh
make run        # build, install to /Applications, and open it
make install    # build and install without opening
make test       # run the test suite
make clean
```

`make app` runs `scripts/build-app.sh`, which builds with SwiftPM and wraps the binary in an app bundle in `build.noindex/` (the suffix keeps Spotlight from listing it). To work on the code in Xcode, run `open Package.swift`.

## Layout

```
Sources/TheExplorer/
  App/        App entry point, menu commands, tabs and session restore, debug scenes and input
  Model/      Per-window browser state, search, recents, storage, settings, actions
  Services/   Search index and fuzzy matcher, disk scanner, folder size cache, favorites, Spotlight wrapper (Recents), zip reader, S3 client and signer, Google sign-in and Drive client, directory watcher
  Views/      SwiftUI views (file list, sidebar, search, recents, storage and treemap, inspector, previews, settings)
  Util/       Formatting and icon caching
Resources/    Info.plist and app icon
scripts/      build-app.sh, make-icon.swift, mock-drive.py (a local stand-in for Google Drive)
Tests/        Swift Testing suites
docs/         Screenshots for the README and guide
```

A debug build (`CONFIG=debug ./scripts/build-app.sh`) goes to `build.noindex/debug/` with its own bundle identifier, so it never replaces the copy you use.

**Speed is a feature.** Anything proportional to the number of files (listing, sorting, search, Spotlight results, folder sizes, path suggestions) runs off the main thread, or runs once and is cached, never per redraw.

## Signing and permissions

macOS remembers privacy permissions (Desktop, Documents, Downloads, Full Disk Access…) per app, identified by its code signature. An ad-hoc signature changes on every build, which makes macOS ask for permissions again after every rebuild. The Keychain is stricter: for an app without a Team ID it trusts each build's exact hash, so the S3 and Google Drive secrets prompt again after every rebuild unless the app is signed with a certificate that has a Team ID. The build script signs with the steadiest identity it finds:

1. `SIGN_IDENTITY`, if you set it.
2. Otherwise, an **Apple Development** certificate. It's free: in Xcode, open Settings (⌘,) › Accounts, add your Apple Account, select your Personal Team, then Manage Certificates… › + › Apple Development. If `security find-identity -v -p codesigning` doesn't list it as valid, Apple's intermediate certificate is missing; add it with `curl -fsSLO https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer && security add-certificates AppleWWDRCAG3.cer`.
3. Otherwise, a self-signed certificate called **TheExplorer Local Signing**, if it's in your keychain. Privacy permissions stick with it, but Keychain access doesn't.
4. Otherwise, ad-hoc, with a warning.

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

## Scripted scenes and screenshots

Debug builds can drive themselves through a scripted set of scenes and save a screenshot of the window after each one, which is handy for checking UI changes without clicking through by hand:

```sh
CONFIG=debug ./scripts/build-app.sh
open -g -n --env EXPLORER_SNAPSHOT_DIR=/tmp/shots --env EXPLORER_SNAPSHOT_QUIT=1 \
    --env "EXPLORER_SCENES=folder:~/Dev;newtab:~/Downloads;recents;search:swift;searchmac:swift;storage:~/Dev" \
    build.noindex/debug/TheExplorer.app
```

Scenes are separated by `;`. The available scenes are `folder:<path>`, `select:<path>`, `newtab:<path>`, `tab:<n>`, `omnibox:<text>`, `expand:<path>`, `recents`, `new`, `range:<days>` (0 for all time), `more` (load the next page), `search:<text>`, `searchmac:<text>`, `scope:mac|folder`, `create:folder|file`, `drop:<source>><folder>`, `storage[:<path>]` (scans and logs how long it took), `layout:gallery|list` (shows the place as a gallery or list), `tilesize:<points>` (the gallery tile size), `scanstart:<path>` (starts a scan without waiting for it; `scanstop` then stops it and logs the CPU used in the second after), `rowcounts:<seconds>` (opens Recents unless New or Recents is showing, then logs each change in how many rows it shows), `drill:<name>` (opens a folder in Storage and logs what's inside), `settings[:actions|openwith|cloud]` (shows the Settings window, optionally on that tab), `openrule:<types>><bundle id>` (adds an Open With rule for the run, e.g. `openrule:png,jpg>com.apple.Preview`), `actioneditor` (shows the action editor; `type:` scenes after it go to the command field), `editortext` (logs the command field), `runs` (logs every action run's state and output), `stop` (stops the newest running action), `menu:<name>` (logs a menu bar menu's items), `s3:[bucket/prefix/]` (browses the first S3 connection), `transfers` (logs uploads and downloads), `showdownload` (does what a finished download's Show button does), `promise:<bucket/key>><folder>` (delivers an S3 item the way a drop on Finder asks for it, and logs what the drag carries; `promise:drive:<id>><folder>` does the same for a Drive file), `drive:[<id>/]` (browses the first Google account: My Drive, a folder by ID, or `~/`, `~shared/`, `~starred/` and `~drives/` for its lists), `drivesignin` (signs in the way Add Account does), `googleclient` (shows the Google client sheet), `share:<id>` (opens the Share sheet for a Drive item and logs who has access; `shareadd:<a@x,b@y>><role>[>quiet[>message]]`, `sharerole:<email>><role>`, `shareremove:<email>`, `shareaccess:restricted|anyone:<role>|domain:<name>:<role>` and `shareclose` then do what its controls do), `beginrename` (shows the rename prompt for the selection, as ⇧⌘↩ does), `theme:<system|dark|graphite|midnight|light>` (shows a theme for the run without saving it), `split` (splits the tab, or closes the split), `pane:1|2` (makes that side active), `back`, `bigpreview:<path>` (opens a Markdown, CSV, JSON or font file in the large preview; leave out the path to close it), `reveal:<path>[,<path>…]` (sends the app the reveal event other apps' "Show in Finder" uses), `viewer:<bundle id>` (sets the file viewer and logs it back; pass the current one to change nothing) `idle:<seconds>` (sits still and logs the CPU the app used meanwhile), `foldersize:<path>` (logs a folder's measured size), `pressed` (logs the rows the last press would drag) and `wait:<seconds>`.

Scenes can also drive the app with real input:

- `key:<combo>`: a key press such as `key:cmd+k`, `key:down`, `key:f5` or `key:esc`.
- `type:<text>`: types the text into whatever has focus.
- `click:<row name>`, `dblclick:<row name>`, `cmdclick:<row name>`: clicks a row in the list. Rows inside a zip in the inspector are named `debug-rows/<path in the zip>`, and rows of a JSON preview `debug-rows/json-<node>`, numbering every value in the file in order from 0.
- `clickat:<x>,<y>[,<clicks>]`: clicks a point in the window, in points from its top left (for things that aren't rows, like links in a preview). Add a click count for a double-click.
- `dragrow:<name>:<dx>`: presses in the middle of a named element and drags it sideways by `dx` points, such as `dragrow:split-divider:-200`, and logs where it ended up.
- `chevron:<row name>`: clicks a folder's expand arrow.
- `rclick:<row name>[:<submenu>]`: right-clicks a row and logs its context menu (or one submenu, such as `Open With`), then closes it.
- `scroll[:<points>]`: scrolls the list one step per frame and reports frame times, hitches, and the longest wait at the bottom for the next page. Leave out the distance to scroll until the list stops growing; negative distances scroll up.

The events go only to the app's own window (see `App/InputDriver.swift`), so they never touch your mouse or keyboard and need no permissions. Launch with `open -g` so the app never takes focus; running the binary directly can leave the app without a window. To run fully hidden and just read the log, add `-j` and `--env EXPLORER_NO_CAPTURE=1`. Don't double-click file rows in scenes: opening a file launches its app.

**README screenshots** come from demo mode. `EXPLORER_DEMO=1` shows only the startup disk in the sidebar and puts the window on a Retina screen, so captures are sharp. `EXPLORER_DEMO_PINS` sets the pinned folders (paths separated by `;`), and demo pins are never saved over your own. Point the scenes at a demo folder rather than your own files. `EXPLORER_ACTIONS_FILE`, `EXPLORER_S3_FILE`, `EXPLORER_DRIVE_FILE`, `EXPLORER_VISITS_FILE` and `EXPLORER_INDEX_FILE` give a run its own actions, S3 connections, Google accounts, recent folders and search index, so tests never touch yours. Demo mode also shows the command bar's dropdowns even though the app is in the background. `drop:`, `trash:` and `rename:` accept `s3:bucket/key` for S3 items (`drop:` only) and `drive:<id>` for Drive items. Scripted runs never open files or links in other apps; they log `open <path>` instead.

## Measuring speed

Scripted runs also watch the main thread. After each scene the log reports how long the scene took to show something, plus the worst main-thread stall during it. Anything over 250ms is also logged on its own line as `[hang]`:

```
[snapshot] recents timing: first content 0.08s, worst main-thread stall 49ms, stalls>100ms 0 · …
```

Debug builds aren't optimized, so build with `SWIFT_FLAGS="-Xswiftc -O" CONFIG=debug ./scripts/build-app.sh` to get numbers that match the release app. A folder with tens of thousands of files makes a good stress test.

## App icon

The icon is drawn in code. After changing `scripts/make-icon.swift`, regenerate it with:

```sh
swift scripts/make-icon.swift   # writes Resources/AppIcon.icns
sips -s format png -z 256 256 Resources/AppIcon.icns --out docs/icon.png
```

## Testing S3 without AWS

The S3 client's integration tests run against any S3-compatible server; they're skipped unless one is set:

```sh
python3 -m venv /tmp/motoenv && /tmp/motoenv/bin/pip install "moto[server]"
/tmp/motoenv/bin/moto_server -p 5055 &
EXPLORER_S3_TEST_ENDPOINT=http://127.0.0.1:5055 swift test --filter S3
```

## Testing Google Drive without Google

`scripts/mock-drive.py` stands in for Google's sign-in and the parts of the Drive API the app uses, with a small seeded Drive. Nothing leaves your Mac. The client's integration tests run against it, and are skipped otherwise:

```sh
python3 scripts/mock-drive.py 5056 &
EXPLORER_DRIVE_ENDPOINT=http://127.0.0.1:5056 swift test --filter Drive
```

Debug builds talk to it too. Give the run an accounts file with a client and an account, and a sign-in token, so it never reads your Keychain:

```sh
echo '{"clientID": "test.apps.googleusercontent.com", "accounts": [{"id": "6B1C1E8A-3E0B-4C3D-9C1A-111111111111", "email": "test@example.com", "name": "Test User"}]}' > /tmp/drive.json
open -g -n --env EXPLORER_DRIVE_ENDPOINT=http://127.0.0.1:5056 --env EXPLORER_DRIVE_FILE=/tmp/drive.json \
    --env EXPLORER_DRIVE_TOKEN=refresh-test --env EXPLORER_SNAPSHOT_DIR=/tmp/shots --env EXPLORER_SNAPSHOT_QUIT=1 \
    --env "EXPLORER_SCENES=drive:;dblclick:Projects;key:cmd+k;type:milk;wait:1" build.noindex/debug/TheExplorer.app
```

The mock keeps what you change until it's restarted. `EXPLORER_DRIVE_TOKEN=revoked` shows what a signed-out account looks like.

## Contributing

Issues and pull requests are welcome. Before opening a PR, run `make test`. For UI changes, check them with the scripted scenes, and refresh the screenshots in `docs/screenshots/` if the look changed.
