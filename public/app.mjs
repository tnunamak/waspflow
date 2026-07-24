var re, w, He, H, ye, De, Ee, oe, B, M, Le, pe, se, ce, K = {}, Q = [], nt = /acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i, ie = Array.isArray;
function F(t, e) {
  for (var r in e) t[r] = e[r];
  return t;
}
function he(t) {
  t && t.parentNode && t.parentNode.removeChild(t);
}
function rt(t, e, r) {
  var a, l, i, d = {};
  for (i in e) i == "key" ? a = e[i] : i == "ref" ? l = e[i] : d[i] = e[i];
  if (arguments.length > 2 && (d.children = arguments.length > 3 ? re.call(arguments, 2) : r), typeof t == "function" && t.defaultProps != null) for (i in t.defaultProps) d[i] === void 0 && (d[i] = t.defaultProps[i]);
  return Y(t, d, a, l, null);
}
function Y(t, e, r, a, l) {
  var i = { type: t, props: e, key: r, ref: a, __k: null, __: null, __b: 0, __e: null, __c: null, constructor: void 0, __v: l ?? ++He, __i: -1, __u: 0 };
  return l == null && w.vnode != null && w.vnode(i), i;
}
function T(t) {
  return t.children;
}
function G(t, e) {
  this.props = t, this.context = e;
}
function L(t, e) {
  if (e == null) return t.__ ? L(t.__, t.__i + 1) : null;
  for (var r; e < t.__k.length; e++) if ((r = t.__k[e]) != null && r.__e != null) return r.__e;
  return typeof t.type == "function" ? L(t) : null;
}
function it(t) {
  if (t.__P && t.__d) {
    var e = t.__v, r = e.__e, a = [], l = [], i = F({}, e);
    i.__v = e.__v + 1, w.vnode && w.vnode(i), _e(t.__P, i, e, t.__n, t.__P.namespaceURI, 32 & e.__u ? [r] : null, a, r ?? L(e), !!(32 & e.__u), l), i.__v = e.__v, i.__.__k[i.__i] = i, ze(a, i, l), e.__e = e.__ = null, i.__e != r && We(i);
  }
}
function We(t) {
  if ((t = t.__) != null && t.__c != null) return t.__e = t.__c.base = null, t.__k.some(function(e) {
    if (e != null && e.__e != null) return t.__e = t.__c.base = e.__e;
  }), We(t);
}
function ke(t) {
  (!t.__d && (t.__d = !0) && H.push(t) && !X.__r++ || ye != w.debounceRendering) && ((ye = w.debounceRendering) || De)(X);
}
function X() {
  try {
    for (var t, e = 1; H.length; ) H.length > e && H.sort(Ee), t = H.shift(), e = H.length, it(t);
  } finally {
    H.length = X.__r = 0;
  }
}
function Me(t, e, r, a, l, i, d, s, h, c, m) {
  var f, o, u, v, b, k, y, p = a && a.__k || Q, _ = e.length;
  for (h = at(r, e, p, h, _), f = 0; f < _; f++) (u = r.__k[f]) != null && (o = u.__i != -1 && p[u.__i] || K, u.__i = f, k = _e(t, u, o, l, i, d, s, h, c, m), v = u.__e, u.ref && o.ref != u.ref && (o.ref && me(o.ref, null, u), m.push(u.ref, u.__c || v, u)), b == null && v != null && (b = v), (y = !!(4 & u.__u)) || o.__k === u.__k ? (h = Oe(u, h, t, y), y && o.__e && (o.__e = null)) : typeof u.type == "function" && k !== void 0 ? h = k : v && (h = v.nextSibling), u.__u &= -7);
  return r.__e = b, h;
}
function at(t, e, r, a, l) {
  var i, d, s, h, c, m = r.length, f = m, o = 0;
  for (t.__k = new Array(l), i = 0; i < l; i++) (d = e[i]) != null && typeof d != "boolean" && typeof d != "function" ? (typeof d == "string" || typeof d == "number" || typeof d == "bigint" || d.constructor == String ? d = t.__k[i] = Y(null, d, null, null, null) : ie(d) ? d = t.__k[i] = Y(T, { children: d }, null, null, null) : d.constructor === void 0 && d.__b > 0 ? d = t.__k[i] = Y(d.type, d.props, d.key, d.ref ? d.ref : null, d.__v) : t.__k[i] = d, h = i + o, d.__ = t, d.__b = t.__b + 1, s = null, (c = d.__i = ot(d, r, h, f)) != -1 && (f--, (s = r[c]) && (s.__u |= 2)), s == null || s.__v == null ? (c == -1 && (l > m ? o-- : l < m && o++), typeof d.type != "function" && (d.__u |= 4)) : c != h && (c == h - 1 ? o-- : c == h + 1 ? o++ : (c > h ? o-- : o++, d.__u |= 4))) : t.__k[i] = null;
  if (f) for (i = 0; i < m; i++) (s = r[i]) != null && (2 & s.__u) == 0 && (s.__e == a && (a = L(s)), Ye(s, s));
  return a;
}
function Oe(t, e, r, a) {
  var l, i;
  if (typeof t.type == "function") {
    for (l = t.__k, i = 0; l && i < l.length; i++) l[i] && (l[i].__ = t, e = Oe(l[i], e, r, a));
    return e;
  }
  t.__e != e && (a && (e && t.type && !e.parentNode && (e = L(t)), r.insertBefore(t.__e, e || null)), e = t.__e);
  do
    e = e && e.nextSibling;
  while (e != null && e.nodeType == 8);
  return e;
}
function ot(t, e, r, a) {
  var l, i, d, s = t.key, h = t.type, c = e[r], m = c != null && (2 & c.__u) == 0;
  if (c === null && s == null || m && s == c.key && h == c.type) return r;
  if (a > (m ? 1 : 0)) {
    for (l = r - 1, i = r + 1; l >= 0 || i < e.length; ) if ((c = e[d = l >= 0 ? l-- : i++]) != null && (2 & c.__u) == 0 && s == c.key && h == c.type) return d;
  }
  return -1;
}
function we(t, e, r) {
  e[0] == "-" ? t.setProperty(e, r ?? "") : t[e] = r == null ? "" : typeof r != "number" || nt.test(e) ? r : r + "px";
}
function j(t, e, r, a, l) {
  var i, d;
  e: if (e == "style") if (typeof r == "string") t.style.cssText = r;
  else {
    if (typeof a == "string" && (t.style.cssText = a = ""), a) for (e in a) r && e in r || we(t.style, e, "");
    if (r) for (e in r) a && r[e] == a[e] || we(t.style, e, r[e]);
  }
  else if (e[0] == "o" && e[1] == "n") i = e != (e = e.replace(Le, "$1")), d = e.toLowerCase(), e = d in t || e == "onFocusOut" || e == "onFocusIn" ? d.slice(2) : e.slice(2), t.l || (t.l = {}), t.l[e + i] = r, r ? a ? r[M] = a[M] : (r[M] = pe, t.addEventListener(e, i ? ce : se, i)) : t.removeEventListener(e, i ? ce : se, i);
  else {
    if (l == "http://www.w3.org/2000/svg") e = e.replace(/xlink(H|:h)/, "h").replace(/sName$/, "s");
    else if (e != "width" && e != "height" && e != "href" && e != "list" && e != "form" && e != "tabIndex" && e != "download" && e != "rowSpan" && e != "colSpan" && e != "role" && e != "popover" && e in t) try {
      t[e] = r ?? "";
      break e;
    } catch {
    }
    typeof r == "function" || (r == null || r === !1 && e[4] != "-" ? t.removeAttribute(e) : t.setAttribute(e, e == "popover" && r == 1 ? "" : r));
  }
}
function xe(t) {
  return function(e) {
    if (this.l) {
      var r = this.l[e.type + t];
      if (e[B] == null) e[B] = pe++;
      else if (e[B] < r[M]) return;
      return r(w.event ? w.event(e) : e);
    }
  };
}
function _e(t, e, r, a, l, i, d, s, h, c) {
  var m, f, o, u, v, b, k, y, p, _, g, x, q, R, I, U, $ = e.type;
  if (e.constructor !== void 0) return null;
  128 & r.__u && (h = !!(32 & r.__u), i = [s = e.__e = r.__e]), (m = w.__b) && m(e);
  e: if (typeof $ == "function") {
    f = d.length;
    try {
      if (p = e.props, _ = $.prototype && $.prototype.render, g = (m = $.contextType) && a[m.__c], x = m ? g ? g.props.value : m.__ : a, r.__c ? y = (o = e.__c = r.__c).__ = o.__E : (_ ? e.__c = o = new $(p, x) : (e.__c = o = new G(p, x), o.constructor = $, o.render = st), g && g.sub(o), o.state || (o.state = {}), o.__n = a, u = o.__d = !0, o.__h = [], o._sb = []), _ && o.__s == null && (o.__s = o.state), _ && $.getDerivedStateFromProps != null && (o.__s == o.state && (o.__s = F({}, o.__s)), F(o.__s, $.getDerivedStateFromProps(p, o.__s))), v = o.props, b = o.state, o.__v = e, u) _ && $.getDerivedStateFromProps == null && o.componentWillMount != null && o.componentWillMount(), _ && o.componentDidMount != null && o.__h.push(o.componentDidMount);
      else {
        if (_ && $.getDerivedStateFromProps == null && p !== v && o.componentWillReceiveProps != null && o.componentWillReceiveProps(p, x), e.__v == r.__v || !o.__e && o.shouldComponentUpdate != null && o.shouldComponentUpdate(p, o.__s, x) === !1) {
          e.__v != r.__v && (o.props = p, o.state = o.__s, o.__d = !1), e.__e = r.__e, e.__k = r.__k, e.__k.some(function(A) {
            A && (A.__ = e);
          }), Q.push.apply(o.__h, o._sb), o._sb = [], o.__h.length && d.push(o);
          break e;
        }
        o.componentWillUpdate != null && o.componentWillUpdate(p, o.__s, x), _ && o.componentDidUpdate != null && o.__h.push(function() {
          o.componentDidUpdate(v, b, k);
        });
      }
      if (o.context = x, o.props = p, o.__P = t, o.__e = !1, q = w.__r, R = 0, _) o.state = o.__s, o.__d = !1, q && q(e), m = o.render(o.props, o.state, o.context), Q.push.apply(o.__h, o._sb), o._sb = [];
      else do
        o.__d = !1, q && q(e), m = o.render(o.props, o.state, o.context), o.state = o.__s;
      while (o.__d && ++R < 25);
      o.state = o.__s, o.getChildContext != null && (a = F(F({}, a), o.getChildContext())), _ && !u && o.getSnapshotBeforeUpdate != null && (k = o.getSnapshotBeforeUpdate(v, b)), I = m != null && m.type === T && m.key == null ? Be(m.props.children) : m, s = Me(t, ie(I) ? I : [I], e, r, a, l, i, d, s, h, c), o.base = e.__e, e.__u &= -161, o.__h.length && d.push(o), y && (o.__E = o.__ = null);
    } catch (A) {
      if (d.length = f, e.__v = null, h || i != null) {
        if (A.then) {
          for (e.__u |= h ? 160 : 128; s && s.nodeType == 8 && s.nextSibling; ) s = s.nextSibling;
          i != null && (i[i.indexOf(s)] = null), e.__e = s;
        } else if (i != null) for (U = i.length; U--; ) he(i[U]);
      } else e.__e = r.__e;
      e.__k == null && (e.__k = r.__k || []), A.then || je(e), w.__e(A, e, r);
    }
  } else i == null && e.__v == r.__v ? (e.__k = r.__k, e.__e = r.__e) : s = e.__e = lt(r.__e, e, r, a, l, i, d, h, c);
  return (m = w.diffed) && m(e), 128 & e.__u ? void 0 : s;
}
function je(t) {
  t && (t.__c && (t.__c.__e = !0), t.__k && t.__k.some(je));
}
function ze(t, e, r) {
  for (var a = 0; a < r.length; a++) me(r[a], r[++a], r[++a]);
  w.__c && w.__c(e, t), t.some(function(l) {
    try {
      t = l.__h, l.__h = [], t.some(function(i) {
        i.call(l);
      });
    } catch (i) {
      w.__e(i, l.__v);
    }
  });
}
function Be(t) {
  return typeof t != "object" || t == null || t.__b > 0 ? t : ie(t) ? t.map(Be) : t.constructor !== void 0 ? null : F({}, t);
}
function lt(t, e, r, a, l, i, d, s, h) {
  var c, m, f, o, u, v, b, k = r.props || K, y = e.props, p = e.type;
  if (p == "svg" ? l = "http://www.w3.org/2000/svg" : p == "math" ? l = "http://www.w3.org/1998/Math/MathML" : l || (l = "http://www.w3.org/1999/xhtml"), i != null) {
    for (c = 0; c < i.length; c++) if ((u = i[c]) && "setAttribute" in u == !!p && (p ? u.localName == p : u.nodeType == 3)) {
      t = u, i[c] = null;
      break;
    }
  }
  if (t == null) {
    if (p == null) return document.createTextNode(y);
    t = document.createElementNS(l, p, y.is && y), s && (w.__m && w.__m(e, i), s = !1), i = null;
  }
  if (p == null) k === y || s && t.data == y || (t.data = y);
  else {
    if (i = p == "textarea" && y.defaultValue != null ? null : i && re.call(t.childNodes), !s && i != null) for (k = {}, c = 0; c < t.attributes.length; c++) k[(u = t.attributes[c]).name] = u.value;
    for (c in k) u = k[c], c == "dangerouslySetInnerHTML" ? f = u : c == "children" || c in y || c == "value" && "defaultValue" in y || c == "checked" && "defaultChecked" in y || j(t, c, null, u, l);
    for (c in y) u = y[c], c == "children" ? o = u : c == "dangerouslySetInnerHTML" ? m = u : c == "value" ? v = u : c == "checked" ? b = u : s && typeof u != "function" || k[c] === u || j(t, c, u, k[c], l);
    if (m) s || f && (m.__html == f.__html || m.__html == t.innerHTML) || (t.innerHTML = m.__html), e.__k = [];
    else if (f && (t.innerHTML = ""), Me(e.type == "template" ? t.content : t, ie(o) ? o : [o], e, r, a, p == "foreignObject" ? "http://www.w3.org/1999/xhtml" : l, i, d, i ? i[0] : r.__k && L(r, 0), s, h), i != null) for (c = i.length; c--; ) he(i[c]);
    s && p != "textarea" || (c = "value", p == "progress" && v == null ? t.removeAttribute("value") : v != null && (v !== t[c] || p == "progress" && !v || p == "option" && v != k[c]) && j(t, c, v, k[c], l), c = "checked", b != null && b != t[c] && j(t, c, b, k[c], l));
  }
  return t;
}
function me(t, e, r) {
  try {
    if (typeof t == "function") {
      var a = typeof t.__u == "function";
      a && t.__u(), a && e == null || (t.__u = t(e));
    } else t.current = e;
  } catch (l) {
    w.__e(l, r);
  }
}
function Ye(t, e, r) {
  var a, l;
  if (w.unmount && w.unmount(t), (a = t.ref) && (a.current && a.current != t.__e || me(a, null, e)), (a = t.__c) != null) {
    if (a.componentWillUnmount) try {
      a.componentWillUnmount();
    } catch (i) {
      w.__e(i, e);
    }
    a.base = a.__P = a.__n = null;
  }
  if (a = t.__k) for (l = 0; l < a.length; l++) a[l] && Ye(a[l], e, r || typeof t.type != "function");
  r || he(t.__e), t.__c = t.__ = t.__e = void 0;
}
function st(t, e, r) {
  return this.constructor(t, r);
}
function ct(t, e, r) {
  var a, l, i, d;
  e == document && (e = document.documentElement), w.__ && w.__(t, e), l = (a = !1) ? null : e.__k, i = [], d = [], _e(e, t = e.__k = rt(T, null, [t]), l || K, K, e.namespaceURI, l ? null : e.firstChild ? re.call(e.childNodes) : null, i, l ? l.__e : e.firstChild, a, d), ze(i, t, d), t.props.children = null;
}
re = Q.slice, w = { __e: function(t, e, r, a) {
  for (var l, i, d; e = e.__; ) if ((l = e.__c) && !l.__) try {
    if ((i = l.constructor) && i.getDerivedStateFromError != null && (l.setState(i.getDerivedStateFromError(t)), d = l.__d), l.componentDidCatch != null && (l.componentDidCatch(t, a || {}), d = l.__d), d) return l.__E = l;
  } catch (s) {
    t = s;
  }
  throw t;
} }, He = 0, G.prototype.setState = function(t, e) {
  var r;
  r = this.__s != null && this.__s != this.state ? this.__s : this.__s = F({}, this.state), typeof t == "function" && (t = t(F({}, r), this.props)), t && F(r, t), t != null && this.__v && (e && this._sb.push(e), ke(this));
}, G.prototype.forceUpdate = function(t) {
  this.__v && (this.__e = !0, t && this.__h.push(t), ke(this));
}, G.prototype.render = T, H = [], De = typeof Promise == "function" ? Promise.prototype.then.bind(Promise.resolve()) : setTimeout, Ee = function(t, e) {
  return t.__v.__b - e.__v.__b;
}, X.__r = 0, oe = Math.random().toString(8), B = "__d" + oe, M = "__a" + oe, Le = /(PointerCapture)$|Capture$/i, pe = 0, se = xe(!1), ce = xe(!0);
var dt = 0;
function n(t, e, r, a, l, i) {
  e || (e = {});
  var d, s, h = e;
  if ("ref" in h) for (s in h = {}, e) s == "ref" ? d = e[s] : h[s] = e[s];
  var c = { type: t, props: h, key: r, ref: d, __k: null, __: null, __b: 0, __e: null, __c: null, constructor: void 0, __v: --dt, __i: -1, __u: 0, __source: l, __self: i };
  if (typeof t == "function" && (d = t.defaultProps)) for (s in d) h[s] === void 0 && (h[s] = d[s]);
  return w.vnode && w.vnode(c), c;
}
var O, N, le, Ne, Z = 0, Ge = [], C = w, Se = C.__b, Ce = C.__r, qe = C.diffed, Te = C.__c, $e = C.unmount, Pe = C.__;
function fe(t, e) {
  C.__h && C.__h(N, t, Z || e), Z = 0;
  var r = N.__H || (N.__H = { __: [], __h: [] });
  return t >= r.__.length && r.__.push({}), r.__[t];
}
function P(t) {
  return Z = 1, ut(Ve, t);
}
function ut(t, e, r) {
  var a = fe(O++, 2);
  if (a.t = t, !a.__c && (a.__ = [Ve(void 0, e), function(s) {
    var h = a.__N ? a.__N[0] : a.__[0], c = a.t(h, s);
    h !== c && (a.__N = [c, a.__[1]], a.__c.setState({}));
  }], a.__c = N, !N.__f)) {
    var l = function(s, h, c) {
      if (!a.__c.__H) return !0;
      var m = !1, f = a.__c.props !== s;
      if (a.__c.__H.__.some(function(u) {
        if (u.__N) {
          m = !0;
          var v = u.__[0];
          u.__ = u.__N, u.__N = void 0, v !== u.__[0] && (f = !0);
        }
      }), i) {
        var o = i.call(this, s, h, c);
        return m ? o || f : o;
      }
      return !m || f;
    };
    N.__f = !0;
    var i = N.shouldComponentUpdate, d = N.componentWillUpdate;
    N.componentWillUpdate = function(s, h, c) {
      if (this.__e) {
        var m = i;
        i = void 0, l(s, h, c), i = m;
      }
      d && d.call(this, s, h, c);
    }, N.shouldComponentUpdate = l;
  }
  return a.__N || a.__;
}
function ee(t, e) {
  var r = fe(O++, 3);
  !C.__s && Je(r.__H, e) && (r.__ = t, r.u = e, N.__H.__h.push(r));
}
function pt(t, e) {
  var r = fe(O++, 7);
  return Je(r.__H, e) && (r.__ = t(), r.__H = e, r.__h = t), r.__;
}
function z(t, e) {
  return Z = 8, pt(function() {
    return t;
  }, e);
}
function ht() {
  for (var t; t = Ge.shift(); ) {
    var e = t.__H;
    if (t.__P && e) try {
      e.__h.some(J), e.__h.some(de), e.__h = [];
    } catch (r) {
      e.__h = [], C.__e(r, t.__v);
    }
  }
}
C.__b = function(t) {
  N = null, Se && Se(t);
}, C.__ = function(t, e) {
  t && e.__k && e.__k.__m && (t.__m = e.__k.__m), Pe && Pe(t, e);
}, C.__r = function(t) {
  Ce && Ce(t), O = 0;
  var e = (N = t.__c).__H;
  e && (le === N ? (e.__h = [], N.__h = [], e.__.some(function(r) {
    r.__N && (r.__ = r.__N), r.u = r.__N = void 0;
  })) : (e.__h.some(J), e.__h.some(de), e.__h = [], O = 0)), le = N;
}, C.diffed = function(t) {
  qe && qe(t);
  var e = t.__c;
  e && e.__H && (e.__H.__h.length && (Ge.push(e) !== 1 && Ne === C.requestAnimationFrame || ((Ne = C.requestAnimationFrame) || _t)(ht)), e.__H.__.some(function(r) {
    r.u && (r.__H = r.u, r.u = void 0);
  })), le = N = null;
}, C.__c = function(t, e) {
  e.some(function(r) {
    try {
      r.__h.some(J), r.__h = r.__h.filter(function(a) {
        return !a.__ || de(a);
      });
    } catch (a) {
      e.some(function(l) {
        l.__h && (l.__h = []);
      }), e = [], C.__e(a, r.__v);
    }
  }), Te && Te(t, e);
}, C.unmount = function(t) {
  $e && $e(t);
  var e, r = t.__c;
  r && r.__H && (r.__H.__.some(function(a) {
    try {
      J(a);
    } catch (l) {
      e = l;
    }
  }), r.__H = void 0, e && C.__e(e, r.__v));
};
var Re = typeof requestAnimationFrame == "function";
function _t(t) {
  var e, r = function() {
    clearTimeout(a), Re && cancelAnimationFrame(e), setTimeout(t);
  }, a = setTimeout(r, 35);
  Re && (e = requestAnimationFrame(r));
}
function J(t) {
  var e = N, r = t.__c;
  typeof r == "function" && (t.__c = void 0, r()), N = e;
}
function de(t) {
  var e = N;
  t.__c = t.__(), N = e;
}
function Je(t, e) {
  return !t || t.length !== e.length || e.some(function(r, a) {
    return r !== t[a];
  });
}
function Ve(t, e) {
  return typeof e == "function" ? e(t) : e;
}
const mt = "This local link has expired; no task or account change was made.", ft = /* @__PURE__ */ new Set(["contribute", "requests", "compose", "activity", "help", "settings", "tasks"]);
function Ie(t = "") {
  const e = String(t).replace(/^#\/?/, "").split("/").filter(Boolean), r = e[0]?.toLowerCase() || "contribute";
  return ft.has(r) ? { name: r, parts: e.slice(1) } : { name: "contribute", parts: [] };
}
function ue(t) {
  return t ? t.state === "not_joined" ? { name: "join" } : t.state === "pending_approval" ? { name: "pending" } : t.state === "approval_revoked" ? { name: "approval_revoked" } : t.state === "action_needed" ? { name: "action", action: t.action || {} } : t.state === "setup_required" ? { name: "setup", checks: t.action?.checks || [] } : { name: "status", title: { contributing: "Contributing", pausing: "Pausing after this task…", paused: "Paused", idle: "Ready when you are" }[t.state] || "Checking status", control: ["contributing", "pausing"].includes(t.state) ? "pause" : "start" } : { name: "loading" };
}
function vt(t) {
  const e = String(t || "").toLowerCase();
  return ["failed", "error", "returned"].includes(e) ? "failed" : e === "settled" ? "settled" : e === "claimed" ? "claimed" : ["submitted", "evaluating", "running"].includes(e) ? "running" : "queued";
}
function gt(t = {}) {
  const e = vt(t?.status), r = e === "failed" ? ["queued", "claimed", "running", "failed"] : ["queued", "claimed", "running", "settled"];
  return r.map((a, l) => ({ name: a, complete: l < r.indexOf(e), current: a === e, timestamp: t?.[`${a}_at`] || (a === "queued" ? t?.published_at : null) }));
}
function te(t) {
  const e = { anthropic: "Anthropic (Claude)", claude: "Anthropic (Claude)", openai: "OpenAI", github: "GitHub", google: "Google" }, r = String(t || "provider").trim();
  return e[r.toLowerCase()] || r;
}
function ve(t, e) {
  const r = String(t || "").trim();
  if (r) return r;
  try {
    return new URL(e).hostname || "Unknown collective";
  } catch {
    return "Unknown collective";
  }
}
function bt(t = {}) {
  return t.capacity_kind || t.capacity?.kind || t.kind || t.auth_kind || t.capacity_type || "not captured";
}
function Ke(t) {
  const e = (t?.accounts || t?.providers || [])[0];
  if (!e) return "your configured provider account";
  const r = te(e.provider || e.service || e.name), a = String(bt(e)).toLowerCase();
  return a.includes("local") ? `the ${r} local model` : a.includes("api") ? `your ${r} API key` : `your ${r} account`;
}
function Qe(t) {
  const e = String(t || "").toLowerCase();
  return ["contributing", "claimed", "running", "submitted", "evaluating"].includes(e) ? "active" : ["paused", "action_needed", "pending_approval", "pausing"].includes(e) ? "attention" : ["failed", "error", "approval_revoked", "unreachable", "session_expired"].includes(e) ? "problem" : "ready";
}
function Xe(t) {
  return String(t || "queued").replace(/[_-]+/g, " ").replace(/\b\w/g, (e) => e.toUpperCase());
}
const yt = ':root{--ink:#17212b;--muted:#5d6b76;--line:#d9e0e5;--surface:#fff;--page:#f7f9fa;--space-1:4px;--space-2:8px;--space-3:12px;--space-4:16px;--space-5:24px;--space-6:32px;--active:#19597e;--active-bg:#e6f0f7;--ready:#176a46;--ready-bg:#e1f3e8;--attention:#b37d17;--attention-bg:#fff4dc;--problem:#8b3513;--problem-bg:#fff0eb;font-family:Inter,ui-sans-serif,system-ui,sans-serif;color:var(--ink);background:var(--page)}*{box-sizing:border-box}body{margin:0;background:var(--page)}button,input,textarea{font:inherit}button,.button-link{border:0;border-radius:8px;padding:10px 14px;background:#19597e;color:#fff;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;gap:6px}button.secondary,.button-link.secondary{background:#fff;color:#19597e;border:1px solid #9fb4c2}button:disabled{opacity:.55;cursor:not-allowed}a{color:#19597e}#app>main,#main-content{width:min(1040px,calc(100% - 32px));margin:var(--space-6) auto}.app-header{min-height:64px;padding:0 max(16px,calc((100vw - 1040px)/2));display:flex;align-items:center;gap:var(--space-5);background:#fff;border-bottom:1px solid var(--line)}.brand{display:flex;gap:var(--space-2);color:var(--ink);text-decoration:none;font-weight:760;white-space:nowrap}.brand-mark{width:24px;height:24px;display:grid;place-items:center;border-radius:7px;color:#fff;background:#19597e}.primary-nav{margin-left:auto;display:flex;gap:var(--space-4)}.primary-nav a{padding:22px 0 18px;color:var(--muted);text-decoration:none;border-bottom:3px solid transparent}.primary-nav a[aria-current=page]{color:var(--ink);border-color:#19597e;font-weight:700}.gear{font-size:20px;color:var(--ink);text-decoration:none}.skip-link{position:absolute;left:-999px}.skip-link:focus{left:8px;top:8px;z-index:3;background:#fff;padding:8px}.view-stack{display:grid;gap:var(--space-4)}.panel{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:var(--space-5)}.panel-heading{margin-bottom:var(--space-4)}.panel h2{font-size:1.125rem;margin:0 0 var(--space-1)}.panel h3{margin-top:var(--space-5)}.muted,.detail,.quiet-note,.field-help{color:var(--muted)}.contribution-state{display:flex;gap:var(--space-3);align-items:flex-start}.status-label{font-size:1.5rem;line-height:1.2;margin:0;font-weight:760}.status-dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--ready)}.status-dot.large{margin-top:8px;width:14px;height:14px}.status-dot[data-status=active]{background:var(--active)}.status-dot[data-status=ready]{background:var(--ready)}.status-dot[data-status=attention]{background:var(--attention)}.status-dot[data-status=problem]{background:var(--problem)}.collective-line{font-weight:650}.actions{display:flex;flex-wrap:wrap;gap:var(--space-2);margin:var(--space-4) 0}.guard{padding:var(--space-3);background:var(--ready-bg);color:var(--ready);border-radius:8px}.notice{margin:0 0 var(--space-4);padding:var(--space-3);border:1px solid var(--problem);background:var(--problem-bg);color:var(--problem);border-radius:8px}.notice[data-status=attention]{border-color:var(--attention);background:var(--attention-bg);color:#77530d}.empty-state{padding:var(--space-4);background:#fff;border:1px dashed #afbec8;border-radius:8px}.empty-state strong{display:block}.task-list,.request-list,.history-list,.roster,.file-list{list-style:none;padding:0;margin:var(--space-4) 0 0}.task-row,.request-list li,.history-list li,.roster li{padding:var(--space-3) 0;border-top:1px solid var(--line)}.task-row,.request-select,.history-list li,.roster li{display:flex;justify-content:space-between;gap:var(--space-4);align-items:flex-start}.request-select{color:inherit;text-decoration:none;display:flex;width:100%}.request-select small{display:block;color:var(--muted);margin-top:var(--space-1)}.receipt-chips{display:flex;gap:var(--space-2);flex-wrap:wrap}.receipt-chip,.role-chip{padding:3px 7px;border-radius:999px;background:#edf1f3;font-size:.85rem}.consent-card{border-color:#b2cad8;box-shadow:0 4px 14px #17324f12}.full-prompt{white-space:pre-wrap;line-height:1.5}.chip{display:inline-flex;align-items:center;gap:6px;width:fit-content;padding:3px 8px;border-radius:999px;font-size:.85rem;font-weight:650;color:var(--ready);background:var(--ready-bg)}.chip[data-status=active]{color:var(--active);background:var(--active-bg)}.chip[data-status=attention]{color:#77530d;background:var(--attention-bg)}.chip[data-status=problem]{color:var(--problem);background:var(--problem-bg)}.timeline{padding:0;list-style:none;display:flex;gap:0;overflow:auto}.timeline li{min-width:130px;position:relative;padding:24px 12px 0 0;color:var(--muted)}.timeline li:before{content:"";position:absolute;top:7px;left:0;width:100%;height:2px;background:var(--line)}.timeline li:first-child:before{width:100%}.timeline li:after{content:"";position:absolute;top:1px;left:0;width:14px;height:14px;border-radius:50%;background:#fff;border:2px solid #a6b3bb}.timeline li.complete:after,.timeline li.current:after{border-color:var(--active);background:var(--active)}.timeline li strong,.timeline li span{display:block}.timeline li span{font-size:.85rem;margin-top:var(--space-1)}.execution-log{white-space:pre-wrap;overflow:auto;padding:var(--space-3);background:#17212b;color:#e9f0f4;border-radius:8px;max-height:400px}.receipt{display:grid;grid-template-columns:140px 1fr;gap:var(--space-2) var(--space-3)}.receipt dt{font-weight:700}.receipt dd{margin:0}.back-link{display:block;margin-bottom:calc(var(--space-4) * -1)}.segmented{display:flex;gap:var(--space-1);padding:var(--space-1);width:fit-content;border-radius:8px;background:#edf1f3}.segmented button{color:var(--muted);background:transparent;padding:7px 10px}.segmented button[aria-selected=true]{background:#fff;color:var(--ink);box-shadow:0 1px 2px #0002}.history-list li span,.roster li small{color:var(--muted)}.provider-card{padding:var(--space-3);border:1px solid var(--line);border-radius:8px;margin-top:var(--space-2)}.day-chips{display:flex;gap:var(--space-2);flex-wrap:wrap;margin:var(--space-2) 0}.day-chips button{background:#fff;color:var(--ink);border:1px solid var(--line);padding:8px 10px}.day-chips button.selected{background:var(--active-bg);color:var(--active);border-color:var(--active)}form{display:grid;gap:var(--space-2)}label{font-weight:650;display:grid;gap:var(--space-1)}input,textarea{width:100%;padding:9px;border:1px solid #aebdc7;border-radius:7px;background:#fff}input[type=checkbox]{width:auto;margin-right:var(--space-1)}textarea{min-height:120px;resize:vertical}.form-feedback{min-height:1.5rem;color:var(--problem)}.one-time-code-wrap{display:inline-flex;gap:var(--space-2);align-items:center}.one-time-code{padding:4px 6px;background:#eef1f3;border-radius:4px;cursor:pointer}.full-bleed{display:grid;place-items:center;min-height:100vh;margin:0!important;width:100%!important}.full-bleed .panel{max-width:600px;width:calc(100% - 32px)}.stop-now{margin:var(--space-3) 0}.collectives{list-style:none;padding:0;margin:0}.collectives li{display:flex;align-items:flex-start;justify-content:space-between;gap:var(--space-4);padding:var(--space-3) 0;border-top:1px solid var(--line)}.collectives p{margin:var(--space-1) 0}.collective-actions{margin:0}.one-time-code-wrap{display:flex;max-width:100%;min-width:0}.one-time-code{flex:1;min-width:0;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.full-bleed{min-height:calc(100vh - 64px);align-content:start;padding-top:var(--space-6)}.full-bleed .panel{width:min(600px,calc(100vw - 32px));min-width:0}@media(max-width:700px){.app-header{gap:var(--space-2);flex-wrap:wrap;padding:var(--space-2) var(--space-4)}.primary-nav{margin-left:0;order:3;width:100%;gap:var(--space-3);overflow:auto}.primary-nav a{padding:var(--space-2) 0}.brand{font-size:.95rem}#app>main,#main-content{width:min(100% - 24px,1040px);margin:var(--space-4) auto}.panel{padding:var(--space-4)}.timeline li{min-width:108px}.task-row,.history-list li,.collectives li{flex-direction:column;gap:var(--space-2)}.receipt{grid-template-columns:1fr;gap:var(--space-1)}.receipt dd{margin-bottom:var(--space-2)}.one-time-code-wrap{align-items:stretch}.one-time-code-wrap button{flex:0 0 auto}}', kt = 1500, Ae = { display_id: "", prompt: "", source: "", git_url: "", git_ref: "", git_probe: "", github_access_required: !1, files: [], network: !1, error: "" }, wt = [["contribute", "Contribute"], ["requests", "Requests"], ["activity", "Activity"], ["help", "Help"]], D = (t) => Array.isArray(t) ? t : [], ge = (t) => {
  const e = new Date(t || "");
  return Number.isFinite(e.getTime()) ? new Intl.DateTimeFormat(void 0, { dateStyle: "medium", timeStyle: "short" }).format(e) : "Not captured";
}, xt = (t) => typeof t == "number" ? `${Math.max(0, Math.round(t / 1e3))} seconds` : t || "Not captured — the harness did not report a duration.", Nt = (t) => String(t || "").split(/\r?\n/).map((e) => e.trim()).find(Boolean) || "Prompt preview is not available.", Fe = (t) => String(t || "").replace(/^sha256:/, ""), St = async (t) => {
  const e = new Uint8Array(await t.arrayBuffer());
  let r = "";
  for (let a = 0; a < e.length; a += 32768) r += String.fromCharCode(...e.subarray(a, a + 32768));
  return { name: t.name, relative_path: t.webkitRelativePath || t.name, data_base64: btoa(r) };
};
function S({ title: t, lead: e, children: r, className: a = "" }) {
  return /* @__PURE__ */ n("section", { className: `panel ${a}`, children: [
    /* @__PURE__ */ n("div", { className: "panel-heading", children: [
      t && /* @__PURE__ */ n("h2", { children: t }),
      e && /* @__PURE__ */ n("p", { className: "muted", children: e })
    ] }),
    r
  ] });
}
function ne({ value: t }) {
  const e = Qe(t);
  return /* @__PURE__ */ n("span", { className: "chip", "data-status": e, children: [
    /* @__PURE__ */ n("span", { className: "status-dot", "data-status": e }),
    Xe(t)
  ] });
}
function W({ status: t = "problem", children: e }) {
  return e ? /* @__PURE__ */ n("div", { className: "notice", "data-status": t, role: "status", children: e }) : null;
}
function Ue({ value: t }) {
  const e = () => {
    navigator.clipboard?.writeText(t);
  }, r = t.length > 96 ? `${t.slice(0, 96)}…` : t;
  return /* @__PURE__ */ n("span", { className: "one-time-code-wrap", children: [
    /* @__PURE__ */ n("code", { className: "one-time-code", title: t, tabIndex: "0", onClick: e, children: r }),
    /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: e, children: "Copy code" })
  ] });
}
function V({ route: t }) {
  return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n("a", { className: "skip-link", href: "#main-content", children: "Skip to content" }),
    /* @__PURE__ */ n("header", { className: "app-header", children: [
      /* @__PURE__ */ n("a", { className: "brand", href: "#/contribute", children: [
        /* @__PURE__ */ n("span", { className: "brand-mark", children: "W" }),
        /* @__PURE__ */ n("span", { children: "Waspflow Federation" })
      ] }),
      /* @__PURE__ */ n("nav", { className: "primary-nav", "aria-label": "Federation sections", children: wt.map(([e, r]) => /* @__PURE__ */ n("a", { href: `#/${e}`, "aria-current": t === e ? "page" : void 0, children: r })) }),
      /* @__PURE__ */ n("a", { className: "gear", href: "#/settings/device", "aria-label": "Settings", title: "Settings", children: "⚙" })
    ] })
  ] });
}
function Ze({ view: t, status: e, control: r }) {
  const [a, l] = P("");
  if (t.name === "loading") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: "Checking Federation status", lead: "Loading your local Federation state before showing the next step." }) });
  if (t.name === "join") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: "Join your collective", lead: "Paste the invite your operator sent you.", children: [
    /* @__PURE__ */ n("label", { htmlFor: "invite", children: "Invite" }),
    /* @__PURE__ */ n("textarea", { id: "invite", value: a, onInput: (s) => l(s.currentTarget.value), placeholder: "Paste your invite link" }),
    /* @__PURE__ */ n("div", { className: "actions", children: /* @__PURE__ */ n("button", { type: "button", onClick: () => r("/join", { invite: a }), children: "Join collective" }) }),
    /* @__PURE__ */ n("details", { children: [
      /* @__PURE__ */ n("summary", { children: "Using a terminal instead?" }),
      /* @__PURE__ */ n("p", { children: "Paste this invite link into Waspflow Federation." })
    ] })
  ] }) });
  if (t.name === "pending") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: "Approval requested", lead: `Your request is with ${ve(e?.collective_name, e?.coordinator_url)}.`, children: [
    /* @__PURE__ */ n("p", { children: "Send this approval request to your operator. You can close this after — contributions start once they approve your machine." }),
    e?.approval_request ? /* @__PURE__ */ n(T, { children: [
      /* @__PURE__ */ n("label", { children: "Approval request" }),
      /* @__PURE__ */ n(Ue, { value: e.approval_request })
    ] }) : null,
    /* @__PURE__ */ n(W, { status: "attention", children: e?.coordinator_unavailable ? /* @__PURE__ */ n(T, { children: [
      "Collective unavailable. Switch to another collective, or ask its operator to bring it back online; approval will refresh when it returns.",
      /* @__PURE__ */ n("div", { className: "actions", children: /* @__PURE__ */ n("a", { className: "button-link secondary", href: "#/settings/collective", children: "View collectives" }) })
    ] }) : null })
  ] }) });
  if (t.name === "approval_revoked") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: "Approval was revoked", lead: "No new work will start on this machine.", children: [
    /* @__PURE__ */ n("p", { children: e?.detail || "Ask your collective owner to approve this machine again." }),
    /* @__PURE__ */ n("button", { type: "button", onClick: () => location.reload(), children: "Refresh approval" })
  ] }) });
  if (t.name === "setup") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: "Your sandbox needs attention", lead: "Complete this once, then come back to contribute.", children: [
    /* @__PURE__ */ n("ol", { children: (t.checks.length ? t.checks : [{ detail: "Open Federation again after Docker Sandbox setup is complete." }]).map((s) => /* @__PURE__ */ n("li", { children: [
      s.detail || s.name,
      " ",
      s.fix || ""
    ] })) }),
    /* @__PURE__ */ n("p", { children: e?.detail })
  ] }) });
  const i = t.action || {}, d = te(i.service || "your provider");
  return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: i.kind === "awaiting_browser" ? `Sign in to ${d}` : "Sign-in needs attention", lead: i.kind === "awaiting_browser" ? "Finish this one browser step, then return here." : `${d} sign-in isn't available from this screen yet.`, children: [
    /* @__PURE__ */ n("p", { children: i.kind === "awaiting_browser" ? "No task will resume automatically. Federation will show the result here after you finish." : e?.detail || "Contact your collective owner, then try again later." }),
    i.kind === "awaiting_browser" && /* @__PURE__ */ n("button", { type: "button", onClick: () => window.open(i.url, "_blank", "noopener"), children: [
      "Sign in to ",
      d
    ] }),
    i.code && /* @__PURE__ */ n("p", { children: [
      "Confirmation code: ",
      /* @__PURE__ */ n(Ue, { value: i.code })
    ] })
  ] }) });
}
function E({ children: t }) {
  return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n(V, { route: "contribute" }),
    /* @__PURE__ */ n("main", { id: "main-content", className: "full-bleed", children: t })
  ] });
}
function Ct({ status: t, settings: e, tasks: r, identity: a, coordinatorUnavailable: l, control: i, goTask: d, beginGitHub: s }) {
  const h = ue(t), [c, m] = P(null), [f, o] = P(!1);
  if (h.name !== "status") return /* @__PURE__ */ n(Ze, { view: h, status: t, control: i });
  const u = h.control === "pause", v = t?.contribution || {}, b = c || r[0];
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n(S, { title: "Your contribution", children: [
      /* @__PURE__ */ n("div", { className: "contribution-state", children: [
        /* @__PURE__ */ n("span", { className: "status-dot large", "data-status": Qe(t?.state) }),
        /* @__PURE__ */ n("div", { children: [
          /* @__PURE__ */ n("p", { className: "status-label", children: h.title }),
          /* @__PURE__ */ n("p", { className: "detail", children: u && v.display_id ? `Working on “${v.display_id}”${v.requester || v.author ? ` for ${v.requester || v.author}` : ""}` : t?.detail || "Nothing will run until you approve a task." })
        ] })
      ] }),
      /* @__PURE__ */ n("p", { className: "collective-line", children: [
        "Collective: ",
        ve(e?.collective_name || t?.collective_name, t?.coordinator_url)
      ] }),
      /* @__PURE__ */ n(W, { status: "problem", children: l ? /* @__PURE__ */ n(T, { children: [
        "Collective unavailable. Nothing changed on this computer. Switch to another collective, or ask its operator to bring it back online.",
        /* @__PURE__ */ n("div", { className: "actions", children: /* @__PURE__ */ n("a", { className: "button-link secondary", href: "#/settings/collective", children: "View collectives" }) })
      ] }) : null }),
      /* @__PURE__ */ n("div", { className: "actions", children: [
        u ? /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => i("/contribute/pause"), children: "Pause after this task" }) : null,
        u && v.task_digest ? /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => d(v.task_digest), children: "Watch what it’s doing →" }) : null
      ] }),
      u && /* @__PURE__ */ n("div", { className: "stop-now", children: f ? /* @__PURE__ */ n(T, { children: [
        /* @__PURE__ */ n("p", { children: "Stop now abandons the current task. Waspflow records it as returned." }),
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => i("/contribute/stop", { confirm: !0 }), children: "Stop now" }),
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => o(!1), children: "Keep working" })
      ] }) : /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => o(!0), children: "Stop now" }) }),
      /* @__PURE__ */ n("div", { className: "guard", children: /* @__PURE__ */ n("strong", { children: "You approve every task before it starts. Nothing runs while paused." }) })
    ] }),
    !u && !l && (b ? /* @__PURE__ */ n(S, { title: c ? "Review this task" : "Tasks ready for review", lead: c ? "Read the full request before deciding whether to use your account." : "Nothing runs without your say.", className: c ? "consent-card" : "", children: c ? /* @__PURE__ */ n(T, { children: [
      /* @__PURE__ */ n("p", { children: [
        /* @__PURE__ */ n("strong", { children: b.display_id || "Untitled task" }),
        " from ",
        b.author || "Unknown requester"
      ] }),
      /* @__PURE__ */ n("p", { className: "full-prompt", children: b.prompt || b.prompt_preview || "Prompt was not included." }),
      /* @__PURE__ */ n("p", { children: [
        "Will use: ",
        Ke(a),
        " · isolated sandbox",
        b.network === "enabled" || b.git_source ? " · internet access" : ""
      ] }),
      /* @__PURE__ */ n("p", { children: "Estimated: a few minutes, based on similar tasks." }),
      /* @__PURE__ */ n(et, { task: b }),
      /* @__PURE__ */ n("div", { className: "actions", children: [
        b.git_source?.authentication_required && !D(a?.providers).some((k) => k.service === "github" && k.authed) ? /* @__PURE__ */ n("button", { type: "button", onClick: s, children: "Set up GitHub access" }) : /* @__PURE__ */ n("button", { type: "button", onClick: () => i("/contribute/start", { task_digest: b.task_digest }), children: "Accept and run" }),
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => m(null), children: "Skip this one" })
      ] })
    ] }) : /* @__PURE__ */ n(T, { children: [
      /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => m(b), children: "Review the next task" }),
      /* @__PURE__ */ n(qt, { tasks: r, onSelect: m })
    ] }) }) : /* @__PURE__ */ n("div", { className: "empty-state", children: [
      /* @__PURE__ */ n("strong", { children: "No tasks are waiting." }),
      /* @__PURE__ */ n("p", { children: "You’ll see a review card here the moment one is ready — nothing runs without your say." })
    ] }))
  ] });
}
function et({ task: t }) {
  return /* @__PURE__ */ n("div", { className: "receipt-chips", children: [
    (t?.github_access_required || t?.git_source?.authentication_required) && /* @__PURE__ */ n("span", { className: "receipt-chip", children: "Needs: GitHub" }),
    (t?.network === "enabled" || t?.git_source) && /* @__PURE__ */ n("span", { className: "receipt-chip", children: "Needs: internet" })
  ] });
}
function qt({ tasks: t, onSelect: e }) {
  return /* @__PURE__ */ n("ul", { className: "task-list", children: t.map((r) => /* @__PURE__ */ n("li", { className: "task-row", children: [
    /* @__PURE__ */ n("div", { children: [
      /* @__PURE__ */ n("strong", { children: r.display_id || "Untitled task" }),
      /* @__PURE__ */ n("p", { className: "muted", children: r.author ? `from ${r.author}` : "Requester not captured yet" }),
      /* @__PURE__ */ n("p", { children: Nt(r.prompt_preview || r.prompt) }),
      /* @__PURE__ */ n(et, { task: r })
    ] }),
    /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => e(r), children: "Review" })
  ] })) });
}
function Tt({ digest: t, task: e, log: r, loadLog: a, resultHref: l }) {
  const i = String(e?.status || "").toLowerCase() === "settled";
  return ee(() => {
    t && a(t);
  }, [t]), /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n("a", { className: "back-link", href: "#/requests", children: "← Requests" }),
    /* @__PURE__ */ n(S, { title: e?.display_id || "Task", lead: /* @__PURE__ */ n(ne, { value: e?.status || "queued" }), children: [
      /* @__PURE__ */ n($t, { task: e }),
      /* @__PURE__ */ n("h3", { children: "Live transcript" }),
      /* @__PURE__ */ n(Pt, { log: r }),
      /* @__PURE__ */ n("h3", { children: "What was asked" }),
      /* @__PURE__ */ n("p", { className: "full-prompt", children: e?.prompt || e?.prompt_preview || "Task details are still loading." }),
      i && /* @__PURE__ */ n("details", { children: [
        /* @__PURE__ */ n("summary", { children: "Result and receipt" }),
        /* @__PURE__ */ n(Rt, { task: e }),
        l && /* @__PURE__ */ n("a", { className: "button-link", href: l, children: "Download result" })
      ] })
    ] })
  ] });
}
function $t({ task: t }) {
  return /* @__PURE__ */ n("ol", { className: "timeline", children: gt(t).map((e) => /* @__PURE__ */ n("li", { className: e.complete ? "complete" : e.current ? "current" : "", children: [
    /* @__PURE__ */ n("strong", { children: Xe(e.name) }),
    /* @__PURE__ */ n("span", { children: e.timestamp ? ge(e.timestamp) : e.current ? "In progress" : "Waiting" })
  ] })) });
}
function Pt({ log: t }) {
  return t ? /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n("details", { open: !0, children: [
      /* @__PURE__ */ n("summary", { children: "Readable transcript" }),
      /* @__PURE__ */ n("pre", { className: "execution-log", children: t.output || "No output was captured." })
    ] }),
    /* @__PURE__ */ n("details", { children: [
      /* @__PURE__ */ n("summary", { children: "Raw JSON" }),
      /* @__PURE__ */ n("pre", { className: "execution-log", children: JSON.stringify(t, null, 2) })
    ] })
  ] }) : /* @__PURE__ */ n("p", { className: "muted", children: "Live output will appear here when the task harness reports it." });
}
function Rt({ task: t }) {
  const e = t?.execution_metadata || t?.receipt || {}, r = [["Harness", e.harness_id], ["Model", t?.model || e.model], ["Tokens", t?.tokens || e.tokens || It(e)], ["Duration", xt(t?.duration || e.duration || e.duration_ms)], ["Sandbox", t?.sandbox_id || e.sandbox_id]];
  return /* @__PURE__ */ n("dl", { className: "receipt", children: r.map(([a, l]) => /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n("dt", { children: a }),
    /* @__PURE__ */ n("dd", { children: l || "Not captured — this task ran before receipts were enabled." })
  ] })) });
}
function It(t) {
  const e = t.usage || t;
  return e.input_tokens !== void 0 || e.output_tokens !== void 0 ? `${e.input_tokens || e.tokens_in || 0} tokens in · ${e.output_tokens || e.tokens_out || 0} tokens out` : "";
}
function At({ requests: t, submission: e, form: r, setForm: a, submit: l, probeGit: i, acknowledge: d }) {
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    e && /* @__PURE__ */ n(S, { title: "Submission status", children: [
      /* @__PURE__ */ n(ne, { value: e.status || "pending" }),
      /* @__PURE__ */ n("p", { children: e.detail || "Your request is being published." }),
      e.error && /* @__PURE__ */ n(W, { children: e.error }),
      /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: d, children: "Acknowledge" })
    ] }),
    /* @__PURE__ */ n(S, { title: "Requests", lead: "Submitted tasks and their live progress.", children: [
      /* @__PURE__ */ n("div", { className: "actions", children: /* @__PURE__ */ n("a", { className: "button-link", href: "#/compose", children: "+ New request" }) }),
      t.length ? /* @__PURE__ */ n("ul", { className: "request-list", children: t.map((s) => /* @__PURE__ */ n("li", { children: /* @__PURE__ */ n("a", { className: "request-select", href: `#/tasks/${encodeURIComponent(s.task_digest)}`, children: [
        /* @__PURE__ */ n("span", { children: [
          /* @__PURE__ */ n("strong", { children: s.display_id || "Untitled task" }),
          /* @__PURE__ */ n("small", { children: s.published_at ? ge(s.published_at) : "Recently submitted" })
        ] }),
        /* @__PURE__ */ n(ne, { value: s.status })
      ] }) })) }) : /* @__PURE__ */ n("div", { className: "empty-state", children: [
        /* @__PURE__ */ n("strong", { children: "No requests yet." }),
        /* @__PURE__ */ n("p", { children: "Submitted tasks and their live progress will show up here." })
      ] })
    ] })
  ] });
}
function Ft({ form: t, setForm: e, submit: r, probeGit: a }) {
  const l = (s) => (h) => e((c) => ({ ...c, [s]: h.currentTarget.type === "checkbox" ? h.currentTarget.checked : h.currentTarget.value, error: "" })), i = (s) => e((h) => ({ ...h, files: [...h.files, ...Array.from(s.currentTarget.files || [])], error: "" }));
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n("a", { className: "back-link", href: "#/requests", children: "← Requests" }),
    /* @__PURE__ */ n(S, { title: "New request", lead: "Describe the outcome for your collective.", children: /* @__PURE__ */ n("form", { onSubmit: (s) => {
      s.preventDefault(), r(t);
    }, children: [
      /* @__PURE__ */ n("label", { htmlFor: "task-name", children: "Task name" }),
      /* @__PURE__ */ n("input", { id: "task-name", value: t.display_id, onInput: l("display_id"), required: !0 }),
      /* @__PURE__ */ n("label", { htmlFor: "task-prompt", children: "What should this task accomplish?" }),
      /* @__PURE__ */ n("textarea", { id: "task-prompt", value: t.prompt, onInput: l("prompt"), required: !0 }),
      /* @__PURE__ */ n("label", { htmlFor: "task-files", children: [
        "Add files (optional)",
        /* @__PURE__ */ n("input", { id: "task-files", type: "file", multiple: !0, onChange: i })
      ] }),
      /* @__PURE__ */ n("label", { htmlFor: "task-folder-upload", children: [
        "Add folder (optional)",
        /* @__PURE__ */ n("input", { id: "task-folder-upload", type: "file", webkitdirectory: "", onChange: i })
      ] }),
      t.files.length > 0 && /* @__PURE__ */ n("ul", { className: "file-list", children: t.files.map((s, h) => /* @__PURE__ */ n("li", { children: [
        s.webkitRelativePath || s.name,
        " · ",
        s.size,
        " bytes ",
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => e((c) => ({ ...c, files: c.files.filter((m, f) => f !== h) })), children: "Remove" })
      ] })) }),
      /* @__PURE__ */ n("details", { children: [
        /* @__PURE__ */ n("summary", { children: "Advanced" }),
        /* @__PURE__ */ n("label", { htmlFor: "task-folder", children: "Use a folder already on this computer (where Waspflow runs)" }),
        /* @__PURE__ */ n("input", { id: "task-folder", value: t.source, onInput: l("source") }),
        /* @__PURE__ */ n("label", { htmlFor: "task-git-url", children: "Git repository (optional)" }),
        /* @__PURE__ */ n("input", { id: "task-git-url", value: t.git_url, onInput: l("git_url"), onBlur: () => t.git_url && a(t.git_url) }),
        /* @__PURE__ */ n("label", { htmlFor: "task-git-ref", children: "Branch or ref (optional)" }),
        /* @__PURE__ */ n("input", { id: "task-git-ref", value: t.git_ref, onInput: l("git_ref") }),
        /* @__PURE__ */ n("label", { children: [
          /* @__PURE__ */ n("input", { type: "checkbox", checked: t.github_access_required, onChange: l("github_access_required") }),
          " Task needs GitHub access"
        ] }),
        /* @__PURE__ */ n("label", { children: [
          /* @__PURE__ */ n("input", { type: "checkbox", checked: t.network, onChange: l("network"), disabled: !!t.git_url }),
          " Allow internet access"
        ] }),
        /* @__PURE__ */ n("p", { className: "field-help", children: t.git_url ? "This only lets the task read the repository it names — never your other GitHub activity." : "When on, tasks can fetch public resources." })
      ] }),
      /* @__PURE__ */ n("p", { className: "form-feedback", role: "alert", children: t.error }),
      /* @__PURE__ */ n("button", { type: "submit", children: "Submit task" })
    ] }) })
  ] });
}
function Ut({ ledger: t, requests: e }) {
  const [r, a] = P("did"), l = r === "did" ? t.filter((i) => i.role !== "requester" && i.author !== "me") : e;
  return /* @__PURE__ */ n("div", { className: "view-stack", children: /* @__PURE__ */ n(S, { title: "Activity", children: [
    /* @__PURE__ */ n("div", { className: "segmented", role: "tablist", children: [
      /* @__PURE__ */ n("button", { type: "button", "aria-selected": r === "did", onClick: () => a("did"), children: "What I did" }),
      /* @__PURE__ */ n("button", { type: "button", "aria-selected": r === "asked", onClick: () => a("asked"), children: "What I asked for" })
    ] }),
    l.length ? /* @__PURE__ */ n("ul", { className: "history-list", children: l.map((i) => /* @__PURE__ */ n("li", { children: [
      /* @__PURE__ */ n("strong", { children: i.display_id || "Untitled task" }),
      /* @__PURE__ */ n("span", { children: r === "did" ? `Completed for ${i.requester || i.author || "your collective"}` : "Requested by you" }),
      /* @__PURE__ */ n(ne, { value: i.status })
    ] })) }) : /* @__PURE__ */ n("div", { className: "empty-state", children: [
      /* @__PURE__ */ n("strong", { children: r === "did" ? "Nothing completed yet." : "No requests yet." }),
      /* @__PURE__ */ n("p", { children: r === "did" ? "Every task you run will get a full private receipt here." : "Submitted tasks and their live progress will show up here." })
    ] })
  ] }) });
}
function Ht({ section: t, identity: e, settings: r, roster: a, collectives: l, save: i, signIn: d, status: s, join: h, switchCollective: c, leaveCollective: m, message: f }) {
  const [o, u] = P(r?.schedule || { enabled: !1, start: "", end: "", days: "", timezone: Intl.DateTimeFormat().resolvedOptions().timeZone }), [v, b] = P(""), k = ["contributing", "pausing", "action_needed"].includes(s?.state) || ["pending", "published"].includes(s?.submission?.state);
  if (ee(() => {
    r?.schedule && u(r.schedule);
  }, [r]), t === "collective") return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n(S, { title: "Your collectives", lead: "You can belong to many collectives. One is active at a time for now.", children: [
      /* @__PURE__ */ n("ul", { className: "collectives", children: l.map((p) => /* @__PURE__ */ n("li", { children: [
        /* @__PURE__ */ n("div", { children: [
          /* @__PURE__ */ n("strong", { children: ve(p.collective_name, p.coordinator_url) }),
          /* @__PURE__ */ n("p", { className: "muted", children: p.active ? p.reachable === !1 ? "Active · unavailable — switch away or ask its operator to bring it back online." : "Active · ready to use." : "Inactive · switch to check this collective." })
        ] }),
        /* @__PURE__ */ n("div", { className: "actions collective-actions", children: [
          !p.active && /* @__PURE__ */ n("button", { type: "button", className: "secondary", disabled: k, onClick: () => c(p.id), children: "Switch" }),
          /* @__PURE__ */ n("button", { type: "button", className: "secondary", disabled: k, onClick: () => m(p.id), children: "Leave" })
        ] })
      ] })) }),
      k && /* @__PURE__ */ n("p", { className: "muted", children: "Finish the current work before switching collectives." }),
      /* @__PURE__ */ n("h3", { children: "Join another collective" }),
      /* @__PURE__ */ n("label", { htmlFor: "switch-invite", children: [
        "Invite",
        /* @__PURE__ */ n("textarea", { id: "switch-invite", value: v, onInput: (p) => b(p.currentTarget.value), placeholder: "Paste an invite link" })
      ] }),
      /* @__PURE__ */ n("button", { type: "button", disabled: k, onClick: () => h(v), children: "Join collective" }),
      /* @__PURE__ */ n(W, { children: f })
    ] }),
    a.length > 0 && /* @__PURE__ */ n(S, { title: "Members", lead: r?.collective_name || e?.collective_name || "Active collective", children: /* @__PURE__ */ n("ul", { className: "roster", children: a.map((p) => /* @__PURE__ */ n("li", { children: [
      /* @__PURE__ */ n("strong", { children: p.display_name || p.name || p.key_id }),
      /* @__PURE__ */ n("span", { className: "role-chip", children: p.role || "Member" }),
      p.joined_at && /* @__PURE__ */ n("small", { children: [
        "Joined ",
        ge(p.joined_at)
      ] })
    ] })) }) })
  ] });
  const y = D(e?.accounts || e?.providers);
  return /* @__PURE__ */ n("div", { className: "view-stack", children: /* @__PURE__ */ n(S, { title: "Device & accounts", lead: "Settings for this computer only.", children: [
    /* @__PURE__ */ n("p", { children: [
      "Your machine’s ID: ",
      e?.key_id || "Not detected yet",
      " — this is how the collective recognizes this computer, not a person."
    ] }),
    /* @__PURE__ */ n("h3", { children: "Schedule" }),
    /* @__PURE__ */ n("label", { children: [
      /* @__PURE__ */ n("input", { type: "checkbox", checked: o.enabled, onChange: (p) => u({ ...o, enabled: p.currentTarget.checked }) }),
      " Contribute on a schedule"
    ] }),
    /* @__PURE__ */ n("div", { className: "day-chips", children: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((p) => /* @__PURE__ */ n("button", { type: "button", className: String(o.days || "").split(",").includes(p) ? "selected" : "", onClick: () => {
      const _ = new Set(String(o.days || "").split(",").filter(Boolean));
      _.has(p) ? _.delete(p) : _.add(p), u({ ...o, days: [..._].join(",") });
    }, children: p })) }),
    /* @__PURE__ */ n("label", { children: [
      "Start",
      /* @__PURE__ */ n("input", { value: o.start || "", onInput: (p) => u({ ...o, start: p.currentTarget.value }) })
    ] }),
    /* @__PURE__ */ n("label", { children: [
      "End",
      /* @__PURE__ */ n("input", { value: o.end || "", onInput: (p) => u({ ...o, end: p.currentTarget.value }) })
    ] }),
    /* @__PURE__ */ n("p", { className: "muted", children: [
      "Schedule times are in ",
      o.timezone || "your local timezone",
      "."
    ] }),
    /* @__PURE__ */ n("button", { type: "button", onClick: () => i({ ...r, schedule: o }), children: "Save device settings" }),
    /* @__PURE__ */ n("h3", { children: "Accounts" }),
    y.map((p) => /* @__PURE__ */ n("div", { className: "provider-card", children: [
      /* @__PURE__ */ n("strong", { children: te(p.service || p.provider) }),
      /* @__PURE__ */ n("p", { children: p.authed ? "Ready to use" : "Not detected yet — checking your sign-in…" }),
      !p.authed && /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => d(p.service || p.provider), children: [
        "Sign in to ",
        te(p.service || p.provider)
      ] })
    ] })),
    /* @__PURE__ */ n("h3", { children: "Docker account" }),
    /* @__PURE__ */ n("p", { children: e?.docker_account || (e?.docker_status === "failed" ? "Not detected yet — checking your Docker sign-in…" : "Checking…") }),
    s?.detail?.match(/sign-in could not start/i) && /* @__PURE__ */ n(W, { status: "attention", children: [
      "Sign-in needs attention: ",
      s.detail
    ] })
  ] }) });
}
function Dt({ identity: t }) {
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n(S, { title: "How Federation works", lead: "A trusted collective shares spare capacity without sharing your computer.", children: [
      /* @__PURE__ */ n("p", { children: "You choose when to contribute and approve each task before it runs. You can belong to several collectives, while one active collective uses this machine at a time." }),
      /* @__PURE__ */ n("ol", { children: [
        /* @__PURE__ */ n("li", { children: "A requester packages one chosen folder and describes the work." }),
        /* @__PURE__ */ n("li", { children: "A contributor accepts a task only when contributing is on." }),
        /* @__PURE__ */ n("li", { children: "The task runs in an isolated Docker sandbox and returns a receipt and result." })
      ] })
    ] }),
    /* @__PURE__ */ n(S, { title: "Your safety boundary", children: /* @__PURE__ */ n("p", { children: "Everything else is blocked. Tasks cannot read your other files, reach your home network, or see other tasks." }) }),
    /* @__PURE__ */ n(S, { title: "Questions people ask", children: [
      /* @__PURE__ */ n("details", { open: !0, children: [
        /* @__PURE__ */ n("summary", { children: "Whose account is used?" }),
        /* @__PURE__ */ n("p", { children: [
          Ke(t),
          " is used only inside the contributor’s isolated Federation environment."
        ] })
      ] }),
      /* @__PURE__ */ n("details", { children: [
        /* @__PURE__ */ n("summary", { children: "What happens if I get interrupted mid-task?" }),
        /* @__PURE__ */ n("p", { children: "Pause after the current task finishes, or stop now to return it to the collective." })
      ] })
    ] })
  ] });
}
function Et() {
  const t = new URLSearchParams(location.search).get("token") || "", [e, r] = P({ status: null, tasks: [], requests: [], ledger: [], identity: null, settings: null, roster: [], collectives: [], coordinatorUnavailable: !1, sessionExpired: !1, daemonUnavailable: !1, message: "", submission: null }), [a, l] = P(Ae), [i, d] = P(() => Ie(location.hash)), [s, h] = P(null), [c, m] = P(null), f = z(async (_, g = {}) => {
    const x = await fetch(_, { ...g, headers: { "x-waspflow-session-token": t, ...g.body ? { "content-type": "application/json" } : {} } });
    let q = {};
    try {
      q = await x.json();
    } catch {
    }
    if (!x.ok) {
      const R = new Error(q.error || "Waspflow could not complete that request.");
      throw R.status = x.status, R;
    }
    return q;
  }, [t]), o = z(async () => {
    try {
      const _ = await f("/status"), g = !_.coordinator_unavailable && _.state !== "not_joined", [x, q, R, I, U, $, A, be] = await Promise.all([_.state === "idle" ? f("/tasks").catch(() => []) : Promise.resolve([]), f("/ledger").catch(() => []), f("/identity").catch(() => null), f("/settings").catch(() => null), g ? f("/roster").catch(() => []) : Promise.resolve([]), g ? f("/activity").catch(() => []) : Promise.resolve([]), g ? f("/requests").catch(() => null) : Promise.resolve(null), f("/collectives").catch(() => [])]);
      r((tt) => ({ ...tt, status: _, tasks: D(x), ledger: D(q), identity: R || { key_id: _.key_id, coordinator_url: _.coordinator_url }, settings: I, roster: D(U?.roster || U), requests: A ? D(A) : D(q).filter((ae) => ae.author === "me" || ae.role === "requester" || ae.requester === !0), collectives: D(be?.collectives || be), coordinatorUnavailable: !!_.coordinator_unavailable, daemonUnavailable: !1 }));
    } catch (_) {
      _.status === 401 ? r((g) => ({ ...g, sessionExpired: !0 })) : r((g) => ({ ...g, daemonUnavailable: !0 }));
    }
  }, [f]);
  ee(() => {
    const _ = () => d(Ie(location.hash));
    if (addEventListener("hashchange", _), e.sessionExpired) return () => removeEventListener("hashchange", _);
    o();
    const g = setInterval(o, kt);
    return () => {
      removeEventListener("hashchange", _), clearInterval(g);
    };
  }, [o, e.sessionExpired]);
  const u = async (_, g) => {
    try {
      const x = await f(_, { method: "POST", body: g ? JSON.stringify(g) : void 0 });
      r((q) => ({ ...q, status: x, message: "" }));
    } catch (x) {
      r((q) => ({ ...q, message: x.message }));
    }
  }, v = async (_) => {
    try {
      const g = await Promise.all(_.files.map(St));
      if (g.reduce((I, U) => I + Math.floor(U.data_base64.length * 3 / 4), 0) > 20 * 1024 * 1024) throw new Error("Attachments are limited to 20 MB. Choose fewer or smaller files.");
      const q = { ..._, attachments: g, network: _.git_url || _.network ? "enabled" : "disabled" };
      delete q.files;
      const R = await f("/submit", { method: "POST", body: JSON.stringify(q) });
      l(Ae), r((I) => ({ ...I, status: R, submission: R.submission, message: "" })), location.hash = "#/requests";
    } catch (g) {
      l((x) => ({ ...x, error: g.message }));
    }
  }, b = z(async (_) => {
    if (_)
      try {
        const g = await f(`/tasks/${encodeURIComponent(Fe(_))}`);
        h(g);
      } catch {
        h(null);
      }
  }, [f]), k = z(async (_) => {
    try {
      const g = await f(`/tasks/${encodeURIComponent(Fe(_))}/log?since=0`);
      m(g);
    } catch {
      m(null);
    }
  }, [f]), y = i.name === "tasks" ? decodeURIComponent(i.parts[0] || "") : "";
  if (ee(() => {
    y && b(y);
  }, [y, b]), e.sessionExpired) return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: "This local link has expired", lead: mt, children: /* @__PURE__ */ n("button", { type: "button", onClick: () => {
    location.href = "waspflow://federation/reconnect";
  }, children: "Reconnect Federation" }) }) });
  if (e.daemonUnavailable) return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(S, { title: "Federation isn’t running right now", lead: "Nothing changed since the last time this page could connect.", children: /* @__PURE__ */ n("button", { type: "button", onClick: () => location.href = "waspflow://federation/reconnect", children: "Reconnect Federation" }) }) });
  if (i.name === "tasks") return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n(V, { route: "requests" }),
    /* @__PURE__ */ n("main", { id: "main-content", children: /* @__PURE__ */ n(Tt, { digest: y, task: s, log: c, loadLog: k, resultHref: y ? `/result/${encodeURIComponent(y)}?token=${encodeURIComponent(t)}` : null }) })
  ] });
  if (i.name === "compose") return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n(V, { route: "requests" }),
    /* @__PURE__ */ n("main", { id: "main-content", children: /* @__PURE__ */ n(Ft, { form: a, setForm: l, submit: v, probeGit: (_) => f("/git/probe", { method: "POST", body: JSON.stringify({ git_url: _ }) }) }) })
  ] });
  if (i.name === "contribute" && ue(e.status).name !== "status") return /* @__PURE__ */ n(Ze, { view: ue(e.status), status: e.status, control: u });
  const p = i.name === "contribute" ? /* @__PURE__ */ n(Ct, { ...e, control: u, goTask: (_) => {
    location.hash = `#/tasks/${encodeURIComponent(_)}`;
  }, beginGitHub: () => u("/identity/signin", { service: "github" }) }) : i.name === "requests" ? /* @__PURE__ */ n(At, { requests: e.requests, submission: e.submission, form: a, setForm: l, submit: v, probeGit: () => {
  }, acknowledge: () => u("/submit/ack") }) : i.name === "activity" ? /* @__PURE__ */ n(Ut, { ledger: e.ledger, requests: e.requests }) : i.name === "settings" ? /* @__PURE__ */ n(Ht, { section: i.parts[0] || "device", identity: e.identity, settings: e.settings, roster: e.roster, collectives: e.collectives, save: (_) => f("/settings", { method: "POST", body: JSON.stringify(_) }).then((g) => r((x) => ({ ...x, settings: g }))), signIn: (_) => u("/identity/signin", { service: _ }), join: (_) => u("/join", { invite: _ }), switchCollective: (_) => u(`/collectives/${encodeURIComponent(_)}/switch`), leaveCollective: (_) => u(`/collectives/${encodeURIComponent(_)}/leave`), status: e.status, message: e.message }) : /* @__PURE__ */ n(Dt, { identity: e.identity });
  return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n(V, { route: i.name }),
    /* @__PURE__ */ n("main", { id: "main-content", children: [
      /* @__PURE__ */ n(W, { children: e.message }),
      p
    ] })
  ] });
}
if (typeof document < "u") {
  const t = document.createElement("style");
  t.textContent = yt, document.head.append(t);
  const e = document.getElementById("app");
  e.textContent = "", ct(/* @__PURE__ */ n(Et, {}), e);
}
export {
  bt as capacityKind,
  ve as collectiveDisplayName,
  vt as lifecycleStage,
  Ke as providerCapacitySubject,
  te as providerDisplayName,
  Ie as routeFromHash,
  Qe as statusRole,
  gt as taskTimeline,
  ue as viewForStatus
};
