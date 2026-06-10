param(
  [string]$SourcePath = "albums.txt",
  [string]$ImageDirectory = "images\covers",
  [int]$DelayMs = 1100,
  [int]$ArtSize = 500,
  [ValidateSet("all", "missing", "refresh", "sort")]
  [string]$Mode,
  [ValidateSet("artist", "album", "score")]
  [string]$SortBy
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-ResolvedPath([string]$PathValue) {
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return $PathValue
  }

  return Join-Path -Path $RepoRoot -ChildPath $PathValue
}

function Get-ModeFromPrompt() {
  while ($true) {
    Write-Host ""
    Write-Host "Choose an art sync mode:"
    Write-Host "1. Get all art"
    Write-Host "2. Get missing art"
    Write-Host "3. Refresh cached data"
    Write-Host "4. Sort albums"
    $selection = (Read-Host "Enter 1, 2, 3, or 4").Trim()

    switch ($selection) {
      "1" { return "all" }
      "2" { return "missing" }
      "3" { return "refresh" }
      "4" { return "sort" }
      default { Write-Host "Please enter 1, 2, 3, or 4." }
    }
  }
}

function Get-SortFieldFromPrompt() {
  while ($true) {
    Write-Host ""
    Write-Host "Sort albums by:"
    Write-Host "1. artist"
    Write-Host "2. album"
    Write-Host "3. score"
    $selection = (Read-Host "Enter 1, 2, or 3").Trim()

    switch ($selection) {
      "1" { return "artist" }
      "2" { return "album" }
      "3" { return "score" }
      default { Write-Host "Please enter 1, 2, or 3." }
    }
  }
}

function Parse-AlbumEntries([string]$SourceText) {
  return $SourceText -split "\r?\n\s*\r?\n+" | Where-Object { $_.Trim() -ne "" }
}

function Convert-EntryToMap([string]$EntryText) {
  $map = [ordered]@{}

  foreach ($line in ($EntryText -split "\r?\n")) {
    $separatorIndex = $line.IndexOf(":")

    if ($separatorIndex -lt 0) {
      continue
    }

    $key = $line.Substring(0, $separatorIndex).Trim().ToLowerInvariant()
    $value = $line.Substring($separatorIndex + 1).Trim()
    $map[$key] = $value
  }

  return $map
}

function Build-EntryText([System.Collections.IDictionary]$EntryMap) {
  $orderedKeys = @("artist", "album", "year", "score", "original_score", "mbid", "art", "review")
  $builder = New-Object System.Text.StringBuilder

  foreach ($key in $orderedKeys) {
    if ($EntryMap.Contains($key)) {
      [void]$builder.AppendLine("${key}: $($EntryMap[$key])")
    }
  }

  foreach ($key in $EntryMap.Keys) {
    if ($orderedKeys -notcontains $key) {
      [void]$builder.AppendLine("${key}: $($EntryMap[$key])")
    }
  }

  return $builder.ToString().TrimEnd("`r", "`n")
}

function Escape-MusicBrainzQueryValue([string]$Value) {
  return ($Value -replace '\\', '\\\\' -replace '"', '\"').Trim()
}

function Get-PrimaryAlbumTitle([string]$Album) {
  $stripped = ($Album -replace '\s*\([^)]*\)', '').Trim()

  if ([string]::IsNullOrWhiteSpace($stripped)) {
    return $Album
  }

  return $stripped
}

function Invoke-MusicBrainzRequest([string]$Url) {
  $headers = @{
    "User-Agent" = "album-ranks/1.0 (https://github.com/)"
    "Accept" = "application/json"
  }

  $attempt = 0

  while ($true) {
    try {
      return Invoke-RestMethod -Uri $Url -Headers $headers -Method Get
    } catch {
      $attempt += 1
      $statusCode = $null

      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }

      if ($attempt -ge 3 -or ($statusCode -notin @(429, 500, 502, 503, 504))) {
        throw
      }

      Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
    }
  }
}

function Find-BestReleaseGroup([string]$Artist, [string]$Album) {
  $escapedArtist = Escape-MusicBrainzQueryValue $Artist
  $escapedAlbum = Escape-MusicBrainzQueryValue $Album
  $query = 'artist:"{0}" AND releasegroup:"{1}"' -f $escapedArtist, $escapedAlbum
  $encodedQuery = [System.Uri]::EscapeDataString($query)
  $url = "https://musicbrainz.org/ws/2/release-group/?query=$encodedQuery&fmt=json&limit=10"
  $response = Invoke-MusicBrainzRequest $url

  if (-not $response.'release-groups') {
    return $null
  }

  $ranked = $response.'release-groups' | Sort-Object `
    @{ Expression = { if ($_.title -eq $Album) { 0 } else { 1 } } }, `
    @{ Expression = { if ($_.'primary-type' -eq "Album") { 0 } else { 1 } } }, `
    @{ Expression = { -1 * [int]($_.score) } }, `
    @{ Expression = { if ($_.'first-release-date') { $_.'first-release-date' } else { "9999-99-99" } } }

  return $ranked | Select-Object -First 1
}

function Find-ReleasesForReleaseGroup([string]$ReleaseGroupId, [string]$Artist, [string]$Album) {
  $escapedArtist = Escape-MusicBrainzQueryValue $Artist
  $escapedAlbum = Escape-MusicBrainzQueryValue $Album
  $query = 'rgid:{0} AND artist:"{1}" AND release:"{2}"' -f $ReleaseGroupId, $escapedArtist, $escapedAlbum
  $encodedQuery = [System.Uri]::EscapeDataString($query)
  $url = "https://musicbrainz.org/ws/2/release/?query=$encodedQuery&fmt=json&limit=25"
  $response = Invoke-MusicBrainzRequest $url
  return $response.releases
}

function Get-ReleaseByMbid([string]$ReleaseMbid) {
  $url = "https://musicbrainz.org/ws/2/release/$ReleaseMbid?fmt=json"
  return Invoke-MusicBrainzRequest $url
}

function Get-FormatRank([string]$Format) {
  switch ($Format) {
    "CD" { return 0 }
    "Digital Media" { return 1 }
    "2xCD" { return 2 }
    "Vinyl" { return 3 }
    default { return 9 }
  }
}

function Get-CountryRank([string]$Country) {
  switch ($Country) {
    "US" { return 0 }
    "GB" { return 1 }
    "XW" { return 2 }
    default { return 9 }
  }
}

function Get-VariantPenalty([string]$Title) {
  $normalized = $Title.ToLowerInvariant()

  if ($normalized -match 'expanded|deluxe|bonus|hi-res|remaster|anniversary') {
    return 1
  }

  return 0
}

function Find-BestRelease([System.Collections.IDictionary]$EntryMap) {
  if ($EntryMap.Contains("mbid") -and -not [string]::IsNullOrWhiteSpace($EntryMap["mbid"])) {
    return @(Get-ReleaseByMbid $EntryMap["mbid"])
  }

  $originalAlbumTitle = $EntryMap["album"]
  $primaryAlbumTitle = Get-PrimaryAlbumTitle $originalAlbumTitle
  $searchAlbumTitle = $primaryAlbumTitle
  $releaseGroup = Find-BestReleaseGroup -Artist $EntryMap["artist"] -Album $searchAlbumTitle

  if (($null -eq $releaseGroup -or -not $releaseGroup.id) -and $primaryAlbumTitle -ne $originalAlbumTitle) {
    $searchAlbumTitle = $originalAlbumTitle
    $releaseGroup = Find-BestReleaseGroup -Artist $EntryMap["artist"] -Album $searchAlbumTitle
  }

  if ($null -eq $releaseGroup -or -not $releaseGroup.id) {
    return @()
  }

  $releases = Find-ReleasesForReleaseGroup -ReleaseGroupId $releaseGroup.id -Artist $EntryMap["artist"] -Album $searchAlbumTitle

  if ((-not $releases -or $releases.Count -eq 0) -and $searchAlbumTitle -ne $originalAlbumTitle) {
    $searchAlbumTitle = $originalAlbumTitle
    $releases = Find-ReleasesForReleaseGroup -ReleaseGroupId $releaseGroup.id -Artist $EntryMap["artist"] -Album $searchAlbumTitle
  }

  if (-not $releases) {
    return @()
  }

  $albumTitle = $searchAlbumTitle

  $ranked = $releases | Sort-Object `
    @{ Expression = { if ($_.status -eq "Official") { 0 } else { 1 } } }, `
    @{ Expression = { if ($_.title -eq $albumTitle) { 0 } else { 1 } } }, `
    @{ Expression = { Get-VariantPenalty $_.title } }, `
    @{ Expression = { Get-FormatRank $_.format } }, `
    @{ Expression = { Get-CountryRank $_.country } }, `
    @{ Expression = { if ($_.date) { $_.date } else { "9999-99-99" } } }

  return @($ranked)
}

function Get-CoverArtTempFile([string]$RemoteArtUrl) {
  $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString() + ".tmp")

  try {
    $response = Invoke-WebRequest -Uri $RemoteArtUrl -Method Get -OutFile $tempPath -PassThru
    return @{
      Response = $response
      TempPath = $tempPath
    }
  } catch {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force
    }

    throw
  }
}

function Convert-ToSlug([string]$Value) {
  $clean = $Value.ToLowerInvariant()
  $clean = $clean -replace "[^a-z0-9]+", "-"
  $clean = $clean.Trim("-")

  if ([string]::IsNullOrWhiteSpace($clean)) {
    return "item"
  }

  return $clean
}

function Get-ExtensionFromResponse($Response, [string]$FallbackUrl) {
  $contentType = ""

  if ($Response.Headers["Content-Type"]) {
    $contentType = $Response.Headers["Content-Type"].Split(";")[0].Trim().ToLowerInvariant()
  }

  switch ($contentType) {
    "image/jpeg" { return ".jpg" }
    "image/jpg" { return ".jpg" }
    "image/png" { return ".png" }
    "image/webp" { return ".webp" }
    default {
      $fallbackExtension = [System.IO.Path]::GetExtension(([System.Uri]$FallbackUrl).AbsolutePath)

      if ([string]::IsNullOrWhiteSpace($fallbackExtension)) {
        return ".jpg"
      }

      return $fallbackExtension.ToLowerInvariant()
    }
  }
}

function Get-ReleaseYear($Release) {
  if ($Release -and $Release.date -and $Release.date -match '^(\d{4})') {
    return $Matches[1]
  }

  return $null
}

function Get-ReleaseArtist($Release) {
  if ($Release -and $Release.'artist-credit') {
    $names = @(
      $Release.'artist-credit' |
        ForEach-Object {
          if ($_.name) {
            $_.name
          } elseif ($_.artist -and $_.artist.name) {
            $_.artist.name
          }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($names.Count -gt 0) {
      return ($names -join ", ")
    }
  }

  return $null
}

function Update-EntryMetadataFromRelease([System.Collections.IDictionary]$EntryMap, $Release, [string]$FallbackArtist, [string]$FallbackAlbum) {
  if ((-not $EntryMap.Contains("artist")) -or [string]::IsNullOrWhiteSpace($EntryMap["artist"])) {
    $resolvedArtist = Get-ReleaseArtist $Release

    if (-not [string]::IsNullOrWhiteSpace($resolvedArtist)) {
      $EntryMap["artist"] = $resolvedArtist
    } elseif (-not [string]::IsNullOrWhiteSpace($FallbackArtist)) {
      $EntryMap["artist"] = $FallbackArtist
    }
  }

  if ((-not $EntryMap.Contains("album")) -or [string]::IsNullOrWhiteSpace($EntryMap["album"])) {
    if ($Release -and -not [string]::IsNullOrWhiteSpace($Release.title)) {
      $EntryMap["album"] = $Release.title
    } elseif (-not [string]::IsNullOrWhiteSpace($FallbackAlbum)) {
      $EntryMap["album"] = $FallbackAlbum
    }
  }
}

function Get-ReleaseIdFromArtPath([string]$ArtPath) {
  if ([string]::IsNullOrWhiteSpace($ArtPath)) {
    return $null
  }

  $match = [regex]::Match($ArtPath, '-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.[a-z0-9]+$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

  if ($match.Success) {
    return $match.Groups[1].Value.ToLowerInvariant()
  }

  return $null
}

function Resolve-AlbumDataForEntry(
  [System.Collections.IDictionary]$EntryMap,
  [string]$ResolvedImageDirectory,
  [string]$ImageDirectory,
  [int]$ArtSize,
  [bool]$ForceDownload
) {
  $releases = Find-BestRelease -EntryMap $EntryMap

  if (-not $releases -or $releases.Count -eq 0) {
    throw "No suitable MusicBrainz release found."
  }

  $fallbackArtist = if ($EntryMap.Contains("artist")) { $EntryMap["artist"] } else { "" }
  $fallbackAlbum = if ($EntryMap.Contains("album")) { $EntryMap["album"] } else { "" }
  $currentArtPath = if ($EntryMap.Contains("art")) { $EntryMap["art"].Trim() } else { "" }
  $currentReleaseId = Get-ReleaseIdFromArtPath $currentArtPath

  foreach ($release in $releases) {
    if (-not $release.id) {
      continue
    }

    $releaseId = $release.id.ToLowerInvariant()
    $releaseYear = Get-ReleaseYear $release
    $resolvedArtist = Get-ReleaseArtist $release
    $artistSlug = Convert-ToSlug $(if ($resolvedArtist) { $resolvedArtist } else { $fallbackArtist })
    $albumSlug = Convert-ToSlug $(if ($release.title) { $release.title } else { $fallbackAlbum })

    if (-not $ForceDownload -and $currentReleaseId -eq $releaseId) {
      return @{
        ArtPath = $currentArtPath
        Year = $releaseYear
        ReleaseId = $releaseId
        ArtChanged = $false
        Release = $release
      }
    }

    $remoteArtUrl = "https://coverartarchive.org/release/$($release.id)/front-$ArtSize"
    $baseName = "{0}-{1}-{2}" -f $artistSlug, $albumSlug, $releaseId

    try {
      $download = Get-CoverArtTempFile -RemoteArtUrl $remoteArtUrl
      $response = $download.Response
      $tempPath = $download.TempPath
      $extension = Get-ExtensionFromResponse -Response $response -FallbackUrl $remoteArtUrl
      $destinationFileName = "$baseName$extension"
      $destinationPath = Join-Path -Path $ResolvedImageDirectory -ChildPath $destinationFileName
      Move-Item -LiteralPath $tempPath -Destination $destinationPath -Force

      return @{
        ArtPath = (($ImageDirectory.TrimEnd("\", "/") + "/" + $destinationFileName) -replace "\\", "/")
        Year = $releaseYear
        ReleaseId = $releaseId
        ArtChanged = $true
        Release = $release
      }
    } catch {
      $statusCode = $null

      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }

      if ($statusCode -eq 404) {
        Write-Host "  -> no cover art for release $($release.id), trying next match..."
        continue
      }

      throw
    }
  }

  throw "No release with cover art was found."
}

function Sort-AlbumEntries([string[]]$EntryBlocks, [string]$Field) {
  $parsedEntries = foreach ($block in $EntryBlocks) {
    $map = Convert-EntryToMap $block
    [pscustomobject]@{
      EntryMap = $map
      Artist = if ($map.Contains("artist")) { $map["artist"] } else { "" }
      Album = if ($map.Contains("album")) { $map["album"] } else { "" }
      Score = if ($map.Contains("score")) { [double]$map["score"] } else { -1 }
    }
  }

  switch ($Field) {
    "artist" {
      $sorted = $parsedEntries | Sort-Object Artist, Album
    }
    "album" {
      $sorted = $parsedEntries | Sort-Object Album, Artist
    }
    "score" {
      $sorted = $parsedEntries | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, Artist, Album
    }
  }

  $updatedEntries = New-Object System.Collections.Generic.List[string]

  foreach ($entry in $sorted) {
    $updatedEntries.Add((Build-EntryText $entry.EntryMap))
  }

  return $updatedEntries
}

if (-not $Mode) {
  $Mode = Get-ModeFromPrompt
}

$resolvedSourcePath = Get-ResolvedPath $SourcePath
$resolvedImageDirectory = Get-ResolvedPath $ImageDirectory

$sourceText = [System.IO.File]::ReadAllText($resolvedSourcePath)
$entries = Parse-AlbumEntries $sourceText

if ($Mode -eq "sort") {
  if (-not $SortBy) {
    $SortBy = Get-SortFieldFromPrompt
  }

  $sortedEntries = Sort-AlbumEntries -EntryBlocks $entries -Field $SortBy
  $entrySeparator = [Environment]::NewLine + [Environment]::NewLine
  $finalText = (($sortedEntries -join $entrySeparator).TrimEnd()) + [Environment]::NewLine
  [System.IO.File]::WriteAllText($resolvedSourcePath, $finalText)
  Write-Host "Albums sorted by $SortBy."
  exit 0
}

if (-not (Test-Path -Path $resolvedImageDirectory)) {
  New-Item -ItemType Directory -Path $resolvedImageDirectory -Force | Out-Null
}

$updatedEntries = New-Object System.Collections.Generic.List[string]

for ($index = 0; $index -lt $entries.Count; $index++) {
  $entryMap = Convert-EntryToMap $entries[$index]
  $hasMbid = $entryMap.Contains("mbid") -and -not [string]::IsNullOrWhiteSpace($entryMap["mbid"])
  $hasArtistAlbum = (-not [string]::IsNullOrWhiteSpace($entryMap["artist"])) -and (-not [string]::IsNullOrWhiteSpace($entryMap["album"]))

  if (-not $hasMbid -and -not $hasArtistAlbum) {
    Write-Warning "Skipping entry $($index + 1): missing mbid and artist/album."
    $updatedEntries.Add((Build-EntryText $entryMap))
    continue
  }

  $currentArt = if ($entryMap.Contains("art")) { $entryMap["art"].Trim() } else { "" }
  $hasBlankArt = [string]::IsNullOrWhiteSpace($currentArt)
  $shouldFetch = $Mode -in @("all", "refresh") -or ($Mode -eq "missing" -and $hasBlankArt)

  if (-not $shouldFetch) {
    Write-Host "Skipping $($entryMap["artist"]) - $($entryMap["album"]): local art already set."
    $updatedEntries.Add((Build-EntryText $entryMap))
    continue
  }

  if ($Mode -eq "refresh") {
    Write-Host "Refreshing MusicBrainz data for $($entryMap["artist"]) - $($entryMap["album"])..."
  } else {
    Write-Host "Fetching and caching art for $($entryMap["artist"]) - $($entryMap["album"])..."
  }

  try {
    $previousArt = $currentArt
    $previousYear = if ($entryMap.Contains("year")) { $entryMap["year"] } else { "" }
    $downloadResult = Resolve-AlbumDataForEntry `
      -EntryMap $entryMap `
      -ResolvedImageDirectory $resolvedImageDirectory `
      -ImageDirectory $ImageDirectory `
      -ArtSize $ArtSize `
      -ForceDownload ($Mode -eq "all" -or $Mode -eq "missing")

    $entryMap["art"] = $downloadResult.ArtPath

    if ($downloadResult.Year) {
      $entryMap["year"] = $downloadResult.Year
    }

    if ((-not $entryMap.Contains("mbid")) -or [string]::IsNullOrWhiteSpace($entryMap["mbid"])) {
      $entryMap["mbid"] = $downloadResult.ReleaseId
    }

    Update-EntryMetadataFromRelease `
      -EntryMap $entryMap `
      -Release $downloadResult.Release `
      -FallbackArtist $(if ($hasArtistAlbum) { $entryMap["artist"] } else { "" }) `
      -FallbackAlbum $(if ($hasArtistAlbum) { $entryMap["album"] } else { "" })

    if ($Mode -eq "refresh") {
      if ($downloadResult.ArtChanged -or $previousArt -ne $entryMap["art"]) {
        Write-Host "  -> updated art: $($entryMap["art"])"
      }

      if ($downloadResult.Year -and $previousYear -ne $downloadResult.Year) {
        Write-Host "  -> updated year: $($downloadResult.Year)"
      }

      if ((-not $downloadResult.ArtChanged) -and ($previousArt -eq $entryMap["art"]) -and ($previousYear -eq $entryMap["year"])) {
        Write-Host "  -> no changes found"
      }
    } else {
      Write-Host "  -> $($entryMap["art"])"
    }
  } catch {
    Write-Warning "Failed for $($entryMap["artist"]) - $($entryMap["album"]): $($_.Exception.Message)"
  }

  $updatedEntries.Add((Build-EntryText $entryMap))

  if ($index -lt ($entries.Count - 1)) {
    Start-Sleep -Milliseconds $DelayMs
  }
}

$entrySeparator = [Environment]::NewLine + [Environment]::NewLine
$finalText = (($updatedEntries -join $entrySeparator).TrimEnd()) + [Environment]::NewLine
[System.IO.File]::WriteAllText($resolvedSourcePath, $finalText)

Write-Host "Album art sync complete."
