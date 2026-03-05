/**
 * @module server
 * @description A minimal HTTP server that listens on a configurable hostname and port,
 * responding to all incoming requests with a plain-text "Hello, World!" message.
 * @author hxu
 * @version 1.0.0
 * @license MIT
 * @see {@link https://nodejs.org/api/http.html} Node.js HTTP module documentation
 */

// Import the built-in Node.js HTTP module to create and manage an HTTP server without external dependencies
const http = require('http');

/**
 * @const {string}
 * @description The server's bind address, set to the IPv4 loopback interface,
 * restricting connections to the local machine only.
 */
const hostname = '127.0.0.1'; // Bind exclusively to the loopback interface to prevent remote network access

/**
 * @const {number}
 * @description The TCP port number on which the server listens for incoming connections.
 */
const port = 3000; // Use port 3000 as the default listening port for local development

/**
 * @description Creates an HTTP server instance with a request handler callback that
 * processes all incoming HTTP requests. The handler responds identically to all HTTP
 * methods and all URL paths with a plain-text greeting.
 * @type {http.Server}
 * @param {http.IncomingMessage} req - The incoming HTTP request object containing method, URL, and headers.
 * @param {http.ServerResponse} res - The server response object used to send data back to the client.
 */
const server = http.createServer((req, res) => {
  res.statusCode = 200; // Set the HTTP response status to 200 OK, indicating a successful request
  res.setHeader('Content-Type', 'text/plain'); // Declare the response body format as plain text content
  res.end('Hello, World!\n'); // Send the greeting as the response body and terminate the HTTP transaction
});

/**
 * @description Binds the server to the specified hostname and port, beginning to accept
 * incoming HTTP connections. The callback is invoked once the server is successfully listening.
 */
server.listen(port, hostname, () => {
  console.log(`Server running at http://${hostname}:${port}/`); // Log the server URL to stdout to confirm successful startup
});
