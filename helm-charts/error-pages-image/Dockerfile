# Traefik's errors middleware swaps only the RESPONSE BODY — the browser stays on
# the failed app's origin, so any /assets/* sub-request 404s there. The served
# pages must therefore be fully self-contained. This builder inlines error.css
# (into <style>), error-fx.js (into <script>) and the logo (as a data: URI) into
# every html page. The CSS @import CDN fonts/icons stay external — they load from
# the public CDN and degrade gracefully if blocked.
FROM alpine:3.20 AS build
RUN apk add --no-cache sed coreutils
WORKDIR /src
COPY html/ ./html/
RUN set -eu; \
    cd html; \
    printf '%s\n' '<style>' > /tmp/style.html; cat assets/error.css >> /tmp/style.html; printf '%s\n' '</style>' >> /tmp/style.html; \
    printf '%s\n' '<script>' > /tmp/script.html; cat assets/error-fx.js >> /tmp/script.html; printf '%s\n' '</script>' >> /tmp/script.html; \
    LOGO="data:image/png;base64,$(base64 -w0 assets/logo.png)"; \
    for f in index.html 401.html 404.html; do \
      sed -i -e '\#<link rel="stylesheet" href="/assets/error.css" />#{r /tmp/style.html' -e 'd}' "$f"; \
      sed -i -e '\#<script src="/assets/error-fx.js"></script>#{r /tmp/script.html' -e 'd}' "$f"; \
      sed -i "s#/assets/logo.png#${LOGO}#g" "$f"; \
      ! grep -q '/assets/error.css'   "$f" || { echo "FAIL: css not inlined in $f";  exit 1; }; \
      ! grep -q '/assets/error-fx.js' "$f" || { echo "FAIL: js not inlined in $f";   exit 1; }; \
      ! grep -q '/assets/logo.png' "$f" || { echo "FAIL: logo not inlined in $f"; exit 1; }; \
    done

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --chown=nginx:nginx nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=nginx:nginx --from=build /src/html/ /usr/share/nginx/html/

EXPOSE 8080
