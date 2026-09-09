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
