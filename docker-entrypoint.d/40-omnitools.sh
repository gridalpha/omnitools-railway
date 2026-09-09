#!/bin/sh
# Render OmniTools' nginx server block, security headers, robots.txt and the
# optional basic-auth credential.
#
# Runs from the nginx image's own /docker-entrypoint.sh, after
# 30-tune-worker-processes.sh has sized worker_processes from the cgroup, and
# as uid 101 -- everything written below goes somewhere that user owns.
#
# The image's stock 20-envsubst-on-templates.sh is deliberately left with
# nothing to do: it returns early because /etc/nginx/templates does not exist.
# Rendering here instead means envsubst gets an explicit variable list, so
# nginx's own $uri, $host and $http_* survive rather than being eaten by a
# whole-environment substitution.

set -eu

ME=$(basename "$0")
log() { echo "$ME: $*"; }

TEMPLATE=/etc/nginx/templates-src/default.conf.template
CONF=/etc/nginx/conf.d/default.conf
SNIPPETS=/etc/nginx/snippets
DOCROOT=/usr/share/nginx/html
HTPASSWD=/tmp/omnitools.htpasswd

mkdir -p "$SNIPPETS"

# ---------------------------------------------------------------- listen port

# Railway injects PORT. 8080 matches the base image's own EXPOSE so the
# container still works unchanged outside Railway.
: "${PORT:=8080}"
case "$PORT" in
    ''|*[!0-9]*) log "error: PORT must be a number, got '$PORT'"; exit 1 ;;
esac

# ---------------------------------------------------- content security policy
#
# Every tool computes in the visitor's browser -- no file is ever uploaded to
# this server -- but the page is not self-contained: five features fetch their
# engine, model or icons from a third-party CDN at the moment they are first
# used, and the URLs are compiled into upstream's bundle rather than read from
# configuration. The defaults below name exactly those hosts and nothing else,
# so the policy still blocks any script origin upstream did not intend.
#
#   cdn.jsdelivr.net          the Monaco editor behind every code-input tool
#                             (its script, its stylesheet and its icon font),
#                             tesseract.js' OCR worker and core, and
#                             browser-image-compression's worker build
#   unpkg.com                 @ffmpeg/core -- the WASM engine behind every
#                             video and audio tool
#   api.iconify.design        every icon in the UI (api.simplesvg.com and
#   api.simplesvg.com         api.unisvg.com are the library's own fallbacks,
#   api.unisvg.com            tried only when the first is unreachable)
#   staticimgly.com           the ONNX model behind "remove background"
#   tessdata.projectnaptha.com  tesseract.js' per-language training data
#
# The two lists are split by what the host is trusted to deliver.
# CSP_CDN_HOSTS serves executable code and the stylesheet and icon font that
# come with it, so it appears in script-src, style-src and font-src.
# CSP_DATA_HOSTS serves models, training data and icon JSON, which the page
# only ever fetches, so it appears in connect-src alone.
#
# Setting both to `none` seals the instance: the features above stop working and
# everything self-contained -- text, list, number, date, JSON, CSV, XML, most
# image tools and every PDF tool -- carries on. `none` rather than an empty
# string because Railway does not inject a variable whose value is empty, so an
# empty one is indistinguishable from an unset one and would silently take the
# default list back.
#
# 'wasm-unsafe-eval' is what lets the page compile WebAssembly at all; without
# it the PDF, image and video engines fail on a CSP violation. It is strictly
# narrower than 'unsafe-eval', which is NOT granted.
#
# style-src needs 'unsafe-inline' because MUI's emotion runtime injects every
# component's styles as a <style> element.
#
# blob: appears in script-src, worker-src and connect-src because that is how
# ffmpeg.wasm, tesseract.js and Monaco start their workers: each fetches its
# script from the CDN, wraps the bytes in a Blob and runs that.
: "${CSP_CDN_HOSTS:=https://cdn.jsdelivr.net https://unpkg.com}"
: "${CSP_DATA_HOSTS:=https://api.iconify.design https://api.simplesvg.com https://api.unisvg.com https://staticimgly.com https://tessdata.projectnaptha.com}"
case "$CSP_CDN_HOSTS"  in none|NONE) CSP_CDN_HOSTS="";  log "third-party script origins disabled" ;; esac
case "$CSP_DATA_HOSTS" in none|NONE) CSP_DATA_HOSTS=""; log "third-party data origins disabled"   ;; esac
# ghbtns.com is the GitHub star button in the navbar; *.simplepdf.com is the
# embedded editor behind the "PDF editor" tool. blob: and data: are the
# in-page preview frames every PDF tool renders its result in.
: "${CSP_FRAME_SRC:='self' blob: data: https://ghbtns.com https://*.simplepdf.com}"
: "${CSP_FRAME_ANCESTORS:='none'}"

DEFAULT_CSP="default-src 'self'; \
script-src 'self' 'wasm-unsafe-eval' blob: ${CSP_CDN_HOSTS}; \
style-src 'self' 'unsafe-inline' ${CSP_CDN_HOSTS}; \
img-src 'self' data: blob:; \
font-src 'self' data: ${CSP_CDN_HOSTS}; \
media-src 'self' blob: data:; \
worker-src 'self' blob:; \
child-src 'self' blob:; \
frame-src ${CSP_FRAME_SRC}; \
connect-src 'self' data: blob: ${CSP_CDN_HOSTS} ${CSP_DATA_HOSTS}; \
object-src 'none'; \
base-uri 'self'; \
form-action 'self'; \
frame-ancestors ${CSP_FRAME_ANCESTORS}"

: "${CONTENT_SECURITY_POLICY:=$DEFAULT_CSP}"

# nginx expands $name inside a double-quoted directive argument, so a policy
# carrying one would be rewritten into an empty string rather than sent.
case "$CONTENT_SECURITY_POLICY" in
    *'$'*) log "error: CONTENT_SECURITY_POLICY must not contain '\$'"; exit 1 ;;
esac

# ------------------------------------------------------------------- headers

{
    echo "# Generated by $ME at container start. Included by every location"
    echo "# that declares an add_header of its own, because nginx drops all"
    echo "# inherited add_headers from any block that sets one."
    echo "add_header X-Content-Type-Options 'nosniff' always;"
    echo "add_header Referrer-Policy 'no-referrer' always;"
    echo "add_header Cross-Origin-Opener-Policy 'same-origin' always;"
    echo "add_header Permissions-Policy 'accelerometer=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()' always;"
    echo "add_header Strict-Transport-Security \$hsts_header always;"

    # X-Frame-Options cannot express an allow-list, so send it only while the
    # policy is "no embedding at all". Where the operator has opened
    # frame-ancestors, a DENY here would override their choice in browsers
    # that consult X-Frame-Options first.
    if [ "$CSP_FRAME_ANCESTORS" = "'none'" ]; then
        echo "add_header X-Frame-Options 'DENY' always;"
    fi

    if [ "$CONTENT_SECURITY_POLICY" = "off" ]; then
        echo "# Content-Security-Policy disabled via CONTENT_SECURITY_POLICY=off"
    else
        echo "add_header Content-Security-Policy \"$CONTENT_SECURITY_POLICY\" always;"
    fi
} > "$SNIPPETS/headers.conf"

# ------------------------------------------------------------------- robots

# Upstream ships `Allow: /`, which is right for omnitools.app and wrong for a
# copy of it: a self-hosted instance competing with the original in search
# results helps nobody. Set ROBOTS_POLICY=allow on an instance meant to be
# found.
: "${ROBOTS_POLICY:=noindex}"
case "$ROBOTS_POLICY" in
    noindex) printf 'User-agent: *\nDisallow: /\n' > "$DOCROOT/robots.txt" ;;
    allow)   printf 'User-agent: *\nAllow: /\n'    > "$DOCROOT/robots.txt" ;;
    *) log "error: ROBOTS_POLICY must be 'noindex' or 'allow', got '$ROBOTS_POLICY'"; exit 1 ;;
esac
log "robots policy: $ROBOTS_POLICY"

# ---------------------------------------------------------------- basic auth

# OmniTools has no accounts of its own -- it is a static page with no server
# side, and nothing a visitor opens is stored anywhere -- so this is the only
# access control available. It is off by default, matching how upstream
# publishes omnitools.app, and one variable pair turns it on.
if [ -n "${OMNITOOLS_USERNAME:-}" ] || [ -n "${OMNITOOLS_PASSWORD:-}" ]; then
    if [ -z "${OMNITOOLS_USERNAME:-}" ] || [ -z "${OMNITOOLS_PASSWORD:-}" ]; then
        log "error: set OMNITOOLS_USERNAME and OMNITOOLS_PASSWORD together, or neither"
        exit 1
    fi
    # Fail closed rather than write a file nginx would reject at runtime.
    case "$OMNITOOLS_USERNAME" in
        *:*) log "error: OMNITOOLS_USERNAME must not contain a colon"; exit 1 ;;
    esac
    umask 077
    htpasswd -nbB "$OMNITOOLS_USERNAME" "$OMNITOOLS_PASSWORD" > "$HTPASSWD"
    umask 022
    {
        echo "auth_basic 'OmniTools';"
        echo "auth_basic_user_file $HTPASSWD;"
    } > "$SNIPPETS/auth.conf"
    log "basic auth enabled for user '$OMNITOOLS_USERNAME'"
else
    echo "# basic auth disabled: OMNITOOLS_USERNAME / OMNITOOLS_PASSWORD unset" \
        > "$SNIPPETS/auth.conf"
    rm -f "$HTPASSWD"
    log "basic auth disabled -- this instance is open to anyone with the URL"
fi

# ------------------------------------------------------------ server block

envsubst '${PORT}' < "$TEMPLATE" > "$CONF"

# Fail closed: an unsubstituted placeholder would otherwise reach nginx as a
# literal and surface as a confusing parse error, or worse, parse fine.
if grep -q '\${' "$CONF"; then
    log "error: unsubstituted placeholder left in $CONF"
    grep -n '\${' "$CONF" >&2
    exit 1
fi

log "listening on port $PORT"

# ------------------------------------------------------------------ validate

# Catch a bad rendered config here, where the error is one readable line,
# instead of in a crash loop whose log shows only an exit code. Safe to run as
# uid 101: it creates the /tmp temp directories under the same user that will
# serve, so there is no root-owned leftover for the worker to trip on.
nginx -t
