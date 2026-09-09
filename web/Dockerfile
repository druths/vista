# Development: the Vite dev server with source bind-mounted.
FROM node:22-alpine AS dev

WORKDIR /app

# Install dependencies first so source edits don't reinstall the tree.
COPY package.json ./
RUN npm install

COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src
COPY public ./public

EXPOSE 5173

CMD ["npm", "run", "dev"]


# Build the static bundle. VITE_API_BASE is deliberately left unset so the
# client derives the API host from whatever address served the page.
FROM node:22-alpine AS build

# Vite inlines these at build time, so they are build args rather than runtime
# environment. Both are optional: left empty, the client derives the API
# address from whatever host served the page, which is what makes one image
# work over loopback, a LAN address and a Tailscale name alike. Set
# VITE_API_PORT when the API is published on something other than 8800.
ARG VITE_API_BASE=""
ARG VITE_API_PORT="8800"
ENV VITE_API_BASE=$VITE_API_BASE
ENV VITE_API_PORT=$VITE_API_PORT

WORKDIR /app
COPY package.json ./
RUN npm install
COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src
COPY public ./public
RUN npm run build


# Production: static files over nginx. This is the one that can be installed —
# the service worker only registers in a built app.
FROM nginx:alpine AS prod

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 5173
