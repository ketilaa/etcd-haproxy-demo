FROM haproxy:2.8-alpine

USER root

# Install runtime deps
RUN apk add --no-cache curl jq bash

# Ensure haproxy dirs exist
RUN mkdir -p /etc/haproxy /run

# Copy start script
WORKDIR /usr/local/bin
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Expose ports
EXPOSE 80 8404

# Entrypoint
ENTRYPOINT ["/usr/local/bin/start.sh"]

