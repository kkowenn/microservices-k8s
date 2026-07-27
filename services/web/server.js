const http = require("http");

const PORT = process.env.PORT || 8080;
const API_URL = process.env.API_URL || "http://api";

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("ok");
    return;
  }

  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`
    <!DOCTYPE html>
    <html>
    <head><title>Demo App</title></head>
    <body>
      <h1>ArgoCD Demo</h1>
      <p>API endpoint: ${API_URL}</p>
      <div id="items"></div>
      <script>
        fetch('/api/items')
          .then(r => r.json())
          .then(items => {
            document.getElementById('items').innerHTML =
              '<ul>' + items.map(i => '<li>' + i.name + '</li>').join('') + '</ul>';
          });
      </script>
    </body>
    </html>
  `);
});

server.listen(PORT, () => {
  console.log(`Web service running on port ${PORT}`);
});
