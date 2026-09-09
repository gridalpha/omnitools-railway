# OmniTools on Railway.
#
# OmniTools is a browser-only toolbox: image, video, PDF, text, list, number and
# date tools that all run in the visitor's own tab. There is no backend, no
# database and no state on the container, so the deployable artifact is a
# directory of static files.
#
# Upstream publishes that directory as iib0011/omni-tools, a stock nginx:alpine
# with the Vite build copied into /usr/share/nginx/html. That image cannot be
# deployed here as it stands, and none of the gaps is expressible as a Railway
# variable:
#
#   * its server block hardcodes `listen 80`, so nothing reads Railway's $PORT
#     and the health check has no port to probe;
#   * nginx runs as root and forks `worker_processes auto` -- 48 workers here,
#     against an 8-core quota;
#   * no compression at all: the ONNX runtime blob alone is 22.8 MB and the
#     entry bundle 567 KB, all served raw;
#   * no security response headers, and Railway's edge adds none;
#   * the shipped robots.txt says `Allow: /`, which points crawlers at a
#     self-hosted copy of omnitools.app;
#   * optional HTTP basic auth needs a password hash derived at boot.
#
# The upstream tag floats deliberately. `latest` is built from `main` by
# upstream's own CI, behind unit tests and a Playwright suite, and is the same
# build their public demo runs; the newest semver tag is eleven months older.
# There is no on-disk format, no database and no second service to keep in step,
# so none of the four pinning reasons applies.
FROM iib0011/omni-tools:latest AS upstream

FROM nginxinc/nginx-unprivileged:1-alpine

# The base ends on USER 101; RUN and COPY inherit that, so restate root for the
# build steps and drop back at the end.
USER root

# apache2-utils supplies htpasswd for the optional basic-auth credential.
# envsubst and gzip are already present -- the image's own template hook uses
# the first.
RUN apk add --no-cache apache2-utils \
 && command -v htpasswd \
 && command -v envsubst \
 && command -v gzip

COPY --from=upstream --chown=101:0 /usr/share/nginx/html/ /usr/share/nginx/html/

# nginx 1.31's mime.types still maps only `js`, so the four .mjs chunks in the
# build (pdf.js' worker, two onnxruntime bundles) would go out as
# application/octet-stream and the browser would refuse them as module scripts:
# a blank tool panel behind a 200. Upstream's own Dockerfile patches the same
# line; the grep is what fails the build if the base ever renames it.
RUN sed -i 's|application/javascript  *js;|application/javascript                           js mjs;|' /etc/nginx/mime.types \
 && grep -q 'js mjs;' /etc/nginx/mime.types

RUN set -eux; \
    cd /usr/share/nginx/html; \
    \
    # This build ships no third-party beacon today. The assertion is the
    # control, not a fix: it fails the build if one is ever added upstream,
    # which is how a self-hosted copy avoids reporting its visitors into
    # somebody else's analytics account.
    for host in googletagmanager.com google-analytics.com cloud.umami.is \
                plausible.io posthog.com sentry.io hotjar.com clarity.ms; do \
        if grep -rqI "$host" . ; then \
            echo "ERROR: third-party beacon $host referenced in the build" >&2; \
            exit 1; \
        fi; \
    done; \
    \
    # Nothing is pre-compressed upstream and nginx serves it raw. Compress once
    # here and let gzip_static hand out the sibling: the onnxruntime WASM blob
    # is 22.8 MB, the largest JS chunk 2.6 MB, and the twelve locale bundles are
    # fetched on every language switch.
    find . -type f \
        \( -name '*.js'  -o -name '*.mjs' -o -name '*.css'  -o -name '*.html' \
        -o -name '*.svg' -o -name '*.json' -o -name '*.wasm' -o -name '*.webmanifest' \) \
        -size +1k -exec gzip -9 -k {} + ; \
    \
    # robots.txt is rewritten per boot from ROBOTS_POLICY. Truncate rather than
    # delete: Railway restores files a build layer removes.
    : > robots.txt; \
    \
    # A placeholder file upstream ships for a Ghostscript WASM module that was
    # never compiled -- it defines window.Module/window.FS and logs
    # "[Simulated] Writing file" from a global script. Nothing in the build
    # loads it, and an unreferenced script that stubs a filesystem API has no
    # business on a public origin.
    : > gs.js; \
    \
    chown -R 101:0 /usr/share/nginx/html; \
    chmod -R g+w /usr/share/nginx/html

COPY --chown=101:0 nginx/nginx.conf                          /etc/nginx/nginx.conf
COPY --chown=101:0 nginx/templates-src/default.conf.template /etc/nginx/templates-src/default.conf.template
COPY --chown=101:0 docker-entrypoint.d/40-omnitools.sh /docker-entrypoint.d/40-omnitools.sh
RUN chmod 0755 /docker-entrypoint.d/40-omnitools.sh

# /etc/nginx and its snippets directory must stay writable by the runtime user:
# the image's own 30-tune-worker-processes.sh does a sed -i on nginx.conf, and
# 40-omnitools.sh renders the server block and the header/auth snippets there.
RUN mkdir -p /etc/nginx/snippets \
 && chown -R 101:0 /etc/nginx \
 && chmod -R g+w /etc/nginx

# Fail the build in seconds on a typo rather than crash-looping a container
# whose log shows nothing but an exit code.
RUN sh -n /docker-entrypoint.d/40-omnitools.sh

# Let the image's entrypoint size nginx's worker count from the cgroup CPU
# quota. Railway's hosts report 48 cores against an 8-core quota, so the stock
# `worker_processes auto` would fork 48 workers.
ENV NGINX_ENTRYPOINT_WORKER_PROCESSES_AUTOTUNE=1

USER 101

# No ENTRYPOINT and no CMD here on purpose: declaring either would drop the
# base image's `nginx -g "daemon off;"` and skip /docker-entrypoint.d/*.
# For the same reason this service must not be given a Railway start command.
