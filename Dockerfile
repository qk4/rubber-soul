FROM crystallang/crystal:0.35.1-alpine

WORKDIR /app

# Install shards for caching
COPY shard.yml shard.yml
COPY shard.lock shard.lock

RUN shards install --production

# Add src
ADD ./src /app/src

# Compile
RUN crystal build --release --no-debug --error-trace /app/src/app.cr -o /app/rubber-soul

# Extract dependencies
RUN ldd /app/rubber-soul | tr -s '[:blank:]' '\n' | grep '^/' | \
    xargs -I % sh -c 'mkdir -p $(dirname deps%); cp % deps%;'

# Build a minimal docker image
FROM scratch
WORKDIR /
ENV PATH=$PATH:/
COPY --from=0 /app/deps /
COPY --from=0 /app/rubber-soul /rubber-soul
COPY --from=0 /etc/hosts /etc/hosts

# This is required for Timezone support
COPY --from=0 /usr/share/zoneinfo/ /usr/share/zoneinfo/

# Run the app binding on port 3000
EXPOSE 3000
ENTRYPOINT ["/rubber-soul"]
HEALTHCHECK CMD ["/rubber-soul", "-c", "http://127.0.0.1:3000/api/rubber-soul/v1"]
CMD ["/rubber-soul", "-b", "0.0.0.0", "-p", "3000"]
