<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="TheExplorer icon">

# TheExplorer

**A fast, native file explorer for macOS.**<br>
Real folder sizes, search that forgives typos, previews of everything, git status and S3, in a dense dark UI built for the keyboard.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-111111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-2E2E2E)

[Features](#features) · [Install](#install) · [Guide](GUIDE.md) · [Development](DEVELOPMENT.md)

</div>

## Features

### Git status, right in the list

In a repository, changed files get a letter (**M** modified, **U** untracked…) and folders get a dot when something inside changed. The path bar shows the branch and how many files changed, and code previews live in the inspector.

<img src="docs/screenshots/hero.png" alt="A git project expanded inline, with change badges, the branch chip and a code preview" width="100%">

### Real folder sizes

Every folder's total size is worked out in the background and drawn as a bar, so the heavy ones stand out. Click a folder's arrow to expand it in place.

<img src="docs/screenshots/folder-sizes.png" alt="A folder listing with size bars and type chips" width="100%">

### Search that forgives typos

TheExplorer keeps its own live index instead of using Spotlight, so results update in milliseconds as you type. Matching is fuzzy and forgives slips: here `serch` finds the Search files.

<img src="docs/screenshots/search.png" alt="Search results for the misspelled query serch" width="100%">

### Recent folders and path jumping

Open ⌘K without typing to see the folders you use most, or start with `~` or `/` to jump to a path with completion. Folders you visit often rank first everywhere.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/recent-folders.png" alt="Recent folders in the command bar"></td>
    <td width="50%"><img src="docs/screenshots/path-bar.png" alt="Path completion in the command bar"></td>
  </tr>
</table>

### Previews with the details

Select a file to preview it, with what's inside: dimensions and color for images, length, resolution and codec for video, and pages, lines or fonts for everything else.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/preview.png" alt="An image previewed with its dimensions and color profile"></td>
    <td width="50%"><img src="docs/screenshots/video.png" alt="A video previewed with its length, resolution and codec"></td>
  </tr>
</table>

### Zips without unpacking

Selecting a zip lists everything inside as a tree with sizes, instantly, even for huge archives. Drag files out to unpack just those.

<img src="docs/screenshots/zip.png" alt="A zip archive's contents listed in the inspector" width="100%">

### Storage map

Scan any folder or the whole Mac and drill into a treemap to see what's using your disk. Moving something to the Trash updates the totals without a rescan.

<img src="docs/screenshots/storage.png" alt="The storage treemap and ranked folder list" width="100%">

### S3, like a folder

Browse your S3 buckets in the same list as your files. Drop files on a bucket to upload, and drag items to Finder or the desktop to download.

<img src="docs/screenshots/s3.png" alt="Browsing an S3 bucket" width="100%">

### Actions and Open With

Turn shell commands you run on files, like an ffmpeg conversion, into right-click actions. Choose which app opens each file type, from Settings or the right-click menu.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/actions.png" alt="Actions in Settings"></td>
    <td width="50%"><img src="docs/screenshots/open-with.png" alt="Default apps for file types in Settings"></td>
  </tr>
</table>

### And the basics, done right

Tabs, cut, copy and paste that work with Finder, ⌘Z undo across tabs and windows, drag and drop, and a keyboard shortcut for everything. The **[guide](GUIDE.md)** covers every feature in detail.

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
