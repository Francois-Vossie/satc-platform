// Minimal PWA storefront: reads the catalogue from /api/products (CloudFront -> API Gateway -> Lambda -> DynamoDB)
const CATS = ["all", "pottery", "textiles", "leather", "wood-carvings", "skincare", "jewellery"];
const grid = document.getElementById("grid"), status = document.getElementById("status"), nav = document.getElementById("cats");

function esc(s) { return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c])); }

async function load(cat) {
  [...nav.children].forEach(b => b.classList.toggle("on", b.dataset.cat === cat));
  status.textContent = "Loading...";
  try {
    const url = cat === "all" ? "/api/products" : `/api/products?category=${encodeURIComponent(cat)}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(res.status);
    const { items } = await res.json();
    grid.innerHTML = items.map(p => `<div class="card"><small>${esc(p.category)} | ${esc(p.centreId)}</small>
      <h3>${esc(p.name)}</h3><div class="price">USD ${(p.priceCents / 100).toFixed(2)}</div></div>`).join("");
    status.textContent = `${items.length} products`;
  } catch (e) {
    status.textContent = navigator.onLine ? "Could not load products - please retry." : "You are offline - showing cached pages.";
  }
}

CATS.forEach(c => { const b = document.createElement("button"); b.textContent = c; b.dataset.cat = c; b.onclick = () => load(c); nav.appendChild(b); });
load("all");
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js");
