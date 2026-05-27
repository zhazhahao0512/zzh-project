"use strict";

const state = {
  user: "",
  products: [],
  scan: null,
  currentProductName: "",
  currentRunVersion: "",
  renderedProductName: "",
  productTextDirty: false,
  pendingConfirm: null,
  pendingConfirmTimer: null
};

const dom = {
  healthLine: document.querySelector("#health-line"),
  userForm: document.querySelector("#user-form"),
  userNameInput: document.querySelector("#user-name-input"),
  scanButton: document.querySelector("#scan-button"),
  refreshButton: document.querySelector("#refresh-button"),
  productSearch: document.querySelector("#product-search"),
  newProductToggle: document.querySelector("#new-product-toggle"),
  newProductForm: document.querySelector("#new-product-form"),
  productList: document.querySelector("#product-list"),
  emptyState: document.querySelector("#empty-state"),
  workspace: document.querySelector("#product-workspace"),
  productTitle: document.querySelector("#product-title"),
  productStatus: document.querySelector("#product-status"),
  productText: document.querySelector("#product-text"),
  saveProductButton: document.querySelector("#save-product-button"),
  prepareButton: document.querySelector("#prepare-button"),
  deleteProductButton: document.querySelector("#delete-product-button"),
  readyCheckbox: document.querySelector("#ready-checkbox"),
  imageForm: document.querySelector("#image-form"),
  imageInput: document.querySelector("#image-input"),
  sourceGrid: document.querySelector("#source-grid"),
  outputGrid: document.querySelector("#output-grid"),
  outputCount: document.querySelector("#output-count"),
  runList: document.querySelector("#run-list"),
  actionOutput: document.querySelector("#action-output")
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    ...options
  });
  const text = await response.text();
  let payload;
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    payload = { status: "error", message: text };
  }
  if (!response.ok) {
    throw new Error(payload.message || `HTTP ${response.status}`);
  }
  return payload;
}

function jsonOptions(body, method = "POST") {
  return {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body)
  };
}

function currentProduct() {
  return state.products.find((product) => product.name === state.currentProductName) || null;
}

function productLabel(product) {
  return product ? product.displayName || product.name : "";
}

function scanState(productName) {
  const rows = state.scan && Array.isArray(state.scan.pending)
    ? [...state.scan.pending, ...(state.scan.skipped || []), ...(state.scan.stalled || [])]
    : [];
  return rows.find((item) => item.productName === productName) || null;
}

function statusLabel(product) {
  const scan = scanState(product.name);
  if (scan) return scan.status === "skipped" ? scan.reason : scan.status;
  if (product.latestRun) return product.latestRun.status || "run";
  if (product.done) return "complete";
  if (!product.ready) return "missing_ready";
  return "ready";
}

function statusClass(value) {
  const text = String(value || "").toLowerCase();
  if (text.includes("complete") || text.includes("marker")) return "complete";
  if (text.includes("pending") || text.includes("ready")) return "pending";
  if (text.includes("review") || text.includes("needs")) return "review";
  if (text.includes("blocked") || text.includes("missing") || text.includes("failed")) return "blocked";
  return "default";
}

function setMessage(value) {
  dom.actionOutput.textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2);
}

function clearPendingConfirm() {
  if (state.pendingConfirmTimer) {
    window.clearTimeout(state.pendingConfirmTimer);
    state.pendingConfirmTimer = null;
  }
  if (state.pendingConfirm && state.pendingConfirm.button) {
    state.pendingConfirm.button.textContent = state.pendingConfirm.originalText;
    state.pendingConfirm.button.classList.remove("confirm-delete");
  }
  state.pendingConfirm = null;
}

function armDeleteButton(button, key) {
  if (state.pendingConfirm && state.pendingConfirm.key === key) {
    clearPendingConfirm();
    return true;
  }
  clearPendingConfirm();
  state.pendingConfirm = {
    key,
    button,
    originalText: button.textContent
  };
  button.textContent = "确认删除";
  button.classList.add("confirm-delete");
  state.pendingConfirmTimer = window.setTimeout(clearPendingConfirm, 5000);
  return false;
}

function renderProductList() {
  const query = dom.productSearch.value.trim().toLowerCase();
  dom.productList.innerHTML = "";

  for (const product of state.products) {
    const label = productLabel(product);
    const searchable = `${label} ${product.name}`.toLowerCase();
    if (query && !searchable.includes(query)) continue;
    const status = statusLabel(product);
    const button = document.createElement("button");
    button.type = "button";
    button.className = `product-row ${product.name === state.currentProductName ? "active" : ""}`;
    button.innerHTML = `
      <strong>${escapeHtml(label)}</strong>
      <span class="product-meta">
        <span class="count-chip">${product.sourceImageCount || 0} 源图</span>
        <span class="status-chip ${product.ready ? "complete" : "blocked"}">${product.ready ? "ready" : "no ready"}</span>
        <span class="status-chip ${statusClass(status)}">${escapeHtml(status)}</span>
      </span>
    `;
    button.addEventListener("click", () => {
      if (state.currentProductName !== product.name) {
        state.productTextDirty = false;
      }
      state.currentProductName = product.name;
      state.currentRunVersion = product.latestRun ? product.latestRun.version : "";
      renderAll();
    });
    dom.productList.append(button);
  }
}

function renderImages(container, images, emptyText, options = {}) {
  container.innerHTML = "";
  if (!images || !images.length) {
    const empty = document.createElement("div");
    empty.className = "muted-line";
    empty.textContent = emptyText;
    container.append(empty);
    return;
  }

  for (const image of images) {
    const tile = document.createElement("div");
    tile.className = "image-tile";
    const deleteAction = options.onDelete
      ? `<button class="mini-danger" type="button" data-delete-image="${escapeAttr(image.name)}">删除</button>`
      : "";
    tile.innerHTML = `
      <a class="image-preview" href="${image.url}" target="_blank" rel="noopener">
        <img src="${image.url}" alt="${escapeAttr(image.name)}">
      </a>
      <div class="caption">
        <span title="${escapeAttr(image.name)}">${escapeHtml(image.name)}</span>
        <span class="tile-actions">
          <a class="mini-link" href="${image.url}" download="${escapeAttr(image.name)}">下载</a>
          ${deleteAction}
        </span>
      </div>
    `;
    const deleteButton = tile.querySelector("[data-delete-image]");
    if (deleteButton) {
      deleteButton.addEventListener("click", () => options.onDelete(image.name, deleteButton).catch((error) => setMessage(error.message)));
    }
    container.append(tile);
  }
}

function renderRuns(product) {
  const runs = product.runs || [];
  dom.runList.innerHTML = "";
  if ((!state.currentRunVersion || !runs.some((run) => run.version === state.currentRunVersion)) && runs[0]) {
    state.currentRunVersion = runs[0].version;
  }
  if (!runs.length) {
    dom.runList.innerHTML = `<p class="muted-line">暂无运行版本</p>`;
    return;
  }

  for (const run of runs) {
    const row = document.createElement("div");
    row.className = `run-row ${run.version === state.currentRunVersion ? "active" : ""}`;
    const selectButton = document.createElement("button");
    selectButton.type = "button";
    selectButton.className = "run-select";
    selectButton.innerHTML = `
      <strong>${escapeHtml(run.version)}</strong>
      <span class="status-chip ${statusClass(run.status)}">${escapeHtml(run.status || "")}</span>
      <span class="count-chip">${(run.outputs || []).length} PNG</span>
    `;
    selectButton.addEventListener("click", () => {
      state.currentRunVersion = run.version;
      renderAll();
    });
    const deleteButton = document.createElement("button");
    deleteButton.type = "button";
    deleteButton.className = "mini-danger";
    deleteButton.textContent = "删除版本";
    deleteButton.addEventListener("click", () => deleteRun(run.version, deleteButton).catch((error) => setMessage(error.message)));
    row.append(selectButton, deleteButton);
    dom.runList.append(row);
  }
}

function renderProduct() {
  const product = currentProduct();
  if (!product) {
    dom.emptyState.textContent = state.user ? "当前用户暂无产品" : "先输入用户名";
    dom.emptyState.classList.remove("hidden");
    dom.workspace.classList.add("hidden");
    return;
  }

  dom.emptyState.classList.add("hidden");
  dom.workspace.classList.remove("hidden");
  dom.productTitle.textContent = productLabel(product);

  const status = statusLabel(product);
  const latestRunText = product.latestRun ? `最新 run: ${product.latestRun.version} / ${product.latestRun.status}` : "暂无 run";
  dom.productStatus.textContent = `${status} · ${product.sourceImageCount || 0} 张源图 · ${latestRunText}`;
  dom.readyCheckbox.checked = !!product.ready;
  const productChanged = state.renderedProductName !== product.name;
  if (productChanged || !state.productTextDirty) {
    dom.productText.value = product.productText || "";
  }
  state.renderedProductName = product.name;

  renderImages(dom.sourceGrid, product.sourceImages, "暂无产品源图", { onDelete: deleteSourceImage });
  renderRuns(product);

  const activeRun = (product.runs || []).find((run) => run.version === state.currentRunVersion) || product.latestRun;
  const outputs = activeRun ? activeRun.outputs || [] : [];
  dom.outputCount.textContent = outputs.length ? `${outputs.length} 张` : "无输出";
  renderImages(dom.outputGrid, outputs, "暂无输出图", { onDelete: deleteOutputImage });
}

function renderAll() {
  renderProductList();
  renderProduct();
}

async function loadAll(keepSelection = true) {
  if (!state.user) {
    renderLoggedOut();
    return;
  }
  const health = await api("/api/health");
  dom.healthLine.textContent = `${health.config.inputRoot} -> ${health.config.outputRoot} · 当前用户：${state.user}`;

  const productsPayload = await api("/api/products");
  state.products = productsPayload.products || [];

  if (!keepSelection || !state.products.some((product) => product.name === state.currentProductName)) {
    const first = state.products[0];
    state.currentProductName = first ? first.name : "";
    state.currentRunVersion = first && first.latestRun ? first.latestRun.version : "";
    state.productTextDirty = false;
  }
  renderAll();
}

function renderLoggedOut() {
  state.products = [];
  dom.healthLine.textContent = "输入用户名后，只显示该用户名下的产品。";
  dom.productList.innerHTML = "";
  dom.emptyState.textContent = "先输入用户名";
  dom.emptyState.classList.remove("hidden");
  dom.workspace.classList.add("hidden");
}

async function setSession(userName, options = {}) {
  clearPendingConfirm();
  const nextUser = String(userName || "").trim();
  if (!nextUser) {
    renderLoggedOut();
    return;
  }
  const payload = await api("/api/session", jsonOptions({ userName: nextUser }));
  state.user = payload.user;
  dom.userNameInput.value = payload.user;
  localStorage.setItem("aodingPictureUser", payload.user);
  state.currentProductName = "";
  state.currentRunVersion = "";
  state.renderedProductName = "";
  state.productTextDirty = false;
  await loadAll(false);
  if (!options.quiet) setMessage(`已切换到用户：${payload.user}`);
}

async function refreshCurrentProduct() {
  const product = currentProduct();
  if (!product) return;
  const payload = await api(`/api/products/${encodeURIComponent(product.name)}`);
  replaceProduct(payload.product);
  if (!state.currentRunVersion && payload.product.latestRun) {
    state.currentRunVersion = payload.product.latestRun.version;
  }
}

async function saveProduct(options = {}) {
  const product = currentProduct();
  if (!product) return;
  const payload = await api(`/api/products/${encodeURIComponent(product.name)}`, jsonOptions({
    productText: dom.productText.value,
    ready: dom.readyCheckbox.checked
  }, "PUT"));
  state.productTextDirty = false;
  replaceProduct(payload.product);
  if (!options.quiet) {
    setMessage("已保存 product.txt 和 ready.txt 状态。");
  }
}

async function prepareProduct() {
  await saveProduct({ quiet: true });
  const product = currentProduct();
  if (!product) return;
  const payload = await api(`/api/products/${encodeURIComponent(product.name)}/actions/prepare`, { method: "POST" });
  setMessage(payload);
  await refreshCurrentProduct();
}

function replaceProduct(product) {
  const index = state.products.findIndex((item) => item.name === product.name);
  if (index >= 0) state.products[index] = product;
  else state.products.push(product);
  renderAll();
}

async function createProduct(event) {
  event.preventDefault();
  const payload = await api("/api/products", { method: "POST", body: new FormData(dom.newProductForm) });
  dom.newProductForm.reset();
  dom.newProductForm.classList.add("hidden");
  state.currentProductName = payload.product.name;
  state.currentRunVersion = payload.product.latestRun ? payload.product.latestRun.version : "";
  state.productTextDirty = false;
  replaceProduct(payload.product);
}

async function uploadImages(event) {
  event.preventDefault();
  const product = currentProduct();
  if (!product || !dom.imageInput.files.length) return;
  const form = new FormData();
  for (const file of dom.imageInput.files) form.append("images", file);
  const payload = await api(`/api/products/${encodeURIComponent(product.name)}/images`, { method: "POST", body: form });
  dom.imageForm.reset();
  replaceProduct(payload.product);
  setMessage(`产品源图已上传：${(payload.saved || []).join(", ")}`);
}

async function deleteSourceImage(name, button) {
  const product = currentProduct();
  if (!product) return;
  if (!armDeleteButton(button, `source:${product.name}:${name}`)) return;
  const payload = await api(`/api/products/${encodeURIComponent(product.name)}/images/${encodeURIComponent(name)}`, { method: "DELETE" });
  clearPendingConfirm();
  replaceProduct(payload.product);
  setMessage(`已删除源图：${name}`);
}

async function deleteOutputImage(name, button) {
  const product = currentProduct();
  if (!product || !state.currentRunVersion) return;
  if (!armDeleteButton(button, `output:${product.name}:${state.currentRunVersion}:${name}`)) return;
  const payload = await api(`/api/products/${encodeURIComponent(product.name)}/runs/${encodeURIComponent(state.currentRunVersion)}/images/${encodeURIComponent(name)}`, { method: "DELETE" });
  clearPendingConfirm();
  replaceProduct(payload.product);
  setMessage(`已删除输出图：${name}`);
}

async function deleteRun(version, button) {
  const product = currentProduct();
  if (!product) return;
  if (!armDeleteButton(button, `run:${product.name}:${version}`)) return;
  const payload = await api(`/api/products/${encodeURIComponent(product.name)}/runs/${encodeURIComponent(version)}`, { method: "DELETE" });
  clearPendingConfirm();
  const nextProduct = payload.product;
  state.currentRunVersion = nextProduct && nextProduct.latestRun ? nextProduct.latestRun.version : "";
  replaceProduct(nextProduct);
  setMessage(`已删除版本：${version}`);
}

async function deleteCurrentProduct() {
  const product = currentProduct();
  if (!product) return;
  const label = productLabel(product);
  if (!armDeleteButton(dom.deleteProductButton, `product:${product.name}`)) {
    setMessage(`再次点击“确认删除”将删除整个产品：${label}`);
    return;
  }
  await api(`/api/products/${encodeURIComponent(product.name)}`, { method: "DELETE" });
  clearPendingConfirm();
  state.currentProductName = "";
  state.currentRunVersion = "";
  state.renderedProductName = "";
  state.productTextDirty = false;
  await loadAll(false);
  setMessage(`已删除产品：${label}`);
}

async function runScan() {
  const payload = await api("/api/scan");
  state.scan = payload;
  setMessage(payload);
  await loadAll(true);
}

function escapeHtml(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/'/g, "&#39;");
}

dom.newProductToggle.addEventListener("click", () => dom.newProductForm.classList.toggle("hidden"));
dom.userForm.addEventListener("submit", (event) => {
  event.preventDefault();
  setSession(dom.userNameInput.value).catch((error) => setMessage(error.message));
});
dom.newProductForm.addEventListener("submit", (event) => createProduct(event).catch((error) => setMessage(error.message)));
dom.productSearch.addEventListener("input", renderProductList);
dom.productText.addEventListener("input", () => {
  state.productTextDirty = true;
});
dom.refreshButton.addEventListener("click", () => loadAll(true).catch((error) => setMessage(error.message)));
dom.scanButton.addEventListener("click", () => runScan().catch((error) => setMessage(error.message)));
dom.saveProductButton.addEventListener("click", () => saveProduct().catch((error) => setMessage(error.message)));
dom.prepareButton.addEventListener("click", () => prepareProduct().catch((error) => setMessage(error.message)));
dom.deleteProductButton.addEventListener("click", () => deleteCurrentProduct().catch((error) => setMessage(error.message)));
dom.imageForm.addEventListener("submit", (event) => uploadImages(event).catch((error) => setMessage(error.message)));

const savedUser = localStorage.getItem("aodingPictureUser") || "";
dom.userNameInput.value = savedUser;
if (savedUser) {
  setSession(savedUser, { quiet: true }).catch((error) => {
    localStorage.removeItem("aodingPictureUser");
    state.user = "";
    renderLoggedOut();
    setMessage(error.message);
  });
} else {
  renderLoggedOut();
}
