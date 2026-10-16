<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="TheExplorer icon">

# TheExplorer

**A fast, native file explorer for macOS.**<br>
Real folder sizes, search that forgives typos, previews of everything, git status and S3, in a dense dark UI built for the keyboard.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-2E2E2E)

[Guide](GUIDE.md) · [Install](#install) · [Development](DEVELOPMENT.md)

<br>

<img src="docs/screenshots/hero.png" alt="TheExplorer showing a git project expanded inline, with change badges and a live code preview" width="100%">

</div>

## Why

Finder makes simple things hard: telling folders from files at a glance, seeing how big a folder actually is, finding a file you half remember the name of, and finding out what's eating your disk. TheExplorer is a replacement built around those, tuned to stay fast on folders with tens of thousands of files.

## Highlights

- **Real folder sizes.** Every folder's total size, worked out in the background and drawn as a bar.
- **Search like a launcher.** Its own live index instead of Spotlight, with results in milliseconds as you type. Fuzzy matching forgives typos and ranks the folders you visit most first.
- **One bar for everything.** ⌘K to search, type a path to jump, or pick from your recent folders.
- **Previews with details.** Code, images, PDFs, video and audio, with dimensions, durations and codecs. Browse zips without unpacking them.
- **Git status.** Changed files get a letter, and the path bar shows the branch.
- **Storage map.** A treemap of what's using your disk.
- **S3 like a folder.** Browse buckets in the same list, drop to upload, and drag to Finder to download.
- **Actions.** Turn shell commands, like ffmpeg conversions, into right-click actions.
- **The basics, done right.** Tabs, cut, copy and paste with Finder, undo across tabs, Open With and default apps per file type, and keyboard shortcuts for everything.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/search.png" alt="Search results for a misspelled query"></td>
    <td width="50%"><img src="docs/screenshots/recent-folders.png" alt="Recent folders in the command bar"></td>
  </tr>
  <tr>
    <td align="center"><sub>Search that forgives typos</sub></td>
    <td align="center"><sub>Your recent folders, one keystroke away</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/screenshots/video.png" alt="A video previewed with its length, resolution and codec"></td>
    <td width="50%"><img src="docs/screenshots/storage.png" alt="The storage treemap"></td>
  </tr>
  <tr>
    <td align="center"><sub>Previews with what's inside</sub></td>
    <td align="center"><sub>See what's eating your disk</sub></td>
  </tr>
</table>

Everything else, with screenshots and the full list of shortcuts, is in the **[guide](GUIDE.md)**.

## Install

TheExplorer builds from source. You need macOS 15 or later and Xcode 16 or later.

```sh
git clone https://github.com/gego144/TheExplorer.git
cd TheExplorer
make run        # build, install to /Applications, and open it
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for the other build targets, signing, tests and the scripted UI scenes.

## License

No license has been chosen yet, so all rights are reserved for now.
