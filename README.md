# OmniTools on Railway

A production wrapper around [OmniTools](https://github.com/iib0011/omni-tools), a
self-hosted collection of 126 everyday utilities — image, video, audio, PDF,
text, list, number, date, JSON, CSV and XML tools — that all run in the
visitor's own browser.

Nothing a visitor opens is uploaded: every conversion, crop, split and encode
happens in the page. The deployable artifact is therefore a directory of static
files, and this repo is the web server in front of it.

## What this adds to the published image

Upstream ships `iib0011/omni-tools`, a stock `nginx:alpine` with the Vite build
copied into the docroot. This repo re-serves that same build from
`nginxinc/nginx-unprivileged` and adds what Railway needs and a Railway variable
cannot express:

| | |
|---|---|
| `$PORT` | upstream's server block hardcodes `listen 80`, so nothing reads Railway's port and the health check has nothing to probe |
| Unprivileged nginx | upstream's runs as root with `worker_processes auto`, which forks 48 workers against Railway's 8-core quota. This runs as uid 101 and sizes workers from the cgroup |
| Compression | upstream serves everything raw. Every js/mjs/css/svg/html/json/wasm file over 1 KB is gzipped at build and served by `gzip_static` — the onnxruntime blob drops from 22.8 MB to 5.6 MB |
| `.mjs` MIME type | nginx 1.31's `mime.types` maps only `js`, so the build's four `.mjs` chunks would be sent as `application/octet-stream` and refused as module scripts |
| Security headers | CSP, HSTS (only on requests that arrived over HTTPS), `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, `Cross-Origin-Opener-Policy`, `X-Frame-Options` |
| Correct caching | Vite content-hashes its code output, so `/assets/*-XXXXXXXX.{js,mjs,css,wasm}` is `immutable`; `index.html`, the locale bundles and the unhashed images revalidate |
| A real `/healthz` | serves the actual `index.html`, so it fails if the static build is missing rather than only proving nginx is alive. Exempt from basic auth, because Railway's probe is anonymous |
| `robots.txt` | upstream ships `Allow: /`, which is right for omnitools.app and wrong for a copy of it. Written at boot from `ROBOTS_POLICY`, default `noindex` |
| Optional basic auth | OmniTools has no accounts; a password hash has to be derived at boot |
| A beacon assertion | this build carries no third-party analytics today, and the build now fails if one is ever added upstream |

The upstream tag floats on purpose. `latest` is built from `main` by upstream's
own CI behind unit tests and a Playwright suite, and is the build their public
demo runs; the newest semver tag is eleven months older. There is no on-disk
format, no database and no second service to keep in step, so nothing here rots
against a moving tag.

## What the page still fetches from a CDN

OmniTools computes in the browser, but it is not self-contained: five features
load their engine, model or icons from a third-party CDN the first time they are
used, and those URLs are compiled into upstream's bundle rather than read from
configuration.

| Host | What it serves | Which tools stop without it |
|---|---|---|
| `cdn.jsdelivr.net` | Monaco editor (script, stylesheet, icon font), tesseract.js OCR worker and core, browser-image-compression's worker build | every code-input tool, Image to Text |
| `unpkg.com` | `@ffmpeg/core` — the WASM engine | every video and audio tool |
| `api.iconify.design` (falling back to `api.simplesvg.com`, `api.unisvg.com`) | every icon in the UI | icons render blank |
| `staticimgly.com` | the ONNX model behind background removal | Remove Background |
| `tessdata.projectnaptha.com` | tesseract.js training data on releases that use it rather than jsDelivr | Image to Text |

`CSP_CDN_HOSTS` and `CSP_DATA_HOSTS` name exactly those origins. Set both to the
empty string to seal the instance: the tools above stop working, and everything
self-contained — text, list, number, date, JSON, CSV, XML, most image tools and
every PDF tool — carries on.

Two third-party frames are part of upstream's UI and are allowed by
`CSP_FRAME_SRC`: the GitHub star button in the navbar (`ghbtns.com`) and the
embedded editor behind the PDF Editor tool (`*.simplepdf.com`).

## Environment variables

Every one is optional. A deploy with nothing set produces a working public
instance.

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | The port nginx listens on. Railway sets it. |
| `OMNITOOLS_USERNAME` | unset | Turns on HTTP basic auth. Must be set with `OMNITOOLS_PASSWORD`; setting exactly one fails the boot rather than leaving the site open. |
| `OMNITOOLS_PASSWORD` | unset | Bcrypt-hashed into an htpasswd file at boot. |
| `ROBOTS_POLICY` | `noindex` | `noindex` serves `Disallow: /`. `allow` for an instance meant to be found. |
| `CSP_CDN_HOSTS` | jsDelivr, unpkg | Origins allowed to serve scripts, styles and fonts. |
| `CSP_DATA_HOSTS` | Iconify ×3, staticimgly, tessdata | Origins the page may fetch data from. |
| `CSP_FRAME_SRC` | `'self' blob: data: https://ghbtns.com https://*.simplepdf.com` | What may be framed by the page. |
| `CSP_FRAME_ANCESTORS` | `'none'` | Who may frame the page. `X-Frame-Options: DENY` is dropped automatically when this changes. |
| `CONTENT_SECURITY_POLICY` | built from the four above | Replaces the whole policy; `off` sends no CSP header. |

## Notes

- **Do not set a Railway start command.** It replaces the base image's
  `ENTRYPOINT`/`CMD` and would skip `/docker-entrypoint.d/*`, which is where the
  server block, headers, robots file and credential are rendered.
- `/assets/` and `/locales/` never fall through to `index.html`. A missing chunk
  answered with the HTML shell is the classic blank-page-behind-200s failure.
- No `Cross-Origin-Embedder-Policy` is sent. It would buy `SharedArrayBuffer`
  and cost every CDN-loaded script above, which is a bad trade here: the WASM
  engines fall back to a single thread and keep working.

## Licence

OmniTools is MIT-licensed; this wrapper adds only packaging.
