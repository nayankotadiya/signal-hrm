# Signal HRM API — production image.
#   docker build -t signal-hrm-api apps/api
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:20-alpine
# mongodump / mongorestore for verified backups and protected restores.
RUN apk add --no-cache mongodb-tools tini && addgroup -S app && adduser -S app -G app
WORKDIR /app
ENV NODE_ENV=production PORT=3000 BACKUP_WORK_DIR=/var/lib/signal-hrm/backups LOCAL_STORAGE_DIR=/var/lib/signal-hrm/files
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
RUN mkdir -p /var/lib/signal-hrm/backups /var/lib/signal-hrm/files && chown -R app:app /var/lib/signal-hrm
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD wget -qO- http://127.0.0.1:3000/api/v1/health/live || exit 1
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/main.js"]
