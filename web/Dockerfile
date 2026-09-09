FROM node:22-alpine

WORKDIR /app

# Install dependencies first so source edits don't reinstall the tree.
COPY package.json ./
RUN npm install

COPY tsconfig.json vite.config.ts index.html ./
COPY src ./src
COPY public ./public

EXPOSE 5173

CMD ["npm", "run", "dev"]
