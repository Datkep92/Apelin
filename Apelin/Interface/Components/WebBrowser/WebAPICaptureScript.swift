import Foundation

/// The script the in-app browser injects into every frame of a page: it wraps
/// `fetch` and `XMLHttpRequest` and posts what each call was and answered to the
/// `apelinAPI` message handler.
///
/// It reports the call, never changes it: the original function is called with
/// the original arguments and its result passed back untouched. Cookies are not
/// here — a page cannot read them; the browser fills those in from its own
/// cookie store.
enum WebAPICaptureScript {
    /// The handler name this script posts to; `WebAPICaptureStore` registers it.
    static let handlerName = "apelinAPI"

    static let source = #"""
    (function () {
        "use strict";
        if (window.__apelinAPICapture) { return; }
        if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.apelinAPI) { return; }
        window.__apelinAPICapture = true;
        var bridge = window.webkit.messageHandlers.apelinAPI;
        var LIMIT = 262144;
        function cut(value) {
            if (value === undefined || value === null) { return null; }
            var text = typeof value === "string" ? value : String(value);
            return text.length > LIMIT ? text.slice(0, LIMIT) : text;
        }
        function absolute(url) {
            try { return new URL(String(url), location.href).href; } catch (error) { return String(url); }
        }
        function headers(source) {
            var out = {};
            if (!source) { return out; }
            try {
                if (typeof source.forEach === "function") {
                    source.forEach(function (value, name) { out[String(name)] = cut(value); });
                } else {
                    Object.keys(source).forEach(function (name) { out[String(name)] = cut(source[name]); });
                }
            } catch (error) { }
            return out;
        }
        function body(value) {
            if (value === undefined || value === null) { return null; }
            if (typeof value === "string") { return cut(value); }
            if (typeof URLSearchParams !== "undefined" && value instanceof URLSearchParams) { return cut(value.toString()); }
            if (typeof FormData !== "undefined" && value instanceof FormData) {
                var parts = [];
                try {
                    value.forEach(function (entry, name) {
                        parts.push(name + "=" + (typeof entry === "string" ? entry : "[file]"));
                    });
                } catch (error) { }
                return cut(parts.join("&"));
            }
            if (typeof Blob !== "undefined" && value instanceof Blob) { return "[blob " + value.size + " bytes]"; }
            if (typeof ArrayBuffer !== "undefined" && (value instanceof ArrayBuffer || ArrayBuffer.isView(value))) {
                return "[binary " + (value.byteLength || 0) + " bytes]";
            }
            try { return cut(JSON.stringify(value)); } catch (error) { return cut(value); }
        }
        function start(kind, method, url, source, sent) {
            var address = absolute(url);
            if (!/^https?:/i.test(address)) { return null; }
            return {
                kind: kind,
                at: Date.now(),
                method: String(method || "GET"),
                url: address,
                page: location.href,
                headers: headers(source),
                body: body(sent)
            };
        }
        function reporter(call) {
            var reported = false;
            return function (status, responseBody, message) {
                if (reported) { return; }
                reported = true;
                if (typeof status === "number") { call.status = status; }
                if (typeof responseBody === "string") { call.response = cut(responseBody); }
                if (typeof message === "string") { call.error = message; }
                call.durationMilliseconds = Date.now() - call.at;
                try { bridge.postMessage(call); } catch (error) { }
            };
        }
        if (typeof window.fetch === "function") {
            var originalFetch = window.fetch;
            window.fetch = function (input, init) {
                var options = init || {};
                var request = (input && typeof input === "object") ? input : null;
                var call = start(
                    "fetch",
                    options.method || (request ? request.method : null) || "GET",
                    request ? request.url : input,
                    options.headers || (request ? request.headers : null),
                    options.body !== undefined ? options.body : (request ? request.body : null)
                );
                if (!call) { return originalFetch.apply(this, arguments); }
                var done = reporter(call);
                return originalFetch.apply(this, arguments).then(function (response) {
                    var clone = null;
                    try { clone = response.clone(); } catch (error) { clone = null; }
                    if (clone && typeof clone.text === "function") {
                        try {
                            clone.text().then(function (text) { done(response.status, text); },
                                              function () { done(response.status, ""); });
                        } catch (error) { done(response.status, ""); }
                    } else {
                        done(response.status, "");
                    }
                    setTimeout(function () { done(response.status, ""); }, 3000);
                    return response;
                }, function (error) {
                    done(null, null, error && error.message ? String(error.message) : "network error");
                    throw error;
                });
            };
        }
        if (typeof XMLHttpRequest !== "undefined" && XMLHttpRequest.prototype) {
            var originalOpen = XMLHttpRequest.prototype.open;
            var originalSend = XMLHttpRequest.prototype.send;
            var originalSetHeader = XMLHttpRequest.prototype.setRequestHeader;
            XMLHttpRequest.prototype.open = function (method, url) {
                try {
                    this.__apelinCall = start("xhr", method, url, null, null);
                    this.__apelinHeaders = {};
                } catch (error) { this.__apelinCall = null; }
                return originalOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
                try {
                    if (this.__apelinCall) { this.__apelinHeaders[String(name)] = cut(value); }
                } catch (error) { }
                return originalSetHeader.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function (sent) {
                try {
                    if (this.__apelinCall) {
                        this.__apelinCall.headers = this.__apelinHeaders;
                        this.__apelinCall.body = body(sent);
                        var xhr = this;
                        var done = reporter(this.__apelinCall);
                        this.addEventListener("loadend", function () {
                            var responseBody = "";
                            try {
                                if (xhr.responseType === "" || xhr.responseType === "text") {
                                    responseBody = xhr.responseText || "";
                                } else if (xhr.responseType === "json") {
                                    responseBody = JSON.stringify(xhr.response);
                                }
                            } catch (error) { responseBody = ""; }
                            if (xhr.status >= 200) { done(xhr.status, responseBody); }
                            else if (xhr.status > 0) { done(xhr.status, responseBody, "HTTP " + xhr.status); }
                            else { done(null, responseBody, "network error"); }
                        });
                    }
                } catch (error) { }
                return originalSend.apply(this, arguments);
            };
        }
    })();
    """#
}
