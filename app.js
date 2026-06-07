const albumTableBody = document.getElementById("albumTableBody");
const statusMessage = document.getElementById("statusMessage");
const resultCount = document.getElementById("resultCount");
const searchInput = document.getElementById("searchInput");
const albumRowTemplate = document.getElementById("albumRowTemplate");
const sortableHeaders = Array.from(document.querySelectorAll(".sortable-header"));
const DATA_URL = "albums.txt";

let allAlbums = [];
let searchQuery = "";
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
    allAlbums = parseAlbumText(sourceText).sort((left, right) => right.score - left.score);
    updateSortIndicators();
    renderAlbums(getVisibleAlbums());
    searchInput.addEventListener("input", handleSearch);
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

  return entries.map((entry, index) => {
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

    if (!fields.artist || !fields.album || !fields.score || !fields.art) {
      throw new Error(`Entry ${index + 1} is missing required fields.`);
    }

    return {
      artist: fields.artist,
      album: fields.album,
      score: Number.parseFloat(fields.score),
      art: fields.art,
      review: fields.review || "",
    };
  });
}

function handleSearch(event) {
  searchQuery = event.target.value.trim().toLowerCase();
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
  const filteredAlbums = searchQuery
    ? allAlbums.filter((album) => {
        const haystack = [album.artist, album.album, album.review].join(" ").toLowerCase();
        return haystack.includes(searchQuery);
      })
    : [...allAlbums];

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
    const scoreCell = row.querySelector(".score-cell");
    const scoreBadge = row.querySelector(".score-badge");

    image.src = album.art;
    image.alt = `${album.album} by ${album.artist}`;
    image.loading = "lazy";
    image.decoding = "async";
    row.querySelector(".artist-cell").textContent = album.artist;
    row.querySelector(".album-cell").textContent = album.album;
    scoreBadge.textContent = formatScore(album.score);
    scoreBadge.dataset.scoreBand = getScoreBand(album.score);
    row.querySelector(".review-cell").textContent = album.review || "";

    fragment.appendChild(row);
  }

  albumTableBody.appendChild(fragment);
}

function formatScore(score) {
  return Number.isInteger(score) ? score.toFixed(0) : score.toFixed(1);
}

function getScoreBand(score) {
  const wholeNumber = Math.floor(score);
  return Math.max(0, Math.min(10, wholeNumber)).toString();
}

function showStatus(message) {
  statusMessage.hidden = false;
  statusMessage.textContent = message;
}
