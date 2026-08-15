/**
 * Generic root-relative-path rewriter for the numeric-port reverse proxy.
 *
 * Problem: an app mounted at /<port>/ often has no idea it's not at "/".
 * Any hardcoded absolute path it emits (in HTML attributes, inline JS,
 * JSON, CSS) escapes the /<port>/ prefix once the browser follows it.
 *
 * This filter buffers the response body for one request, then rewrites
 * root-relative references (anything starting with a single "/", not
 * "//" and not already under the current prefix) to include the prefix,
 * for a handful of *structural* patterns — not a word list of specific
 * path names. It intentionally does NOT try to parse arbitrary quoted
 * strings as paths (too many false positives), only well-known
 * attribute/URL contexts.
 *
 * This is a best-effort safety net, not a substitute for writing
 * prefix-aware app code (see skills/exposing-services.md).
 */

const REWRITABLE_TYPES = [
    'text/html',
    'application/javascript',
    'text/javascript',
    'text/css',
    'application/json',
];

function isRewritableType(contentType) {
    if (!contentType) return false;
    const ct = contentType.split(';')[0].trim().toLowerCase();
    return REWRITABLE_TYPES.indexOf(ct) !== -1;
}

function rewrite(body, prefix) {
    if (!prefix) return body;

    // Avoid double-prefixing content that (for whatever reason) already
    // carries this exact prefix right after the delimiter.
    const alreadyPrefixed = (offset, str) =>
        str.slice(offset, offset + prefix.length + 1) === prefix + '/';

    // 1. HTML/XML attributes: href="/x"  src='/x'  action="/x"
    body = body.replace(
        /((?:href|src|action)\s*=\s*)(["'])\/(?!\/)/gi,
        (m, attr, q, offset, str) =>
            alreadyPrefixed(offset + m.length - 1, str) ? m : `${attr}${q}${prefix}/`
    );

    // 2. CSS/JS url(...): url(/x)  url('/x')  url("/x")
    body = body.replace(
        /(url\(\s*)(["']?)\/(?!\/)/gi,
        (m, pre, q, offset, str) =>
            alreadyPrefixed(offset + m.length - 1, str) ? m : `${pre}${q}${prefix}/`
    );

    // 3. Client-side navigation assignments:
    //    location.href = "/x"   location = "/x"   window.location = "/x"
    body = body.replace(
        /((?:window\.)?location(?:\.href)?\s*=\s*)(["'])\/(?!\/)/gi,
        (m, pre, q, offset, str) =>
            alreadyPrefixed(offset + m.length - 1, str) ? m : `${pre}${q}${prefix}/`
    );

    // 4. fetch()/XHR-style calls: fetch("/x"), fetch('/x'
    body = body.replace(
        /(fetch\(\s*)(["'])\/(?!\/)/gi,
        (m, pre, q, offset, str) =>
            alreadyPrefixed(offset + m.length - 1, str) ? m : `${pre}${q}${prefix}/`
    );

    // 5. Set-Cookie / meta-refresh style "/x" appearing right after
    //    Location: in a raw HTTP-style string some apps template into
    //    JSON responses, e.g. {"redirect": "/x"} or {"next":"/x"}.
    body = body.replace(
        /((?:"|')(?:redirect|next|url|location|path)(?:"|')\s*:\s*)(["'])\/(?!\/)/gi,
        (m, pre, q, offset, str) =>
            alreadyPrefixed(offset + m.length - 1, str) ? m : `${pre}${q}${prefix}/`
    );

    return body;
}

function bodyFilter(r, data, flags) {
    r.ctx = r.ctx || {};
    r.ctx.buf = (r.ctx.buf || '') + data;
    if (flags.last) {
        const contentType = r.headersOut['Content-Type'];
        const prefix = r.variables.prefix || '';
        let out = r.ctx.buf;
        if (prefix && isRewritableType(contentType)) {
            out = rewrite(out, prefix);
        }
        r.sendBuffer(out, flags);
    }
}

export default { bodyFilter };
