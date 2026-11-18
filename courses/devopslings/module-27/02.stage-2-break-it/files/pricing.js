// The pricing service checkout calls for every order. The grader steers it
// through two files: /tmp/price is the price it quotes, and /tmp/deny lists
// client addresses whose connections it drops.
const http = require("node:http");
const fs = require("node:fs");

const read = (f, d) => {
  try {
    return fs.readFileSync(f, "utf8").trim();
  } catch {
    return d;
  }
};

http
  .createServer((req, res) => {
    const ip = (req.socket.remoteAddress || "").replace(/^::ffff:/, "");
    if (read("/tmp/deny", "").split(/\s+/).includes(ip)) {
      req.socket.destroy();
      return;
    }
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ price: read("/tmp/price", "39.99") }));
  })
  .listen(8080);
