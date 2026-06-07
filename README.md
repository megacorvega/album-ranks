# Album Ranks

This repo is set up as a simple static GitHub Pages site.

## Edit albums

Add or update entries in [albums.txt](albums.txt) using this format:

```txt
artist: Artist Name
album: Album Title
score: 9.4
art: https://example.com/cover.jpg
review: A short review goes here.
```

Leave one blank line between albums.

## One-command sync

For the normal workflow, run:

```powershell
.\scripts\sync-albums.ps1
```

The script will prompt you with:

1. `Get all art`
2. `Get missing art`

Useful switches:

- `-Mode all` fetches and caches art for every entry.
- `-Mode missing` only fills blank `art:` fields.

The script looks up the best MusicBrainz release for each album, downloads the cover into `images/covers/`, and writes the local image path back into [albums.txt](albums.txt). The site reads `albums.txt` directly, so no rebake step is needed.

## Files

- [index.html](index.html) renders the page.
- [app.js](app.js) reads and parses [albums.txt](albums.txt) from the repo root.
- [styles.css](styles.css) handles the design.
- [scripts/sync-albums.ps1](scripts/sync-albums.ps1) finds MusicBrainz cover art, caches it locally, and updates `albums.txt`.

## Publish on GitHub Pages

1. Open the repo `Settings` on GitHub.
2. Go to `Pages`.
3. Set `Source` to `Deploy from a branch`.
4. Choose your default branch and `/ (root)`.
5. Save.
