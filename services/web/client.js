/* global document, fetch */
"use strict";

async function loadItems(target, fetchItems = fetch) {
  try {
    const response = await fetchItems("/api/items");
    if (!response.ok) throw new Error("API unavailable");
    const items = await response.json();
    if (!Array.isArray(items) || items.some(item => typeof item.name !== "string")) {
      throw new Error("Invalid items response");
    }
    const list = document.createElement("ul");
    for (const item of items) {
      const entry = document.createElement("li");
      entry.textContent = item.name;
      list.appendChild(entry);
    }
    target.replaceChildren(list);
  } catch {
    target.textContent = "Unable to load items. Please try again later.";
  }
}

if (typeof module !== "undefined") module.exports = { loadItems };
if (typeof document !== "undefined") loadItems(document.getElementById("items"));
