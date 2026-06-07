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

function Find-BestRelease([string]$Artist, [string]$Album) {
  $escapedArtist = Escape-MusicBrainzQueryValue $Artist
  $escapedAlbum = Escape-MusicBrainzQueryValue $Album
  $query = 'artist:"{0}" AND release:"{1}"' -f $escapedArtist, $escapedAlbum
  $encodedQuery = [System.Uri]::EscapeDataString($query)
  $url = "https://musicbrainz.org/ws/2/release/?query=$encodedQuery&fmt=json&limit=10"

  $headers = @{
    "User-Agent" = "album-ranks/1.0 (https://github.com/)"
    "Accept" = "application/json"
  }

  $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get

  if (-not $response.releases) {
    return $null
  }

  $ranked = $response.releases | Sort-Object `
    @{ Expression = { if ($_.status -eq "Official") { 0 } else { 1 } } }, `
    @{ Expression = { -1 * [int]($_.score) } }, `
    @{ Expression = { if ($_.date) { $_.date } else { "9999-99-99" } } }

  return $ranked | Select-Object -First 1
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
  $release = Find-BestRelease -Artist $EntryMap["artist"] -Album $EntryMap["album"]

  if ($null -eq $release -or -not $release.id) {
    throw "No MusicBrainz release found."
  }

  $remoteArtUrl = "https://coverartarchive.org/release/$($release.id)/front-$ArtSize"
  $artistSlug = Convert-ToSlug $EntryMap["artist"]
  $albumSlug = Convert-ToSlug $EntryMap["album"]
  $baseName = "{0}-{1}-{2}" -f $artistSlug, $albumSlug, $release.id.ToLowerInvariant()

  $tempPath = $null

  try {
    $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString() + ".tmp")
    $response = Invoke-WebRequest -Uri $remoteArtUrl -Method Get -OutFile $tempPath -PassThru
    $extension = Get-ExtensionFromResponse -Response $response -FallbackUrl $remoteArtUrl
    $destinationFileName = "$baseName$extension"
    $destinationPath = Join-Path -Path $ResolvedImageDirectory -ChildPath $destinationFileName
    Move-Item -LiteralPath $tempPath -Destination $destinationPath -Force

    return (($ImageDirectory.TrimEnd("\", "/") + "/" + $destinationFileName) -replace "\\", "/")
  } finally {
    if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
      Remove-Item -LiteralPath $tempPath -Force
    }
  }
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
