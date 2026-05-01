/**
 * @file Minimal Node.js HTTP server for the hao-backprop-test repository.
 *
 * This module is a deterministic test fixture used to validate Backprop
 * integration. It instantiates a single Node.js {@link http.Server} bound to
 * the loopback interface (127.0.0.1) on TCP port 3000 and returns a static
 * response (HTTP 200 OK, Content-Type `text/plain`, body `"Hello, World!\n"`)
 * for every request, regardless of HTTP method, URL path, headers, or body.
 *
 * The module has no `module.exports`; it is executed for its side effect of
 * starting the listener. Configuration (`hostname`, `port`) is hardcoded — to
 * change either value, edit this source file directly.
 *
 * @author hxu
 * @license MIT
 * @see {@link README.md} for the comprehensive project documentation.
 */

/**
 * Node.js built-in HTTP module. Provides the {@link http.Server},
 * {@link http.IncomingMessage}, and {@link http.ServerResponse} classes used
 * throughout this file. Loaded via CommonJS `require` because the project
 * uses the default CommonJS module system (no `"type": "module"` in
 * `package.json`).
 *
 * @const
 * @type {object}
 */
const http = require('http');

/**
 * Hostname / IP address the HTTP server binds to. The value `'127.0.0.1'`
 * targets the loopback interface, restricting connections to the local
 * machine. Hardcoded; modify this source line to bind to a different
 * interface (for example, `'0.0.0.0'` to accept connections from any
 * network interface).
 *
 * @const
 * @type {string}
 */
const hostname = '127.0.0.1';

/**
 * TCP port the HTTP server listens on. `3000` is a common development port
 * with no privileged-port requirement. Hardcoded; modify this source line to
 * change the listening port.
 *
 * @const
 * @type {number}
 */
const port = 3000;

/**
 * The HTTP server instance bound to {@link hostname} and {@link port}. Created
 * by `http.createServer`, which accepts the inline arrow function below as
 * its request handler.
 *
 * The request handler implements a static response: for every inbound HTTP
 * request it sets the response status to `200`, sets the `Content-Type`
 * header to `text/plain`, and writes the body `'Hello, World!\n'`. The
 * handler does not branch on `req.method` or `req.url`, so the same static
 * response is returned for every request — regardless of method, path,
 * headers, or body. This deterministic behavior is intentional and is what
 * makes the module suitable as a test fixture.
 *
 * @const
 * @type {http.Server}
 *
 * @param {http.IncomingMessage} req - The inbound HTTP request object.
 *   Unused by this handler but included to honor the
 *   `(req, res) => void` signature expected by `http.createServer`.
 * @param {http.ServerResponse} res - The outbound HTTP response object used
 *   to set the status code, response headers, and response body.
 * @returns {void} The request handler does not return a value; it writes
 *   the response and ends the stream via `res.end()`.
 *
 * @example
 * // Sending any HTTP request to the server returns the same static body:
 * //   GET / HTTP/1.1
 * //   Host: 127.0.0.1:3000
 * // -> 200 OK
 * //    Content-Type: text/plain
 * //
 * //    Hello, World!
 *
 * @see {@link README.md#api-reference}
 */
const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain');
  res.end('Hello, World!\n');
});

/**
 * Starts the HTTP server listening on {@link port} bound to {@link hostname}.
 * The third argument is the "ready callback" that fires once the TCP socket
 * has successfully bound and the server is accepting connections. The ready
 * callback emits a single startup-confirmation line to stdout in the form
 * `Server running at http://<hostname>:<port>/`, which is the only diagnostic
 * output produced by this module under normal operation.
 *
 * If the port is already in use, Node.js raises an `EADDRINUSE` error before
 * the ready callback fires; this module does not install an `error` handler,
 * so such errors propagate as unhandled exceptions and terminate the process.
 *
 * @returns {void} The ready callback does not return a value; its sole
 *   effect is the `console.log` invocation below.
 *
 * @example
 * // Expected stdout after invocation:
 * //   Server running at http://127.0.0.1:3000/
 */
server.listen(port, hostname, () => {
  console.log(`Server running at http://${hostname}:${port}/`);
});
