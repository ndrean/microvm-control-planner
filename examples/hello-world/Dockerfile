FROM alpine:3.19

# Install a simple HTTP server
RUN apk add --no-cache busybox-extras

# Create a simple HTML page
RUN mkdir -p /var/www/html
RUN echo '<h1>Hello from MicroVM!</h1><p>This is running directly in Firecracker, no containers!</p>' > /var/www/html/index.html

# Simple health endpoint
RUN echo '#!/bin/sh\necho "HTTP/1.1 200 OK\n\nOK"' > /health.sh
RUN chmod +x /health.sh

# Run httpd on port 8080
CMD ["httpd", "-f", "-p", "8080", "-h", "/var/www/html"]
