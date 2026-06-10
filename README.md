# Album Ranks

This repo is set up as a simple static GitHub Pages site.

## Edit albums

Add or update entries in [albums.txt](albums.txt) using this format:

```txt
artist: Artist Name
album: Album Title
year: 2013
score: 9.4
original_score: 8.7
art: https://example.com/cover.jpg
review: A short review goes here.
```

Leave one blank line between albums.

`score` is the current comparison-derived score used by the site. Pairwise-ranked albums are scaled from `10.0` down to `5.0`. `original_score` preserves your older/manual score when pairwise ranking takes over.
`year` is optional, but when present the site can filter by exact release year or release decade.

## One-command sync

For the normal workflow, run:

```powershell
.\scripts\sync-albums.ps1
```

The script will prompt you with:

1. `Get all art`
2. `Get missing art`
3. `Refresh cached data`

Useful switches:

- `-Mode all` fetches and caches art for every entry.
- `-Mode missing` only fills blank `art:` fields.
- `-Mode refresh` re-checks MusicBrainz for each album, updates `year:` when needed, and refreshes local art when the matched release has changed.

The script looks up the best MusicBrainz release group for each album, chooses the best matching release edition from that group, downloads the cover into `images/covers/`, and writes the local image path plus release `year:` back into [albums.txt](albums.txt) when available. The site reads `albums.txt` directly, so no rebake step is needed.

If you want to force a specific release, you can optionally add an `mbid:` field:

```txt
artist: Grizzly Bear
album: Shields
year: 2012
score: 9.9
mbid: b0b64ca6-5bc7-4ced-a6a0-7ca8563d36ea
art: images/covers/grizzly-bear-shields-b0b64ca6-5bc7-4ced-a6a0-7ca8563d36ea.jpg
review: ...
```

## Files

- [index.html](index.html) renders the page.
- [app.js](app.js) reads and parses [albums.txt](albums.txt) from the repo root.
- [styles.css](styles.css) handles the design.
- [scripts/rank-albums.ps1](scripts/rank-albums.ps1) runs interactive pairwise ranking and rewrites `score:` while preserving `original_score:`.
- [scripts/sync-albums.ps1](scripts/sync-albums.ps1) finds MusicBrainz cover art, caches it locally, and updates `albums.txt`.

## Pairwise ranking

To assign final ranks with a Beli-style comparison flow, run:

```powershell
.\scripts\rank-albums.ps1
```

The script:
- picks a random album, preferring albums that do not yet have an `original_score:`
- compares it against already ranked albums
- asks whether the target is better or worse
- inserts it into the ranked order
- recalculates comparison-derived `score:` values across the ranked set on a `10.0` to `5.0` scale
- preserves the older/manual value as `original_score:`

To rescale already ranked albums without doing an interactive comparison pass, run:

```powershell
.\scripts\rank-albums.ps1 -RescaleOnly
```

## Publish on GitHub Pages

1. Open the repo `Settings` on GitHub.
2. Go to `Pages`.
3. Set `Source` to `Deploy from a branch`.
4. Choose your default branch and `/ (root)`.
5. Save.
