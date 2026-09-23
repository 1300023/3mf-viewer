<p align="center">
  <img src="Packaging/AppIcon.png" width="128" alt="3MF Viewer icon">
</p>

<h1 align="center">3MF Viewer</h1>

<p align="center">
  A fast, native macOS browser for 3D-printing models in <code>.3mf</code> format.<br>
  Pick a folder and flip through your models with thumbnails and an interactive 3D preview.
</p>

<p align="center"><a href="README.ru.md">Русская версия</a></p>

---

## Features

- **Folder library.** Choose a folder (or drag it onto the window / Dock icon). Every `.3mf` in it is listed, optionally including subfolders, with search and sorting by name, date or size. The list updates automatically when files are added or removed.
- **Thumbnails.** Uses the preview image that Bambu Studio, OrcaSlicer, PrusaSlicer, Cura etc. embed in the file. If there is none, the model is rendered off-screen. Thumbnails are cached on disk.
- **Interactive 3D preview** (SceneKit): orbit, zoom, pan, reset view (⌘0), wireframe, build-plate grid.
- **Colours from the slicer project**: filament colours from Bambu Studio / OrcaSlicer (`project_settings.config`) and PrusaSlicer (`Slic3r_PE.config`), per-object / per-part extruders, multi-material painting (`paint_color`, `mmu_segmentation`), and 3MF material colours (`basematerials`, `colorgroup`).
- **Correct geometry**: components, the production extension (objects stored in `3D/Objects/*.model`), transforms, units; modifiers / negative volumes are hidden.
- **Info panel**: dimensions in mm, object and triangle counts, filaments, title, designer, application.
- **Quick Look in Finder**: press Space on a `.3mf` to rotate the model in 3D right in the Quick Look window, and see model previews as file icons.
- **Open With…** — send the model to Bambu Studio, PrusaSlicer, OrcaSlicer or any other app; Show in Finder, Copy Path.
- English and Russian UI. No third-party dependencies.

## Requirements

macOS 13 Ventura or newer, Apple Silicon or Intel.

## Install

Download `3MF-Viewer-x.y.z.zip` from [Releases](../../releases), unzip it and move **3MF Viewer.app** to *Applications*.

Launch the app once — this registers the Quick Look extensions. If the Space-bar preview does not appear, check *System Settings → General → Login Items & Extensions → Quick Look* and make sure **3MF Viewer** is enabled.

The app is not notarized by Apple, so the first launch is blocked by Gatekeeper. Either right-click the app → **Open**, or allow it in *System Settings → Privacy & Security → Open Anyway*, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/3MF Viewer.app"
```

## Build from source

You need Xcode 15 or newer (or the Xcode command-line tools).

```sh
git clone https://github.com/1300023/3mf-viewer.git
cd 3mf-viewer

swift run                       # quick start from the terminal
./scripts/build-app.sh          # build "build/3MF Viewer.app"
./scripts/build-app.sh --install    # build, copy to /Applications, register Quick Look
UNIVERSAL=1 ./scripts/build-app.sh --zip   # universal binary + zip for a release
swift test                      # unit tests for the parser (needs Xcode)
```

To work in Xcode, just open `Package.swift` (File → Open…) and run the `ThreeMFViewer` scheme.

## Project layout

```
Sources/ThreeMFKit/        3MF parsing, no UI and no dependencies
  ZipArchive.swift           minimal ZIP/ZIP64 reader (Apple Compression framework)
  XMLScanner.swift           fast byte-level XML tokenizer (millions of vertices)
  ModelPartParser.swift      3MF core + materials + production extension
  SlicerConfig.swift         Bambu Studio / OrcaSlicer / PrusaSlicer project data
  PaintDecoder.swift         multi-material painting decoder
  ThreeMFReader.swift        public API: load(url:), thumbnailData(url:)
Sources/ThreeMFRendering/  SceneKit scene + off-screen renderer (shared)
Sources/ThreeMFViewer/     the SwiftUI app
  Library/                   folder scanning, thumbnail cache
  Rendering/                 SwiftUI wrapper around SCNView
  Views/                     sidebar, 3D view, info panel
Sources/Extensions/        Quick Look preview (Space) and thumbnail (Finder icons) extensions
Packaging/                 Info.plists, entitlements, icon, localizations for the bundles
scripts/                   build-app.sh, icon and test-fixture generators
Tests/ThreeMFKitTests/     parser tests with small .3mf fixtures
```

## Releasing

Push a tag like `v1.0.0` — the GitHub Actions workflow runs the tests, builds a universal `.app`, zips it and attaches it to a GitHub Release.

For a signed and notarized build set `SIGN_IDENTITY="Developer ID Application: …"` when running `build-app.sh` and notarize the zip with `xcrun notarytool`.

## Roadmap ideas

- Plate selector for multi-plate Bambu projects
- Grid (gallery) view, tags and favourites

## License

[MIT](LICENSE)
