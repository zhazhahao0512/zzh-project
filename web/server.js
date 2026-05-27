"use strict";

const http = require("http");
const fs = require("fs");
const fsp = require("fs/promises");
const path = require("path");
const { execFile } = require("child_process");

const repoRoot = path.resolve(__dirname, "..");
const publicRoot = path.join(__dirname, "public");
const configPath = path.join(repoRoot, "etsy-picture.config.json");
const scriptPath = path.join(repoRoot, "scripts", "etsy-picture.ps1");
function readCliOption(name) {
    const flag = `--${name}`;
    const inline = process.argv.find((arg) => arg.startsWith(`${flag}=`));
    if (inline) return inline.slice(flag.length + 1);
    const index = process.argv.indexOf(flag);
    return index >= 0 ? process.argv[index + 1] : "";
}

const host = process.env.AODING_PICTURE_WEB_HOST || readCliOption("host") || "0.0.0.0";
const port = Number.parseInt(process.env.AODING_PICTURE_WEB_PORT || readCliOption("port") || "8792", 10);
const maxUploadBytes = Number.parseInt(process.env.AODING_PICTURE_WEB_MAX_UPLOAD_MB || "600", 10) * 1024 * 1024;
const imageExtensions = new Set([".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff"]);
const ownerFileName = ".aoding-owner.json";
const ownerCookieName = "aoding_user";

function readJsonFile(filePath, fallback = null) {
    try {
        return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, ""));
    } catch (error) {
        if (error.code === "ENOENT") return fallback;
        throw error;
    }
}

async function writeTextFile(filePath, text) {
    await fsp.mkdir(path.dirname(filePath), { recursive: true });
    const tmpPath = `${filePath}.tmp`;
    await fsp.writeFile(tmpPath, text, "utf8");
    await fsp.rename(tmpPath, filePath);
}

function resolveWorkflowPath(value, basePath) {
    if (!value || !String(value).trim()) return "";
    return path.isAbsolute(value) ? path.resolve(value) : path.resolve(basePath, value);
}

function loadConfig() {
    const raw = readJsonFile(configPath, {});
    return {
        configPath,
        inputRoot: resolveWorkflowPath(raw.inputRoot || "PICTURE\\products", repoRoot),
        outputRoot: resolveWorkflowPath(raw.outputRoot || "PICTURE\\outputs", repoRoot),
        briefFile: raw.briefFile || "product.txt",
        generatedBriefFile: raw.generatedBriefFile || "product.inferred.json",
        readyMarker: raw.readyMarker || "ready.txt",
        completeMarkerFile: raw.completeMarkerFile || "automation.done.txt",
        promptSchemaVersion: raw.promptSchemaVersion || "",
        imageBackend: raw.imageBackend || "",
        codexImageModel: raw.codexImageModel || "",
        productIdentityMode: raw.productIdentityMode || "",
        requireImageReference: raw.requireImageReference === true,
        allowReferenceLimitedDrafts: raw.allowReferenceLimitedDrafts === true
    };
}

function safeSegment(value, fallback = "item") {
    const base = path.basename(String(value || fallback));
    const safe = base.replace(/[<>:"/\\|?*\x00-\x1f]/g, "_").replace(/\s+/g, "-").trim();
    if (!safe || safe === "." || safe === "..") {
        throw Object.assign(new Error("Invalid name."), { status: 400 });
    }
    return safe;
}

function normalizeUser(value) {
    const raw = String(value || "").trim();
    if (!raw) {
        throw Object.assign(new Error("Missing user name."), { status: 401 });
    }
    const safe = raw.replace(/[<>:"/\\|?*\x00-\x1f]/g, "_").replace(/\s+/g, "-").trim();
    if (!safe || safe === "." || safe === "..") {
        throw Object.assign(new Error("Invalid user name."), { status: 400 });
    }
    return safe.slice(0, 64);
}

function parseCookies(header) {
    const cookies = {};
    for (const part of String(header || "").split(";")) {
        const index = part.indexOf("=");
        if (index <= 0) continue;
        const key = part.slice(0, index).trim();
        const value = part.slice(index + 1).trim();
        if (!key) continue;
        cookies[key] = decodeURIComponent(value);
    }
    return cookies;
}

function getRequestUser(req, required = true) {
    const cookies = parseCookies(req.headers.cookie || "");
    const value = cookies[ownerCookieName] || req.headers["x-aoding-user"] || "";
    if (!value && !required) return "";
    return normalizeUser(value);
}

function sendUserCookie(res, user) {
    res.setHeader("Set-Cookie", `${ownerCookieName}=${encodeURIComponent(user)}; Path=/; Max-Age=31536000; SameSite=Lax`);
}

function isWithin(parent, child) {
    const parentFull = path.resolve(parent);
    const childFull = path.resolve(child);
    const relative = path.relative(parentFull, childFull);
    return relative === "" || (!!relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function getProductDir(cfg, productName) {
    const productDir = path.join(cfg.inputRoot, safeSegment(productName));
    if (!isWithin(cfg.inputRoot, productDir)) {
        throw Object.assign(new Error("Invalid product path."), { status: 400 });
    }
    return productDir;
}

function getProductOutputRoot(cfg, productName) {
    const outputDir = path.join(cfg.outputRoot, safeSegment(productName));
    if (!isWithin(cfg.outputRoot, outputDir)) {
        throw Object.assign(new Error("Invalid output path."), { status: 400 });
    }
    return outputDir;
}

function getRunDir(cfg, productName, version) {
    const safeVersion = safeSegment(version);
    if (!/^v\d+$/i.test(safeVersion)) {
        throw Object.assign(new Error("Invalid run version."), { status: 400 });
    }
    const outputRoot = getProductOutputRoot(cfg, productName);
    const runDir = path.join(outputRoot, safeVersion);
    if (!isWithin(outputRoot, runDir)) {
        throw Object.assign(new Error("Invalid run path."), { status: 400 });
    }
    return { version: safeVersion, runDir, outputRoot };
}

function readOwnerInfo(productDir, fallbackName) {
    const ownerPath = path.join(productDir, ownerFileName);
    const metadata = readJsonFile(ownerPath, null);
    if (metadata && metadata.owner) {
        return {
            owner: normalizeUser(metadata.owner),
            displayName: metadata.displayName || fallbackName,
            createdAt: metadata.createdAt || ""
        };
    }
    return {
        owner: "admin",
        displayName: fallbackName,
        createdAt: ""
    };
}

async function writeOwnerInfo(productDir, user, displayName) {
    await writeTextFile(path.join(productDir, ownerFileName), JSON.stringify({
        owner: normalizeUser(user),
        displayName: String(displayName || "").trim() || path.basename(productDir),
        createdAt: new Date().toISOString()
    }, null, 2) + "\n");
}

function assertProductOwner(cfg, productName, user) {
    const productDir = getProductDir(cfg, productName);
    if (!fs.existsSync(productDir)) {
        throw Object.assign(new Error("Product not found."), { status: 404 });
    }
    const ownerInfo = readOwnerInfo(productDir, productName);
    if (ownerInfo.owner !== user) {
        throw Object.assign(new Error("Product is not visible for this user."), { status: 403 });
    }
    return { productDir, ownerInfo };
}

function makeProductFolderName(cfg, user, displayName) {
    const base = safeSegment(displayName || `product-${Date.now()}`);
    const owner = safeSegment(user);
    const prefix = `${owner}__${base}`;
    let candidate = prefix;
    let index = 2;
    while (fs.existsSync(getProductDir(cfg, candidate))) {
        candidate = `${prefix}-${index}`;
        index++;
    }
    return candidate;
}

function defaultProductText(displayName) {
    return [
        `Product Name: ${displayName}`,
        "Category:",
        "Core Description:",
        "Materials / Colors:",
        "Target Customer:",
        "Style / Mood:",
        "Intro Text:",
        "Must Include:",
        "Avoid:",
        "Extra Notes:"
    ].join("\n") + "\n";
}

function getMime(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    if (ext === ".html") return "text/html; charset=utf-8";
    if (ext === ".css") return "text/css; charset=utf-8";
    if (ext === ".js") return "text/javascript; charset=utf-8";
    if (ext === ".json") return "application/json; charset=utf-8";
    if (ext === ".png") return "image/png";
    if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
    if (ext === ".webp") return "image/webp";
    if (ext === ".gif") return "image/gif";
    if (ext === ".svg") return "image/svg+xml";
    return "application/octet-stream";
}

function sendJson(res, status, value) {
    const body = JSON.stringify(value, null, 2);
    res.writeHead(status, {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": Buffer.byteLength(body),
        "Cache-Control": "no-store"
    });
    res.end(body);
}

function sendText(res, status, text) {
    res.writeHead(status, {
        "Content-Type": "text/plain; charset=utf-8",
        "Content-Length": Buffer.byteLength(text)
    });
    res.end(text);
}

async function serveFile(res, filePath) {
    const stat = await fsp.stat(filePath);
    res.writeHead(200, {
        "Content-Type": getMime(filePath),
        "Content-Length": stat.size,
        "Cache-Control": "no-store"
    });
    fs.createReadStream(filePath).pipe(res);
}

async function readBody(req) {
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
        size += chunk.length;
        if (size > maxUploadBytes) {
            throw Object.assign(new Error("Request is too large."), { status: 413 });
        }
        chunks.push(chunk);
    }
    return Buffer.concat(chunks);
}

async function readJsonBody(req) {
    const buffer = await readBody(req);
    if (!buffer.length) return {};
    return JSON.parse(buffer.toString("utf8"));
}

function parseContentDisposition(value) {
    const out = {};
    for (const part of String(value || "").split(";")) {
        const [rawKey, ...rest] = part.trim().split("=");
        if (!rawKey) continue;
        let val = rest.join("=");
        if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);
        out[rawKey.toLowerCase()] = val;
    }
    return out;
}

function parseMultipart(buffer, contentType) {
    const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || "");
    if (!match) throw Object.assign(new Error("Missing multipart boundary."), { status: 400 });
    const boundary = Buffer.from(`--${match[1] || match[2]}`);
    const result = { fields: {}, files: [] };
    let position = buffer.indexOf(boundary);
    while (position >= 0) {
        position += boundary.length;
        if (buffer[position] === 45 && buffer[position + 1] === 45) break;
        if (buffer[position] === 13 && buffer[position + 1] === 10) position += 2;
        const headerEnd = buffer.indexOf(Buffer.from("\r\n\r\n"), position);
        if (headerEnd < 0) break;
        const headersText = buffer.slice(position, headerEnd).toString("utf8");
        const headers = {};
        for (const line of headersText.split(/\r\n/)) {
            const idx = line.indexOf(":");
            if (idx > 0) headers[line.slice(0, idx).toLowerCase()] = line.slice(idx + 1).trim();
        }
        const contentStart = headerEnd + 4;
        const next = buffer.indexOf(boundary, contentStart);
        if (next < 0) break;
        let contentEnd = next;
        if (buffer[contentEnd - 2] === 13 && buffer[contentEnd - 1] === 10) contentEnd -= 2;
        const content = buffer.slice(contentStart, contentEnd);
        const disposition = parseContentDisposition(headers["content-disposition"]);
        if (disposition.name) {
            if (disposition.filename) {
                result.files.push({
                    field: disposition.name,
                    filename: disposition.filename,
                    contentType: headers["content-type"] || "application/octet-stream",
                    data: content
                });
            } else {
                result.fields[disposition.name] = content.toString("utf8");
            }
        }
        position = next;
    }
    return result;
}

async function readMultipartBody(req) {
    return parseMultipart(await readBody(req), req.headers["content-type"]);
}

async function saveUploadedImages(productDir, files, options = {}) {
    await fsp.mkdir(productDir, { recursive: true });
    const saved = [];
    const prefix = options.prefix ? safeSegment(options.prefix) : "";
    let index = 1;
    for (const file of files || []) {
        const ext = path.extname(file.filename || "").toLowerCase();
        if (!imageExtensions.has(ext)) continue;
        let name = safeSegment(file.filename || `source-${Date.now()}${ext}`);
        if (prefix) {
            name = safeSegment(`${prefix}-${Date.now()}-${index}-${name}`);
        }
        const dest = path.join(productDir, name);
        if (!isWithin(productDir, dest)) continue;
        await fsp.writeFile(dest, file.data);
        saved.push(name);
        index++;
    }
    return saved;
}

async function listImageFiles(dir, urlPrefix) {
    let entries = [];
    try {
        entries = await fsp.readdir(dir, { withFileTypes: true });
    } catch {
        return [];
    }
    const rows = [];
    for (const entry of entries) {
        if (!entry.isFile()) continue;
        const ext = path.extname(entry.name).toLowerCase();
        if (!imageExtensions.has(ext) && ext !== ".png") continue;
        const fullPath = path.join(dir, entry.name);
        const stat = await fsp.stat(fullPath);
        rows.push({
            name: entry.name,
            bytes: stat.size,
            modifiedAt: stat.mtime.toISOString(),
            url: `${urlPrefix}/${encodeURIComponent(entry.name)}`
        });
    }
    return rows.sort((a, b) => a.name.localeCompare(b.name, "zh-Hans-CN", { numeric: true }));
}

async function listRuns(cfg, productName) {
    const outputRoot = getProductOutputRoot(cfg, productName);
    let entries = [];
    try {
        entries = await fsp.readdir(outputRoot, { withFileTypes: true });
    } catch {
        return [];
    }
    const runs = [];
    for (const entry of entries) {
        if (!entry.isDirectory() || !/^v\d+$/i.test(entry.name)) continue;
        const runDir = path.join(outputRoot, entry.name);
        const run = readJsonFile(path.join(runDir, "run.json"), null);
        const outputs = await listImageFiles(runDir, `/api/products/${encodeURIComponent(productName)}/outputs/${encodeURIComponent(entry.name)}`);
        runs.push({
            version: entry.name,
            runDir,
            status: run ? run.status : "missing_run_json",
            promptSchemaVersion: run ? run.promptSchemaVersion : "",
            referencePolicy: run ? run.referencePolicy : null,
            expectedFiles: run ? run.expectedFiles || [] : [],
            missingFiles: run ? run.missingFiles || [] : [],
            outputs
        });
    }
    return runs.sort((a, b) => b.version.localeCompare(a.version, "en", { numeric: true }));
}

async function getProductSummary(cfg, productName) {
    const productDir = getProductDir(cfg, productName);
    const ownerInfo = readOwnerInfo(productDir, productName);
    const productPath = path.join(productDir, cfg.briefFile);
    const inferredPath = path.join(productDir, cfg.generatedBriefFile);
    const text = await fsp.readFile(productPath, "utf8").catch(() => "");
    const inferred = readJsonFile(inferredPath, null);
    const sourceImages = await listImageFiles(productDir, `/api/products/${encodeURIComponent(productName)}/source`);
    const runs = await listRuns(cfg, productName);
    return {
        name: productName,
        displayName: ownerInfo.displayName,
        owner: ownerInfo.owner,
        productPath,
        productText: text,
        ready: fs.existsSync(path.join(productDir, cfg.readyMarker)),
        done: fs.existsSync(path.join(productDir, cfg.completeMarkerFile)),
        inferredExists: !!inferred,
        inferredSummary: inferred ? {
            schemaVersion: inferred.schemaVersion || "",
            productName: inferred.productName || "",
            visualIdentity: inferred.visualIdentity || ""
        } : null,
        sourceImages,
        sourceImageCount: sourceImages.length,
        latestRun: runs[0] || null,
        runs
    };
}

async function listProducts(cfg, user) {
    let entries = [];
    try {
        entries = await fsp.readdir(cfg.inputRoot, { withFileTypes: true });
    } catch {
        return [];
    }
    const products = [];
    for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const productDir = getProductDir(cfg, entry.name);
        const ownerInfo = readOwnerInfo(productDir, entry.name);
        if (ownerInfo.owner !== user) continue;
        products.push(await getProductSummary(cfg, entry.name));
    }
    return products.sort((a, b) => (a.displayName || a.name).localeCompare((b.displayName || b.name), "zh-Hans-CN", { numeric: true }));
}

async function filterScanForUser(cfg, scanResult, user) {
    const result = { ...scanResult };
    for (const key of ["pending", "skipped", "stalled"]) {
        const rows = Array.isArray(result[key]) ? result[key] : [];
        result[key] = rows.filter((item) => {
            const productName = item && item.productName ? String(item.productName) : "";
            if (!productName) return false;
            const productDir = getProductDir(cfg, productName);
            if (!fs.existsSync(productDir)) return false;
            return readOwnerInfo(productDir, productName).owner === user;
        });
    }
    return result;
}

function runWorkflow(command, options = {}) {
    const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-Command", command];
    if (command === "scan") args.push("-NoLinkSync");
    if (options.product) args.push("-Product", options.product);
    if (options.runDir) args.push("-RunDir", options.runDir);
    return new Promise((resolve, reject) => {
        execFile("powershell", args, { cwd: repoRoot, windowsHide: true, maxBuffer: 1024 * 1024 * 40 }, (error, stdout, stderr) => {
            if (error) {
                reject(Object.assign(new Error((stderr || stdout || error.message).trim()), { status: 500 }));
                return;
            }
            try {
                resolve(JSON.parse(stdout));
            } catch {
                resolve({ status: "ok", output: stdout.trim() });
            }
        });
    });
}

async function handleApi(req, res, method, parts) {
    const cfg = loadConfig();
    if (method === "GET" && parts[1] === "health" && parts.length === 2) {
        return sendJson(res, 200, { status: "ok", port, user: getRequestUser(req, false), inputRoot: cfg.inputRoot, outputRoot: cfg.outputRoot, config: cfg });
    }
    if (parts[1] === "session" && parts.length === 2 && method === "POST") {
        const body = await readJsonBody(req);
        const user = normalizeUser(body.userName || body.user || "");
        sendUserCookie(res, user);
        return sendJson(res, 200, { user });
    }
    if (parts[1] === "session" && parts.length === 2 && method === "GET") {
        return sendJson(res, 200, { user: getRequestUser(req, false) });
    }
    const user = getRequestUser(req);
    if (method === "GET" && parts[1] === "scan" && parts.length === 2) {
        return sendJson(res, 200, await filterScanForUser(cfg, await runWorkflow("scan"), user));
    }
    if (parts[1] === "products" && parts.length === 2 && method === "GET") {
        return sendJson(res, 200, { user, products: await listProducts(cfg, user) });
    }
    if (parts[1] === "products" && parts.length === 2 && method === "POST") {
        const multipart = await readMultipartBody(req);
        const displayName = safeSegment(multipart.fields.productName || `product-${Date.now()}`);
        const name = makeProductFolderName(cfg, user, displayName);
        const productDir = getProductDir(cfg, name);
        await fsp.mkdir(productDir, { recursive: true });
        await writeOwnerInfo(productDir, user, displayName);
        const submittedText = String(multipart.fields.productText || "");
        const productText = submittedText.trim() ? submittedText : defaultProductText(displayName);
        await writeTextFile(path.join(productDir, cfg.briefFile), productText);
        await writeTextFile(path.join(productDir, cfg.readyMarker), "ready\n");
        await saveUploadedImages(productDir, multipart.files);
        return sendJson(res, 201, { product: await getProductSummary(cfg, name) });
    }

    if (parts[1] !== "products" || parts.length < 3) {
        throw Object.assign(new Error("Unknown API route."), { status: 404 });
    }

    const productName = safeSegment(decodeURIComponent(parts[2]));
    const { productDir } = assertProductOwner(cfg, productName, user);

    if (method === "DELETE" && parts.length === 3) {
        const outputDir = getProductOutputRoot(cfg, productName);
        await fsp.rm(productDir, { recursive: true, force: true });
        await fsp.rm(outputDir, { recursive: true, force: true });
        return sendJson(res, 200, { ok: true, deletedProduct: productName });
    }
    if (method === "GET" && parts.length === 3) {
        return sendJson(res, 200, { product: await getProductSummary(cfg, productName) });
    }
    if (method === "PUT" && parts.length === 3) {
        const body = await readJsonBody(req);
        if (body.productText !== undefined) {
            await writeTextFile(path.join(productDir, cfg.briefFile), String(body.productText));
        }
        if (body.ready === true) {
            await writeTextFile(path.join(productDir, cfg.readyMarker), "ready\n");
        } else if (body.ready === false) {
            await fsp.rm(path.join(productDir, cfg.readyMarker), { force: true });
        }
        return sendJson(res, 200, { product: await getProductSummary(cfg, productName) });
    }
    if (method === "POST" && parts[3] === "images" && parts.length === 4) {
        const multipart = await readMultipartBody(req);
        const saved = await saveUploadedImages(productDir, multipart.files);
        return sendJson(res, 200, { saved, product: await getProductSummary(cfg, productName) });
    }
    if (method === "DELETE" && parts[3] === "images" && parts.length === 5) {
        const fileName = safeSegment(decodeURIComponent(parts[4]));
        const filePath = path.join(productDir, fileName);
        if (!isWithin(productDir, filePath)) throw Object.assign(new Error("Invalid image path."), { status: 400 });
        await fsp.rm(filePath, { force: true });
        return sendJson(res, 200, { ok: true, product: await getProductSummary(cfg, productName) });
    }
    if (method === "GET" && parts[3] === "source" && parts.length === 5) {
        const fileName = safeSegment(decodeURIComponent(parts[4]));
        const filePath = path.join(productDir, fileName);
        if (!isWithin(productDir, filePath)) throw Object.assign(new Error("Invalid source path."), { status: 400 });
        return serveFile(res, filePath);
    }
    if (method === "POST" && parts[3] === "actions" && parts.length === 5) {
        const action = parts[4];
        if (action !== "prepare") throw Object.assign(new Error("Unsupported action."), { status: 400 });
        return sendJson(res, 200, await runWorkflow(action, { product: productName }));
    }
    if (method === "GET" && parts[3] === "runs" && parts.length === 4) {
        return sendJson(res, 200, { runs: await listRuns(cfg, productName) });
    }
    if (method === "DELETE" && parts[3] === "runs" && parts.length === 5) {
        const { version, runDir } = getRunDir(cfg, productName, decodeURIComponent(parts[4]));
        await fsp.rm(runDir, { recursive: true, force: true });
        return sendJson(res, 200, { ok: true, deletedRun: version, product: await getProductSummary(cfg, productName) });
    }
    if (method === "DELETE" && parts[3] === "runs" && parts.length === 7 && parts[5] === "images") {
        const { version, runDir } = getRunDir(cfg, productName, decodeURIComponent(parts[4]));
        const fileName = safeSegment(decodeURIComponent(parts[6]));
        const filePath = path.join(runDir, fileName);
        if (!isWithin(runDir, filePath)) throw Object.assign(new Error("Invalid output image path."), { status: 400 });
        const ext = path.extname(fileName).toLowerCase();
        if (!imageExtensions.has(ext) && ext !== ".png") {
            throw Object.assign(new Error("Unsupported output image type."), { status: 400 });
        }
        await fsp.rm(filePath, { force: true });
        return sendJson(res, 200, { ok: true, deletedRun: version, deletedImage: fileName, product: await getProductSummary(cfg, productName) });
    }
    if (parts[3] === "runs" && parts.length === 6 && method === "POST") {
        const { runDir } = getRunDir(cfg, productName, decodeURIComponent(parts[4]));
        if (parts[5] === "generate") return sendJson(res, 200, await runWorkflow("generate", { runDir }));
        if (parts[5] === "validate") return sendJson(res, 200, await runWorkflow("validate", { runDir }));
    }
    if (method === "GET" && parts[3] === "outputs" && parts.length === 6) {
        const { runDir } = getRunDir(cfg, productName, decodeURIComponent(parts[4]));
        const fileName = safeSegment(decodeURIComponent(parts[5]));
        const filePath = path.join(runDir, fileName);
        if (!isWithin(runDir, filePath)) throw Object.assign(new Error("Invalid output path."), { status: 400 });
        return serveFile(res, filePath);
    }
    throw Object.assign(new Error("Unknown API route."), { status: 404 });
}

async function handleRequest(req, res) {
    try {
        const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
        const pathname = decodeURIComponent(url.pathname);
        const method = req.method || "GET";
        const parts = pathname.split("/").filter(Boolean);

        if (parts[0] === "api") {
            return await handleApi(req, res, method, parts);
        }

        const requested = pathname === "/" ? "index.html" : pathname.replace(/^\/+/, "");
        const filePath = path.join(publicRoot, requested);
        if (!isWithin(publicRoot, filePath)) {
            return sendText(res, 403, "Forbidden");
        }
        return await serveFile(res, filePath);
    } catch (error) {
        const status = error.status || 500;
        if (status >= 500) console.error(error);
        return sendJson(res, status, { status: "error", message: error.message || String(error) });
    }
}

http.createServer(handleRequest).listen(port, host, () => {
    console.log(`AODING ETSY picture LAN console: http://${host}:${port}`);
});
