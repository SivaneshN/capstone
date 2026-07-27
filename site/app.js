const API_BASE = (window.API_BASE_URL || "").replace(/\/$/, "");

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str ?? "";
  return div.innerHTML;
}

function renderTags(tags, onTagClick) {
  if (!tags || tags.length === 0) return "";
  const chips = tags
    .map((t) => `<span class="tag" data-tag="${escapeHtml(t)}">${escapeHtml(t)}</span>`)
    .join("");
  return `<div class="tags">${chips}</div>`;
}

function attachTagHandlers(container) {
  container.querySelectorAll(".tag").forEach((el) => {
    el.addEventListener("click", () => {
      const tag = el.dataset.tag;
      document.getElementById("tag-input").value = tag;
      runSearch(tag);
    });
  });
}

function recordHtml(record) {
  const image = record.media_type === "image" && record.url
    ? `<img src="${escapeHtml(record.url)}" alt="${escapeHtml(record.title)}" loading="lazy">`
    : "";
  return `
    <div class="apod-record">
      ${image}
      <h3>${escapeHtml(record.title)}</h3>
      <p class="meta">${escapeHtml(record.date)}</p>
      <p>${escapeHtml(record.preview || record.explanation || "")}</p>
      ${renderTags(record.tags)}
    </div>
  `;
}

async function loadToday() {
  const container = document.getElementById("today-content");
  if (!API_BASE) {
    container.innerHTML = `<p class="error">API base URL is not configured.</p>`;
    return;
  }
  try {
    const res = await fetch(`${API_BASE}/today`);
    if (res.status === 404) {
      container.innerHTML = `<p class="empty">No APOD record has been fetched yet today.</p>`;
      return;
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const record = await res.json();
    container.innerHTML = recordHtml(record);
    attachTagHandlers(container);
  } catch (err) {
    container.innerHTML = `<p class="error">Failed to load today's record: ${escapeHtml(err.message)}</p>`;
  }
}

async function runSearch(tag) {
  const results = document.getElementById("search-results");
  results.innerHTML = `<p class="loading">Searching...</p>`;
  try {
    const res = await fetch(`${API_BASE}/search?tag=${encodeURIComponent(tag)}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    if (!data.results || data.results.length === 0) {
      results.innerHTML = `<p class="empty">No records found for tag "${escapeHtml(tag)}".</p>`;
      return;
    }
    results.innerHTML =
      `<p class="result-count">${data.count} result(s) for "${escapeHtml(data.tag)}"</p>` +
      data.results.map(recordHtml).join("");
    attachTagHandlers(results);
  } catch (err) {
    results.innerHTML = `<p class="error">Search failed: ${escapeHtml(err.message)}</p>`;
  }
}

document.getElementById("search-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const tag = document.getElementById("tag-input").value.trim();
  if (tag) runSearch(tag);
});

loadToday();
