const http = require("node:http");

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("Hello from {{SLUG}}!\n");
});

server.listen(3000, () => console.log("Listening on port 3000"));
