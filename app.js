const albumTableBody = document.getElementById("albumTableBody");
const statusMessage = document.getElementById("statusMessage");
const resultCount = document.getElementById("resultCount");
const searchInput = document.getElementById("searchInput");
const yearFilter = document.getElementById("yearFilter");
const decadeFilter = document.getElementById("decadeFilter");
const albumRowTemplate = document.getElementById("albumRowTemplate");
const sortableHeaders = Array.from(document.querySelectorAll(".sortable-header"));
const DATA_URL = "albums.txt";

let allAlbums = [];
let searchQuery = "";
let selectedYear = "";
let selectedDecade = "";
let sortState = {
  key: "score",
  direction: "desc",
};

initialize();

async function initialize() {
  try {
    const response = await fetch(DATA_URL, { cache: "no-store" });

    if (!response.ok) {
      throw new Error(`Request failed with status ${response.status}`);
    }

    const sourceText = await response.text();
    allAlbums = parseAlbumText(sourceText);
    populateYearFilters(allAlbums);
    updateSortIndicators();
    renderAlbums(getVisibleAlbums());
    searchInput.addEventListener("input", handleSearch);
    yearFilter.addEventListener("change", handleYearFilter);
    decadeFilter.addEventListener("change", handleDecadeFilter);
    sortableHeaders.forEach((header) => header.addEventListener("click", handleSort));
  } catch (error) {
    console.error(error);
    showStatus("Could not load albums.txt from the repo root.");
  }
}

function parseAlbumText(sourceText) {
  const entries = sourceText
    .split(/\n\s*\n+/)
    .map((entry) => entry.trim())
    .filter(Boolean);

  return entries.flatMap((entry) => {
    const fields = {};
    const lines = entry.split(/\r?\n/);

    for (const line of lines) {
      const separatorIndex = line.indexOf(":");

      if (separatorIndex === -1) {
        continue;
      }

      const key = line.slice(0, separatorIndex).trim().toLowerCase();
      const value = line.slice(separatorIndex + 1).trim();
      fields[key] = value;
    }

    // Ignore incomplete draft blocks in albums.txt so you can keep placeholders
    // at the bottom of the file without breaking the rendered site.
    if (!fields.artist || !fields.album || !fields.score || !fields.art) {
      return [];
    }

    return [{
      artist: fields.artist,
      album: fields.album,
      score: Number.parseFloat(fields.score),
      originalScore: parseOptionalScore(fields.original_score),
      year: parseReleaseYear(fields.year),
      decade: getDecadeLabel(parseReleaseYear(fields.year)),
      art: fields.art,
      review: fields.review || "",
    }];
  });
}

function handleSearch(event) {
  searchQuery = event.target.value.trim().toLowerCase();
  renderAlbums(getVisibleAlbums());
}

function handleYearFilter(event) {
  selectedYear = event.target.value;
  renderAlbums(getVisibleAlbums());
}

function handleDecadeFilter(event) {
  selectedDecade = event.target.value;
  renderAlbums(getVisibleAlbums());
}

function handleSort(event) {
  const nextKey = event.currentTarget.dataset.sortKey;

  if (sortState.key === nextKey) {
    sortState.direction = sortState.direction === "asc" ? "desc" : "asc";
  } else {
    sortState.key = nextKey;
    sortState.direction = nextKey === "score" ? "desc" : "asc";
  }

  updateSortIndicators();
  renderAlbums(getVisibleAlbums());
}

function getVisibleAlbums() {
  const filteredAlbums = allAlbums.filter((album) => {
    if (searchQuery) {
      const haystack = [album.artist, album.album, album.review].join(" ").toLowerCase();
      if (!haystack.includes(searchQuery)) {
        return false;
      }
    }

    if (selectedYear && album.year !== Number.parseInt(selectedYear, 10)) {
      return false;
    }

    if (selectedDecade && album.decade !== selectedDecade) {
      return false;
    }

    return true;
  });

  return filteredAlbums.sort(compareAlbums);
}

function compareAlbums(left, right) {
  const directionMultiplier = sortState.direction === "asc" ? 1 : -1;

  if (sortState.key === "score") {
    return (left.score - right.score) * directionMultiplier;
  }

  return left[sortState.key].localeCompare(right[sortState.key]) * directionMultiplier;
}

function updateSortIndicators() {
  sortableHeaders.forEach((header) => {
    const isActive = header.dataset.sortKey === sortState.key;
    header.setAttribute(
      "aria-sort",
      isActive ? (sortState.direction === "asc" ? "ascending" : "descending") : "none"
    );
  });
}

function renderAlbums(albums) {
  albumTableBody.replaceChildren();
  resultCount.textContent = `${albums.length} album${albums.length === 1 ? "" : "s"}`;

  if (!albums.length) {
    showStatus("No albums matched that search.");
    return;
  }

  statusMessage.hidden = true;

  const fragment = document.createDocumentFragment();

  for (const album of albums) {
    const row = albumRowTemplate.content.firstElementChild.cloneNode(true);
    const image = row.querySelector(".album-art");
    const scoreValue = row.querySelector(".score-value");
    const scoreBadge = row.querySelector(".score-badge");

    image.src = album.art;
    image.alt = `${album.album} by ${album.artist}`;
    image.loading = "lazy";
    image.decoding = "async";
    row.querySelector(".artist-cell").textContent = album.artist;
    row.querySelector(".album-cell").textContent = album.album;
    const formattedScore = formatScore(album.score);

    if (album.originalScore === null) {
      scoreValue.hidden = false;
      scoreBadge.hidden = true;
      scoreValue.textContent = formattedScore;
    } else {
      scoreValue.hidden = true;
      scoreBadge.hidden = false;
      scoreBadge.textContent = formattedScore;
      scoreBadge.dataset.scoreBand = getScoreBand(album.score);
    }

    row.querySelector(".review-cell").textContent = album.review || "";

    fragment.appendChild(row);
  }

  albumTableBody.appendChild(fragment);
}

function formatScore(score) {
  return Number.isInteger(score) ? score.toFixed(0) : score.toFixed(1);
}

function parseOptionalScore(rawScore) {
  if (!rawScore) {
    return null;
  }

  const parsedScore = Number.parseFloat(rawScore);
  return Number.isNaN(parsedScore) ? null : parsedScore;
}

function parseReleaseYear(rawYear) {
  if (!rawYear) {
    return null;
  }

  const parsedYear = Number.parseInt(rawYear, 10);
  if (Number.isNaN(parsedYear) || rawYear.trim().length !== 4) {
    return null;
  }

  return parsedYear;
}

function getDecadeLabel(year) {
  if (year === null) {
    return "";
  }

  const decadeStart = Math.floor(year / 10) * 10;
  return `${decadeStart}s`;
}

function populateYearFilters(albums) {
  const years = [...new Set(albums.map((album) => album.year).filter((year) => year !== null))].sort(
    (left, right) => right - left
  );
  const decades = [...new Set(albums.map((album) => album.decade).filter(Boolean))].sort(
    (left, right) => Number.parseInt(right, 10) - Number.parseInt(left, 10)
  );

  appendOptions(yearFilter, years, "All years");
  appendOptions(decadeFilter, decades, "All decades");
}

function appendOptions(select, values, defaultLabel) {
  select.replaceChildren();
  select.appendChild(new Option(defaultLabel, ""));

  for (const value of values) {
    select.appendChild(new Option(String(value), String(value)));
  }
}

function getScoreBand(score) {
  const wholeNumber = Math.floor(score);
  return Math.max(0, Math.min(10, wholeNumber)).toString();
}

function showStatus(message) {
  statusMessage.hidden = false;
  statusMessage.textContent = message;
}
