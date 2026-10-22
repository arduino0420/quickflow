# PDF.js 6.4.299 (A1)

Source: https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-6.4.299.tgz
Upstream: https://github.com/mozilla/pdf.js/releases/tag/v6.4.299

Archive integrity (npm SHA-512):
`sha512-AVl138zALtfaAPvADulE0PZThbYzCBS79nL4pOSL/6Sm/4AH5A21BD9VHt97OlCuzJuCpmeZtAtkinisF4Vb1g==`

The archive integrity was verified before extracting files. SHA256SUMS records
the unmodified vendored files. The legacy/build minified main module and worker
are copied here together; cmaps, standard_fonts, wasm and iccs retain their
upstream paths and licenses. No npm installation or runtime CDN is required.
The legacy build broadens browser compatibility; actual school devices still
need testing. This directory contains library assets only, never student PDFs.

Importmap loads the main module on demand. The preview starts a same-origin
module Worker using the matching versioned URL. Auxiliary assets are also
same-origin. Keep the entire directory versioned together when updating.
The standard public-file server must serve .mjs as JavaScript and .wasm as WASM;
the system specs exercise the served worker rather than a fake-worker fallback.
