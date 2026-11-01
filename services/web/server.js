const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, char => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[char]);
}

function createServer(apiURL = process.env.API_URL || "/api") {
  const client = fs.readFileSync(path.join(__dirname, "client.js"));
  return http.createServer((req, res) => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.writeHead(405, { Allow: "GET, HEAD" });
      res.end();
      return;
    }
    if (req.url === "/health") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("ok");
      return;
    }
    if (req.url === "/client.js") {
      res.writeHead(200, { "Content-Type": "application/javascript; charset=utf-8" });
      res.end(client);
      return;
    }
    if (req.url !== "/") {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'",
      "X-Content-Type-Options": "nosniff",
    });
    res.end(`<!DOCTYPE html>
<html>
<head><title>Demo App</title><script src="/client.js" defer></script></head>
<body>
  <h1>Microservices K8s</h1>
  <p>API endpoint: ${escapeHTML(apiURL)}</p>
  <div id="items" role="status">Loading items…</div>
</body>
</html>`);
  });
}

if (require.main === module) {
  const server = createServer();
  server.listen(process.env.PORT || 3000, () => {
    console.log(`Web service running on port ${server.address().port}`);
  });
}

module.exports = { createServer };
