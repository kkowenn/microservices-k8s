const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
const { loadItems } = require("./client");
const { createServer } = require("./server");

function element(tag) {
  return { tag, children: [], textContent: "", appendChild(child) { this.children.push(child); },
    replaceChildren(...children) { this.children = children; } };
}

test("database HTML is rendered as text without parsing markup", async () => {
  const target = element("div");
  const payload = '<img src=x onerror="alert(1)">';
  const context = { document: { createElement: element, getElementById: () => target },
    fetch: async () => ({ ok: true, json: async () => [{name: payload}] }), module: {exports:{}} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "client.js"), "utf8"), context);
  await context.module.exports.loadItems(target, context.fetch);
  const entry = target.children[0].children[0];
  assert.equal(entry.tag, "li");
  assert.equal(entry.textContent, payload);
  assert.equal(entry.innerHTML, undefined);
  assert.equal(entry.children.length, 0);
});

test("failed or malformed API responses display an error", async () => {
  for (const fetchItems of [async () => ({ok:false}), async () => {throw Error("offline");},
    async () => ({ok:true, json:async()=>({error:"bad"})})]) {
    const target = element("div");
    await loadItems(target, fetchItems);
    assert.match(target.textContent, /Unable to load items/);
  }
});

test("server escapes configuration, serves client and rejects unknown paths", async t => {
  const server = createServer('<script>alert("config")</script>');
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const response = await fetch(base);
  const html = await response.text();
  assert.ok(!html.includes('<script>alert("config")'));
  assert.ok(html.includes("&lt;script&gt;"));
  assert.match(response.headers.get("content-security-policy"), /script-src 'self'/);
  assert.match(await (await fetch(`${base}/client.js`)).text(), /entry.textContent = item.name/);
  assert.equal((await fetch(`${base}/missing`)).status, 404);
  assert.equal((await fetch(base, {method:"POST"})).status, 405);
});
