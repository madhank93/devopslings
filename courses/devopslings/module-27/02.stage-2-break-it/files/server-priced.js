const http = require("node:http");
const os = require("node:os");

const VERSION = "__VERSION__";

// Every order is priced by the pricing service.
const PRICING = "http://172.29.22.40:8080/price";

function price(cb) {
  let done = false;
  const once = (err, p) => {
    if (!done) {
      done = true;
      cb(err, p);
    }
  };
  const req = http.get(PRICING, { timeout: 1000 }, (res) => {
    let body = "";
    res.on("data", (c) => (body += c));
    res.on("end", () => {
      try {
        once(null, JSON.parse(body).price);
      } catch (e) {
        once(e);
      }
    });
  });
  req.on("timeout", () => req.destroy(new Error("pricing timed out")));
  req.on("error", (e) => once(e));
}

http
  .createServer((req, res) => {
    res.setHeader("content-type", "application/json");
    if (req.url === "/health") {
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    price((err, p) => {
      if (err) {
        res.statusCode = 502;
        res.end(JSON.stringify({ error: "pricing unavailable", node: os.hostname() }));
        return;
      }
      res.end(JSON.stringify({ version: VERSION, node: os.hostname(), price: p }));
    });
  })
  .listen(8080);
