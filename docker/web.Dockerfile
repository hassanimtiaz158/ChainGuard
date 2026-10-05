# syntax=docker/dockerfile:1
#
# Frontend (Next.js 14, standalone output). Built in one stage for simplicity;
# dependency layers are still separated from source.

FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM node:20-alpine AS runner

WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1

COPY --from=builder /app ./

EXPOSE 3000

CMD ["npm", "run", "start"]