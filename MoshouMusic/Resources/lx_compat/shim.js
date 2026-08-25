/**
 * LXCompatShim — 让 lx-music 桌面端社区脚本在「墨守music」的 JSContext 中运行。
 *
 * 设计要点：
 * 1. lx-music 脚本用 globalThis.lx = { EVENT_NAMES, request, on, send, env, version, utils }
 *    本 shim 提供完全同名的对象，因此脚本无需改动即可加载。
 * 2. 脚本的 request 处理器有两种风格：
 *      - lx-music 桌面风格：(data) => Promise   （async / await）
 *      - 老式回调风格：     (data, callback) => { callback(err, res) }
 *    __lxDispatch 统一适配：返回值若是 Promise 就 await，否则等 callback。
 * 3. JS -> Swift 的网络走 globalThis.__lxRequest（由 Swift 注入）；
 *    Swift -> JS 的派发走 globalThis.__lxDispatch（由 Swift 调用）。
 * 4. iOS 14.7.1 的 JSC 不支持 async/await，脚本需先用 Babel 转成 ES5（regenerator），
 *    并在本 shim 之前加载 es6-promise 与 regenerator-runtime。
 */
(function () {
  'use strict';

  // ---------- 纯 JS base64（JSC 不保证有 atob/btoa） ----------
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64encode(str) {
    var out = '', i = 0, len = str.length;
    while (i < len) {
      var c1 = str.charCodeAt(i++), c2 = i < len ? str.charCodeAt(i++) : NaN, c3 = i < len ? str.charCodeAt(i++) : NaN;
      var e1 = c1 >> 2, e2 = ((c1 & 3) << 4) | (isNaN(c2) ? 0 : c2 >> 4);
      var e3 = isNaN(c2) ? 64 : (((c2 & 15) << 2) | (isNaN(c3) ? 0 : c3 >> 6));
      var e4 = isNaN(c3) ? 64 : (c3 & 63);
      out += B64.charAt(e1) + B64.charAt(e2) + (e3 === 64 ? '=' : B64.charAt(e3)) + (e4 === 64 ? '=' : B64.charAt(e4));
    }
    return out;
  }
  function b64decode(b64) {
    var str = b64.replace(/[^A-Za-z0-9+/=]/g, ''), out = '', i = 0;
    while (i < str.length) {
      var e1 = B64.indexOf(str.charAt(i++)), e2 = B64.indexOf(str.charAt(i++));
      var e3 = B64.indexOf(str.charAt(i++)), e4 = B64.indexOf(str.charAt(i++));
      var c1 = (e1 << 2) | (e2 >> 4), c2 = ((e2 & 15) << 4) | (e3 >> 2), c3 = ((e3 & 3) << 6) | e4;
      out += String.fromCharCode(c1);
      if (e3 !== 64) out += String.fromCharCode(c2);
      if (e4 !== 64) out += String.fromCharCode(c3);
    }
    return out;
  }

  var LX = {};
  LX.EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    ready: 'ready',
    status: 'status',
    updateAlert: 'updateAlert',
    log: 'log',
  };

  var handlers = {};
  LX._handlers = handlers;

  LX.on = function (name, fn) { handlers[name] = fn; };

  LX._inited = null;
  LX.send = function (name, data) {
    if (name === LX.EVENT_NAMES.inited) { LX._inited = data; }
    if (typeof globalThis.__lxOnSend === 'function') {
      try { globalThis.__lxOnSend(name, data); } catch (e) {}
    }
  };

  LX.request = function (url, options, callback) {
    if (typeof globalThis.__lxRequest !== 'function') {
      if (callback) callback(new Error('no network bridge'));
      return;
    }
    globalThis.__lxRequest(url, options || {}, function (err, resp) { callback(err, resp); });
  };

  // lx-music 桌面/移动端约定：lx.env 是字符串，'desktop' / 'mobile'
  // 社区脚本通过 `env === 'mobile'` 判断是否走移动端分支（发 inited / 注册 handler）。
  // 之前误设成对象会导致 isMobile=false，脚本不注册任何源 —— 这里改回字符串。
  LX.version = '1.0.0';
  LX.env = 'mobile';
  LX.currentScriptInfo = null;

  LX.utils = { crypto: {}, buffer: {} };
  LX.utils.crypto.md5 = function (str) {
    return globalThis.__lxMd5 ? globalThis.__lxMd5(String(str)) : '';
  };
  LX.utils.crypto.sha1 = function (str) {
    return globalThis.__lxSha1 ? globalThis.__lxSha1(String(str)) : '';
  };
  LX.utils.crypto.base64 = function (str) { return b64encode(String(str)); };
  LX.utils.buffer = {
    from: function (str, enc) { return String(str); },
    bufToString: function (buf, enc) {
      if (typeof buf === 'string') return buf;
      if (buf && typeof buf.toString === 'function') {
        try { return buf.toString(enc === 'base64' ? 'base64' : 'utf-8'); } catch (e) {}
      }
      return '';
    },
    b64decode: function (s) { return b64decode(String(s)); },
  };

  // 旧版脚本有时用 Buffer 全局
  if (typeof globalThis.Buffer === 'undefined') {
    globalThis.Buffer = {
      isBuffer: function () { return false; },
      from: function (s, enc) { return String(s); },
    };
  }

  globalThis.lx = LX;

  // ---------- Swift 派发入口 ----------
  globalThis.__lxDispatch = function (action, source, info, callback) {
    var h = handlers[LX.EVENT_NAMES.request];
    if (!h) {
      if (callback) callback(new Error('no request handler for source ' + source));
      return;
    }
    var data = { action: action, source: source, info: info || {} };
    try {
      var ret = h(data, function (err, res) { if (callback) callback(err, res); });
      if (ret && typeof ret.then === 'function') {
        ret.then(function (r) { if (callback) callback(null, r); })
           .catch(function (e) { if (callback) callback(e || new Error('promise rejected')); });
      }
    } catch (e) {
      if (callback) callback(e);
    }
  };
})();
