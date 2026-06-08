param(
  [string]$SourcePath = "albums.txt"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-ResolvedPath([string]$PathValue) {
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return $PathValue
  }

  return Join-Path -Path $RepoRoot -ChildPath $PathValue
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
  $orderedKeys = @("artist", "album", "score", "original_score", "mbid", "art", "review")
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

function Write-AlbumEntries([string]$ResolvedSourcePath, [System.Collections.IList]$Entries) {
  $entryTexts = New-Object System.Collections.Generic.List[string]

  foreach ($entry in $Entries) {
    $entryTexts.Add((Build-EntryText $entry.EntryMap))
  }

  $entrySeparator = [Environment]::NewLine + [Environment]::NewLine
  $finalText = (($entryTexts -join $entrySeparator).TrimEnd()) + [Environment]::NewLine
  [System.IO.File]::WriteAllText($ResolvedSourcePath, $finalText)
}

function Get-ScoreValue([System.Collections.IDictionary]$EntryMap, [string]$Key) {
  if ($EntryMap.Contains($Key) -and $EntryMap[$Key] -match '^-?\d+(\.\d+)?$') {
    return [double]$EntryMap[$Key]
  }

  return $null
}

function Get-DisplayName($Entry) {
  return "$($Entry.Artist) - $($Entry.Album)"
}

function Clear-RankingScreen() {
  Clear-Host
}

function Prompt-Comparison($TargetEntry, $CandidateEntry) {
  while ($true) {
    Clear-RankingScreen
    Write-Host "Target:    $(Get-DisplayName $TargetEntry)"
    Write-Host "Compare to $(Get-DisplayName $CandidateEntry)"
    $selection = (Read-Host "Is the target better, worse, or should it be deleted? [b]etter / [w]orse / [d]elete / [q]uit").Trim().ToLowerInvariant()

    switch ($selection) {
      "b" { return "better" }
      "w" { return "worse" }
      "d" { return "delete" }
      "q" { return "quit" }
      default { Write-Host "Please enter b, w, d, or q." }
    }
  }
}

function Select-TargetEntry([System.Collections.IList]$Entries) {
  $unranked = @($Entries | Where-Object { -not $_.HasDerivedScore })

  if ($unranked.Count -gt 0) {
    return Get-Random -InputObject $unranked
  }

  return Get-Random -InputObject $Entries
}

function Insert-ByComparison($TargetEntry, [System.Collections.IList]$RankedEntries) {
  if ($RankedEntries.Count -eq 0) {
    return 0
  }

  $low = 0
  $high = $RankedEntries.Count - 1

  while ($low -le $high) {
    $mid = [int](($low + $high) / 2)
    $comparison = Prompt-Comparison -TargetEntry $TargetEntry -CandidateEntry $RankedEntries[$mid]

    if ($comparison -eq "quit") {
      return $null
    }

    if ($comparison -eq "delete") {
      return "delete"
    }

    if ($comparison -eq "better") {
      $high = $mid - 1
    } else {
      $low = $mid + 1
    }
  }

  return $low
}

function Reassign-DerivedScores([System.Collections.IList]$RankedEntries) {
  if ($RankedEntries.Count -eq 1) {
    $RankedEntries[0].Score = 10.0
    $RankedEntries[0].EntryMap["score"] = "10"
    return
  }

  for ($index = 0; $index -lt $RankedEntries.Count; $index++) {
    $score = 10.0 - (($index * 10.0) / ($RankedEntries.Count - 1))
    $roundedScore = [Math]::Round($score, 4)
    $RankedEntries[$index].Score = $roundedScore
    $RankedEntries[$index].EntryMap["score"] = $roundedScore.ToString("0.####", [System.Globalization.CultureInfo]::InvariantCulture)
  }
}

function Prompt-Continue() {
  while ($true) {
    Clear-RankingScreen
    $selection = (Read-Host "Do another action? [y/n]").Trim().ToLowerInvariant()

    switch ($selection) {
      "y" { return $true }
      "n" { return $false }
      default { Write-Host "Please enter y or n." }
    }
  }
}

function Prompt-DeleteSelection([System.Collections.IList]$Entries) {
  while ($true) {
    Clear-RankingScreen
    $query = (Read-Host "Search for an album to delete (or q to cancel)").Trim()

    if ($query.ToLowerInvariant() -eq "q") {
      return $null
    }

    $matches = @(
      $Entries | Where-Object {
        (Get-DisplayName $_).ToLowerInvariant().Contains($query.ToLowerInvariant())
      } | Select-Object -First 20
    )

    if ($matches.Count -eq 0) {
      Write-Host "No matches found."
      continue
    }

    for ($index = 0; $index -lt $matches.Count; $index++) {
      Write-Host "$($index + 1). $(Get-DisplayName $matches[$index])"
    }

    $selection = (Read-Host "Enter a number to delete, or q to cancel").Trim()

    if ($selection.ToLowerInvariant() -eq "q") {
      return $null
    }

    $selectedIndex = 0
    if ([int]::TryParse($selection, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $matches.Count) {
      return $matches[$selectedIndex - 1]
    }

    Write-Host "Please enter a valid number."
  }
}

function Confirm-Delete($Entry) {
  while ($true) {
    Clear-RankingScreen
    Write-Host "Delete $(Get-DisplayName $Entry) from albums.txt?"
    $selection = (Read-Host "Type y to confirm or n to cancel").Trim().ToLowerInvariant()

    switch ($selection) {
      "y" { return $true }
      "n" { return $false }
      default { Write-Host "Please enter y or n." }
    }
  }
}

$resolvedSourcePath = Get-ResolvedPath $SourcePath
$sourceText = [System.IO.File]::ReadAllText($resolvedSourcePath)
$entryBlocks = Parse-AlbumEntries $sourceText
$entries = New-Object System.Collections.Generic.List[object]

foreach ($block in $entryBlocks) {
  $entryMap = Convert-EntryToMap $block
  if ($entryMap.Contains("rank")) {
    $entryMap.Remove("rank")
  }
  $entries.Add([pscustomobject]@{
    EntryMap = $entryMap
    Artist = if ($entryMap.Contains("artist")) { $entryMap["artist"] } else { "" }
    Album = if ($entryMap.Contains("album")) { $entryMap["album"] } else { "" }
    Score = if ($entryMap.Contains("score")) { [double]$entryMap["score"] } else { 0 }
    OriginalScore = Get-ScoreValue -EntryMap $entryMap -Key "original_score"
    HasDerivedScore = $entryMap.Contains("original_score")
  })
}

do {
  $targetEntry = Select-TargetEntry -Entries $entries
  $rankedEntries = New-Object System.Collections.Generic.List[object]

  foreach ($entry in ($entries | Where-Object { $_.HasDerivedScore } | Sort-Object @{ Expression = { $_.Score }; Descending = $true })) {
    if ($entry -ne $targetEntry) {
      $rankedEntries.Add($entry)
    }
  }

  Write-Host ""
  Write-Host "Ranking: $(Get-DisplayName $targetEntry)"

  $insertIndex = Insert-ByComparison -TargetEntry $targetEntry -RankedEntries $rankedEntries

  if ($null -eq $insertIndex) {
    Write-Host "Ranking cancelled."
    continue
  }

  if ($insertIndex -eq "delete") {
    if (-not (Confirm-Delete $targetEntry)) {
      Write-Host "Delete cancelled."
      continue
    }

    $null = $entries.Remove($targetEntry)

    $remainingRankedEntries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in ($entries | Where-Object { $_.HasDerivedScore } | Sort-Object @{ Expression = { $_.Score }; Descending = $true })) {
      $remainingRankedEntries.Add($entry)
    }

    if ($remainingRankedEntries.Count -gt 0) {
      Reassign-DerivedScores -RankedEntries $remainingRankedEntries
    }

    Write-AlbumEntries -ResolvedSourcePath $resolvedSourcePath -Entries $entries
    Write-Host "Deleted $(Get-DisplayName $targetEntry)."
    continue
  }

  if (-not $targetEntry.HasDerivedScore) {
    $targetEntry.EntryMap["original_score"] = $targetEntry.Score.ToString("0.####", [System.Globalization.CultureInfo]::InvariantCulture)
    $targetEntry.OriginalScore = $targetEntry.Score
    $targetEntry.HasDerivedScore = $true
  }

  $rankedEntries.Insert($insertIndex, $targetEntry)
  Reassign-DerivedScores -RankedEntries $rankedEntries

  Write-AlbumEntries -ResolvedSourcePath $resolvedSourcePath -Entries $entries
  Write-Host "Assigned score $($targetEntry.EntryMap["score"]) to $(Get-DisplayName $targetEntry)."
} while (Prompt-Continue)
