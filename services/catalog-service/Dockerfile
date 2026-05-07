# Use a specific minor version, not :latest. "latest" is non-reproducible and bites you in production.
FROM node:20-alpine

WORKDIR /app

# Copy package files first and install dependencies BEFORE copying source code.
# This way Docker caches the npm install layer and only rebuilds it when dependencies change.
COPY package.json ./
RUN npm install --omit=dev

COPY index.js ./

EXPOSE 3001

CMD ["node", "index.js"]
