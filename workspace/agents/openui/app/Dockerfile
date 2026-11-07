# OpenUI generative-UI app (thesysdev scaffold, Next.js standalone) - model: sumopod GLM
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM node:22-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# component library spec must exist before next build
RUN npm run generate && npm run build

FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public

# Corporate CA certificates (same convention as agents/opencode/certs):
# place PEM .crt files under certs/ - baked into the image trust store.
COPY certs/ /certs/
# node:22-alpine ships no CA store tooling; concatenate the bundle and let
# Node trust it directly (works with or without certs present).
RUN touch /etc/ssl/corp-bundle.crt && cat /certs/*.crt >> /etc/ssl/corp-bundle.crt 2>/dev/null || true
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/corp-bundle.crt \
    SSL_CERT_FILE=/etc/ssl/corp-bundle.crt
RUN addgroup -S app && adduser -S app -G app && chown -R app:app /app
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- -T 3 http://127.0.0.1:3000/ || exit 1
CMD ["node", "server.js"]
