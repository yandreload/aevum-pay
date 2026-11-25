# Serves the AevumPay prototype UI (web/index.html) as a static site.
# Testnet only — the page talks to Aevum testnet (chain 44005) via the
# visitor's own wallet (MetaMask). No keys or backend in this image.
FROM nginx:alpine
COPY web/ /usr/share/nginx/html/
EXPOSE 80
