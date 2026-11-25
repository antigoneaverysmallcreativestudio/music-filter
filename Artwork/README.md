# Artwork sources

This folder contains the artwork used by the current application. It is kept
separate from `Resources`, which contains only files loaded by the app at runtime.
Historical previews, comparisons and abandoned icon variants are not included.

## Application icon

- `AppIcon/music.hand4.svg` is the editable drawing for the application icon.
- `AppIcon/music.hand4.pdf` is the trusted vector PDF input used by
  `Scripts/make-icon.swift` to create `Resources/AppIcon.icns`.

To rebuild the application icon from that PDF:

```sh
swift Scripts/make-icon.swift
```

If you edit the SVG, export it to PDF from your vector editor and replace the
PDF input before rebuilding. SVG-to-PDF conversion is not automated by this
project. Preserve the drawing's proportions and transparency when exporting.
Use only artwork inputs you trust.

## Menu icons

- `MenuIcons/music.hand7.svg` is the editable hand-and-note drawing for the
  menu-bar icon. Its runtime file is `Resources/MenuBarIcons/music.hand7.pdf`.
  After editing the SVG, export the matching PDF from your vector editor; this
  conversion is not automated.
- `MenuIcons/exclude-song.svg` and `MenuIcons/exclude-artist.svg` are the editable
  minus-badge icons. Rebuild their runtime PDFs with
  `python3 Scripts/make-exclusion-icons.py`.

The album icon is drawn by the app using a rounded square and the native
single-person SF Symbol. It does not need a separate album artwork file.

The runtime resource set contains six files: `AppIcon.icns`, the three menu PDFs
above, and the English and French `InfoPlist.strings` files. This source artwork
folder is not copied into the application bundle.

See [third-party notices](../THIRD_PARTY_NOTICES.md) for the distinction between
the project's MIT-licensed code and the terms applying to Apple resources.
