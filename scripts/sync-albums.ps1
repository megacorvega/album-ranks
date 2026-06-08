param(
  [string]$SourcePath = "albums.txt",
  [string]$ImageDirectory = "images\covers",
  [int]$DelayMs = 1100,
  [int]$ArtSize = 500,
  [ValidateSet("all", "missing")]
  [string]$Mode
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
    $selection = (Read-Host "Enter 1 or 2").Trim()

    switch ($selection) {
      "1" { return "all" }
      "2" { return "missing" }
      default { Write-Host "Please enter 1 or 2." }
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
  $orderedKeys = @("artist", "album", "score", "art", "review")
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

function Download-AlbumArtForEntry(
  [System.Collections.IDictionary]$EntryMap,
  [string]$ResolvedImageDirectory,
  [string]$ImageDirectory,
  [int]$ArtSize
) {
  $releases = Find-BestRelease -EntryMap $EntryMap

  if (-not $releases -or $releases.Count -eq 0) {
    throw "No suitable MusicBrainz release found."
  }

  $artistSlug = Convert-ToSlug $EntryMap["artist"]
  $albumSlug = Convert-ToSlug $EntryMap["album"]

  foreach ($release in $releases) {
    if (-not $release.id) {
      continue
    }

    $remoteArtUrl = "https://coverartarchive.org/release/$($release.id)/front-$ArtSize"
    $baseName = "{0}-{1}-{2}" -f $artistSlug, $albumSlug, $release.id.ToLowerInvariant()

    try {
      $download = Get-CoverArtTempFile -RemoteArtUrl $remoteArtUrl
      $response = $download.Response
      $tempPath = $download.TempPath
      $extension = Get-ExtensionFromResponse -Response $response -FallbackUrl $remoteArtUrl
      $destinationFileName = "$baseName$extension"
      $destinationPath = Join-Path -Path $ResolvedImageDirectory -ChildPath $destinationFileName
      Move-Item -LiteralPath $tempPath -Destination $destinationPath -Force

      return (($ImageDirectory.TrimEnd("\", "/") + "/" + $destinationFileName) -replace "\\", "/")
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

if (-not $Mode) {
  $Mode = Get-ModeFromPrompt
}

$resolvedSourcePath = Get-ResolvedPath $SourcePath
$resolvedImageDirectory = Get-ResolvedPath $ImageDirectory

if (-not (Test-Path -Path $resolvedImageDirectory)) {
  New-Item -ItemType Directory -Path $resolvedImageDirectory -Force | Out-Null
}

$sourceText = [System.IO.File]::ReadAllText($resolvedSourcePath)
$entries = Parse-AlbumEntries $sourceText
$updatedEntries = New-Object System.Collections.Generic.List[string]

for ($index = 0; $index -lt $entries.Count; $index++) {
  $entryMap = Convert-EntryToMap $entries[$index]

  if (-not $entryMap["artist"] -or -not $entryMap["album"]) {
    Write-Warning "Skipping entry $($index + 1): missing artist or album."
    $updatedEntries.Add((Build-EntryText $entryMap))
    continue
  }

  $currentArt = if ($entryMap.Contains("art")) { $entryMap["art"].Trim() } else { "" }
  $shouldFetch = $Mode -eq "all" -or [string]::IsNullOrWhiteSpace($currentArt)

  if (-not $shouldFetch) {
    Write-Host "Skipping $($entryMap["artist"]) - $($entryMap["album"]): art already set."
    $updatedEntries.Add((Build-EntryText $entryMap))
    continue
  }

  Write-Host "Fetching and caching art for $($entryMap["artist"]) - $($entryMap["album"])..."

  try {
    $entryMap["art"] = Download-AlbumArtForEntry `
      -EntryMap $entryMap `
      -ResolvedImageDirectory $resolvedImageDirectory `
      -ImageDirectory $ImageDirectory `
      -ArtSize $ArtSize

    Write-Host "  -> $($entryMap["art"])"
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
