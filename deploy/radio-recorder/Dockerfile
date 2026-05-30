# node:20 debian-slim — NO alpine: @livekit/rtc-node usa binarios nativos
# glibc (linux-arm64-gnu), que no funcionan en musl/alpine.
FROM node:20-bookworm-slim

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY index.js ./

# El service account de Firebase y el dir de grabaciones se montan como volúmenes.
ENV GOOGLE_APPLICATION_CREDENTIALS=/secrets/firebase-sa.json
ENV REC_DIR=/recordings

CMD ["node", "index.js"]
