const http = require('http');

// Root Cause 11 fix: Environment-configurable host and port
const hostname = process.env.HOST || '127.0.0.1';
const port = parseInt(process.env.PORT, 10) || 3000;

// Root Cause 9 fix: URL and method validation
// Root Cause 4 fix: Request stream error handling
// Root Cause 5 fix: Response stream error handling
const server = http.createServer((req, res) => {
  req.on('error', (err) => {
    console.error('Request error:', err.message);
    if (!res.headersSent) {
      res.statusCode = 400;
      res.setHeader('Content-Type', 'text/plain');
      res.end('Bad Request\n');
    }
  });

  res.on('error', (err) => {
    console.error('Response error:', err.message);
  });

  if (req.method === 'GET' && req.url === '/') {
    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain');
    res.end('Hello, World!\n');
  } else if (req.method !== 'GET') {
    res.statusCode = 405;
    res.setHeader('Allow', 'GET');
    res.setHeader('Content-Type', 'text/plain');
    res.end('Method Not Allowed\n');
  } else {
    res.statusCode = 404;
    res.setHeader('Content-Type', 'text/plain');
    res.end('Not Found\n');
  }
});

// Root Cause 7 fix: Request timeout configuration
server.timeout = 120000; // 120 seconds socket inactivity timeout
server.requestTimeout = 30000; // 30 seconds to receive full request
server.headersTimeout = 60000; // 60 seconds to receive headers
// Root Cause 10 fix: Keep-alive timeout configuration
server.keepAliveTimeout = 65000; // 65 seconds keep-alive idle timeout

// Root Cause 1 fix: Server error event handler
server.on('error', (err) => {
  console.error('Server error:', err.message);
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${port} is already in use`);
    process.exit(1);
  }
});

// Root Cause 2 fix: Client error handler
server.on('clientError', (err, socket) => {
  // ECONNRESET means the client already disconnected, so no response is possible or needed.
  // !socket.writable guards against attempting to write to an already-closed/destroyed socket.
  if (err.code === 'ECONNRESET' || !socket.writable) {
    return;
  }
  socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
});

// Root Cause 3 fix: Graceful shutdown signal handlers
let isShuttingDown = false;

function gracefulShutdown(signal) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`${signal} received. Shutting down gracefully...`);
  server.close(() => {
    console.log('Server closed.');
    process.exit(0);
  });
  // Force shutdown after 5 seconds if connections won't drain
  setTimeout(() => {
    console.error('Forced shutdown: connections did not drain in time');
    process.exit(1);
  }, 5000).unref();
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));

// Root Cause 6 fix: Process-level exception/rejection handlers
process.on('uncaughtException', (err) => {
  console.error('Uncaught Exception:', err.message);
  server.close(() => process.exit(1));
  setTimeout(() => process.abort(), 1000).unref();
});

process.on('unhandledRejection', (reason) => {
  console.error('Unhandled Rejection:', reason);
});

server.listen(port, hostname, () => {
  console.log(`Server running at http://${hostname}:${port}/`);
});
