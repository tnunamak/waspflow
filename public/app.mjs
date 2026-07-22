var ne, y, Ie, H, ve, Fe, Ue, ae, B, M, He, pe, le, ce, V = {}, K = [], Ze = /acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i, re = Array.isArray;
function F(t, e) {
  for (var r in e) t[r] = e[r];
  return t;
}
function _e(t) {
  t && t.parentNode && t.parentNode.removeChild(t);
}
function et(t, e, r) {
  var a, s, i, d = {};
  for (i in e) i == "key" ? a = e[i] : i == "ref" ? s = e[i] : d[i] = e[i];
  if (arguments.length > 2 && (d.children = arguments.length > 3 ? ne.call(arguments, 2) : r), typeof t == "function" && t.defaultProps != null) for (i in t.defaultProps) d[i] === void 0 && (d[i] = t.defaultProps[i]);
  return G(t, d, a, s, null);
}
function G(t, e, r, a, s) {
  var i = { type: t, props: e, key: r, ref: a, __k: null, __: null, __b: 0, __e: null, __c: null, constructor: void 0, __v: s ?? ++Ie, __i: -1, __u: 0 };
  return s == null && y.vnode != null && y.vnode(i), i;
}
function T(t) {
  return t.children;
}
function Y(t, e) {
  this.props = t, this.context = e;
}
function L(t, e) {
  if (e == null) return t.__ ? L(t.__, t.__i + 1) : null;
  for (var r; e < t.__k.length; e++) if ((r = t.__k[e]) != null && r.__e != null) return r.__e;
  return typeof t.type == "function" ? L(t) : null;
}
function tt(t) {
  if (t.__P && t.__d) {
    var e = t.__v, r = e.__e, a = [], s = [], i = F({}, e);
    i.__v = e.__v + 1, y.vnode && y.vnode(i), he(t.__P, i, e, t.__n, t.__P.namespaceURI, 32 & e.__u ? [r] : null, a, r ?? L(e), !!(32 & e.__u), s), i.__v = e.__v, i.__.__k[i.__i] = i, We(a, i, s), e.__e = e.__ = null, i.__e != r && Ee(i);
  }
}
function Ee(t) {
  if ((t = t.__) != null && t.__c != null) return t.__e = t.__c.base = null, t.__k.some(function(e) {
    if (e != null && e.__e != null) return t.__e = t.__c.base = e.__e;
  }), Ee(t);
}
function be(t) {
  (!t.__d && (t.__d = !0) && H.push(t) && !Q.__r++ || ve != y.debounceRendering) && ((ve = y.debounceRendering) || Fe)(Q);
}
function Q() {
  try {
    for (var t, e = 1; H.length; ) H.length > e && H.sort(Ue), t = H.shift(), e = H.length, tt(t);
  } finally {
    H.length = Q.__r = 0;
  }
}
function De(t, e, r, a, s, i, d, l, p, c, u) {
  var h, o, _, f, b, w, k, v = a && a.__k || K, m = e.length;
  for (p = nt(r, e, v, p, m), h = 0; h < m; h++) (_ = r.__k[h]) != null && (o = _.__i != -1 && v[_.__i] || V, _.__i = h, w = he(t, _, o, s, i, d, l, p, c, u), f = _.__e, _.ref && o.ref != _.ref && (o.ref && me(o.ref, null, _), u.push(_.ref, _.__c || f, _)), b == null && f != null && (b = f), (k = !!(4 & _.__u)) || o.__k === _.__k ? (p = Le(_, p, t, k), k && o.__e && (o.__e = null)) : typeof _.type == "function" && w !== void 0 ? p = w : f && (p = f.nextSibling), _.__u &= -7);
  return r.__e = b, p;
}
function nt(t, e, r, a, s) {
  var i, d, l, p, c, u = r.length, h = u, o = 0;
  for (t.__k = new Array(s), i = 0; i < s; i++) (d = e[i]) != null && typeof d != "boolean" && typeof d != "function" ? (typeof d == "string" || typeof d == "number" || typeof d == "bigint" || d.constructor == String ? d = t.__k[i] = G(null, d, null, null, null) : re(d) ? d = t.__k[i] = G(T, { children: d }, null, null, null) : d.constructor === void 0 && d.__b > 0 ? d = t.__k[i] = G(d.type, d.props, d.key, d.ref ? d.ref : null, d.__v) : t.__k[i] = d, p = i + o, d.__ = t, d.__b = t.__b + 1, l = null, (c = d.__i = rt(d, r, p, h)) != -1 && (h--, (l = r[c]) && (l.__u |= 2)), l == null || l.__v == null ? (c == -1 && (s > u ? o-- : s < u && o++), typeof d.type != "function" && (d.__u |= 4)) : c != p && (c == p - 1 ? o-- : c == p + 1 ? o++ : (c > p ? o-- : o++, d.__u |= 4))) : t.__k[i] = null;
  if (h) for (i = 0; i < u; i++) (l = r[i]) != null && (2 & l.__u) == 0 && (l.__e == a && (a = L(l)), je(l, l));
  return a;
}
function Le(t, e, r, a) {
  var s, i;
  if (typeof t.type == "function") {
    for (s = t.__k, i = 0; s && i < s.length; i++) s[i] && (s[i].__ = t, e = Le(s[i], e, r, a));
    return e;
  }
  t.__e != e && (a && (e && t.type && !e.parentNode && (e = L(t)), r.insertBefore(t.__e, e || null)), e = t.__e);
  do
    e = e && e.nextSibling;
  while (e != null && e.nodeType == 8);
  return e;
}
function rt(t, e, r, a) {
  var s, i, d, l = t.key, p = t.type, c = e[r], u = c != null && (2 & c.__u) == 0;
  if (c === null && l == null || u && l == c.key && p == c.type) return r;
  if (a > (u ? 1 : 0)) {
    for (s = r - 1, i = r + 1; s >= 0 || i < e.length; ) if ((c = e[d = s >= 0 ? s-- : i++]) != null && (2 & c.__u) == 0 && l == c.key && p == c.type) return d;
  }
  return -1;
}
function ye(t, e, r) {
  e[0] == "-" ? t.setProperty(e, r ?? "") : t[e] = r == null ? "" : typeof r != "number" || Ze.test(e) ? r : r + "px";
}
function j(t, e, r, a, s) {
  var i, d;
  e: if (e == "style") if (typeof r == "string") t.style.cssText = r;
  else {
    if (typeof a == "string" && (t.style.cssText = a = ""), a) for (e in a) r && e in r || ye(t.style, e, "");
    if (r) for (e in r) a && r[e] == a[e] || ye(t.style, e, r[e]);
  }
  else if (e[0] == "o" && e[1] == "n") i = e != (e = e.replace(He, "$1")), d = e.toLowerCase(), e = d in t || e == "onFocusOut" || e == "onFocusIn" ? d.slice(2) : e.slice(2), t.l || (t.l = {}), t.l[e + i] = r, r ? a ? r[M] = a[M] : (r[M] = pe, t.addEventListener(e, i ? ce : le, i)) : t.removeEventListener(e, i ? ce : le, i);
  else {
    if (s == "http://www.w3.org/2000/svg") e = e.replace(/xlink(H|:h)/, "h").replace(/sName$/, "s");
    else if (e != "width" && e != "height" && e != "href" && e != "list" && e != "form" && e != "tabIndex" && e != "download" && e != "rowSpan" && e != "colSpan" && e != "role" && e != "popover" && e in t) try {
      t[e] = r ?? "";
      break e;
    } catch {
    }
    typeof r == "function" || (r == null || r === !1 && e[4] != "-" ? t.removeAttribute(e) : t.setAttribute(e, e == "popover" && r == 1 ? "" : r));
  }
}
function ke(t) {
  return function(e) {
    if (this.l) {
      var r = this.l[e.type + t];
      if (e[B] == null) e[B] = pe++;
      else if (e[B] < r[M]) return;
      return r(y.event ? y.event(e) : e);
    }
  };
}
function he(t, e, r, a, s, i, d, l, p, c) {
  var u, h, o, _, f, b, w, k, v, m, g, x, q, P, R, U, $ = e.type;
  if (e.constructor !== void 0) return null;
  128 & r.__u && (p = !!(32 & r.__u), i = [l = e.__e = r.__e]), (u = y.__b) && u(e);
  e: if (typeof $ == "function") {
    h = d.length;
    try {
      if (v = e.props, m = $.prototype && $.prototype.render, g = (u = $.contextType) && a[u.__c], x = u ? g ? g.props.value : u.__ : a, r.__c ? k = (o = e.__c = r.__c).__ = o.__E : (m ? e.__c = o = new $(v, x) : (e.__c = o = new Y(v, x), o.constructor = $, o.render = at), g && g.sub(o), o.state || (o.state = {}), o.__n = a, _ = o.__d = !0, o.__h = [], o._sb = []), m && o.__s == null && (o.__s = o.state), m && $.getDerivedStateFromProps != null && (o.__s == o.state && (o.__s = F({}, o.__s)), F(o.__s, $.getDerivedStateFromProps(v, o.__s))), f = o.props, b = o.state, o.__v = e, _) m && $.getDerivedStateFromProps == null && o.componentWillMount != null && o.componentWillMount(), m && o.componentDidMount != null && o.__h.push(o.componentDidMount);
      else {
        if (m && $.getDerivedStateFromProps == null && v !== f && o.componentWillReceiveProps != null && o.componentWillReceiveProps(v, x), e.__v == r.__v || !o.__e && o.shouldComponentUpdate != null && o.shouldComponentUpdate(v, o.__s, x) === !1) {
          e.__v != r.__v && (o.props = v, o.state = o.__s, o.__d = !1), e.__e = r.__e, e.__k = r.__k, e.__k.some(function(I) {
            I && (I.__ = e);
          }), K.push.apply(o.__h, o._sb), o._sb = [], o.__h.length && d.push(o);
          break e;
        }
        o.componentWillUpdate != null && o.componentWillUpdate(v, o.__s, x), m && o.componentDidUpdate != null && o.__h.push(function() {
          o.componentDidUpdate(f, b, w);
        });
      }
      if (o.context = x, o.props = v, o.__P = t, o.__e = !1, q = y.__r, P = 0, m) o.state = o.__s, o.__d = !1, q && q(e), u = o.render(o.props, o.state, o.context), K.push.apply(o.__h, o._sb), o._sb = [];
      else do
        o.__d = !1, q && q(e), u = o.render(o.props, o.state, o.context), o.state = o.__s;
      while (o.__d && ++P < 25);
      o.state = o.__s, o.getChildContext != null && (a = F(F({}, a), o.getChildContext())), m && !_ && o.getSnapshotBeforeUpdate != null && (w = o.getSnapshotBeforeUpdate(f, b)), R = u != null && u.type === T && u.key == null ? Oe(u.props.children) : u, l = De(t, re(R) ? R : [R], e, r, a, s, i, d, l, p, c), o.base = e.__e, e.__u &= -161, o.__h.length && d.push(o), k && (o.__E = o.__ = null);
    } catch (I) {
      if (d.length = h, e.__v = null, p || i != null) {
        if (I.then) {
          for (e.__u |= p ? 160 : 128; l && l.nodeType == 8 && l.nextSibling; ) l = l.nextSibling;
          i != null && (i[i.indexOf(l)] = null), e.__e = l;
        } else if (i != null) for (U = i.length; U--; ) _e(i[U]);
      } else e.__e = r.__e;
      e.__k == null && (e.__k = r.__k || []), I.then || Me(e), y.__e(I, e, r);
    }
  } else i == null && e.__v == r.__v ? (e.__k = r.__k, e.__e = r.__e) : l = e.__e = it(r.__e, e, r, a, s, i, d, p, c);
  return (u = y.diffed) && u(e), 128 & e.__u ? void 0 : l;
}
function Me(t) {
  t && (t.__c && (t.__c.__e = !0), t.__k && t.__k.some(Me));
}
function We(t, e, r) {
  for (var a = 0; a < r.length; a++) me(r[a], r[++a], r[++a]);
  y.__c && y.__c(e, t), t.some(function(s) {
    try {
      t = s.__h, s.__h = [], t.some(function(i) {
        i.call(s);
      });
    } catch (i) {
      y.__e(i, s.__v);
    }
  });
}
function Oe(t) {
  return typeof t != "object" || t == null || t.__b > 0 ? t : re(t) ? t.map(Oe) : t.constructor !== void 0 ? null : F({}, t);
}
function it(t, e, r, a, s, i, d, l, p) {
  var c, u, h, o, _, f, b, w = r.props || V, k = e.props, v = e.type;
  if (v == "svg" ? s = "http://www.w3.org/2000/svg" : v == "math" ? s = "http://www.w3.org/1998/Math/MathML" : s || (s = "http://www.w3.org/1999/xhtml"), i != null) {
    for (c = 0; c < i.length; c++) if ((_ = i[c]) && "setAttribute" in _ == !!v && (v ? _.localName == v : _.nodeType == 3)) {
      t = _, i[c] = null;
      break;
    }
  }
  if (t == null) {
    if (v == null) return document.createTextNode(k);
    t = document.createElementNS(s, v, k.is && k), l && (y.__m && y.__m(e, i), l = !1), i = null;
  }
  if (v == null) w === k || l && t.data == k || (t.data = k);
  else {
    if (i = v == "textarea" && k.defaultValue != null ? null : i && ne.call(t.childNodes), !l && i != null) for (w = {}, c = 0; c < t.attributes.length; c++) w[(_ = t.attributes[c]).name] = _.value;
    for (c in w) _ = w[c], c == "dangerouslySetInnerHTML" ? h = _ : c == "children" || c in k || c == "value" && "defaultValue" in k || c == "checked" && "defaultChecked" in k || j(t, c, null, _, s);
    for (c in k) _ = k[c], c == "children" ? o = _ : c == "dangerouslySetInnerHTML" ? u = _ : c == "value" ? f = _ : c == "checked" ? b = _ : l && typeof _ != "function" || w[c] === _ || j(t, c, _, w[c], s);
    if (u) l || h && (u.__html == h.__html || u.__html == t.innerHTML) || (t.innerHTML = u.__html), e.__k = [];
    else if (h && (t.innerHTML = ""), De(e.type == "template" ? t.content : t, re(o) ? o : [o], e, r, a, v == "foreignObject" ? "http://www.w3.org/1999/xhtml" : s, i, d, i ? i[0] : r.__k && L(r, 0), l, p), i != null) for (c = i.length; c--; ) _e(i[c]);
    l && v != "textarea" || (c = "value", v == "progress" && f == null ? t.removeAttribute("value") : f != null && (f !== t[c] || v == "progress" && !f || v == "option" && f != w[c]) && j(t, c, f, w[c], s), c = "checked", b != null && b != t[c] && j(t, c, b, w[c], s));
  }
  return t;
}
function me(t, e, r) {
  try {
    if (typeof t == "function") {
      var a = typeof t.__u == "function";
      a && t.__u(), a && e == null || (t.__u = t(e));
    } else t.current = e;
  } catch (s) {
    y.__e(s, r);
  }
}
function je(t, e, r) {
  var a, s;
  if (y.unmount && y.unmount(t), (a = t.ref) && (a.current && a.current != t.__e || me(a, null, e)), (a = t.__c) != null) {
    if (a.componentWillUnmount) try {
      a.componentWillUnmount();
    } catch (i) {
      y.__e(i, e);
    }
    a.base = a.__P = a.__n = null;
  }
  if (a = t.__k) for (s = 0; s < a.length; s++) a[s] && je(a[s], e, r || typeof t.type != "function");
  r || _e(t.__e), t.__c = t.__ = t.__e = void 0;
}
function at(t, e, r) {
  return this.constructor(t, r);
}
function ot(t, e, r) {
  var a, s, i, d;
  e == document && (e = document.documentElement), y.__ && y.__(t, e), s = (a = !1) ? null : e.__k, i = [], d = [], he(e, t = e.__k = et(T, null, [t]), s || V, V, e.namespaceURI, s ? null : e.firstChild ? ne.call(e.childNodes) : null, i, s ? s.__e : e.firstChild, a, d), We(i, t, d), t.props.children = null;
}
ne = K.slice, y = { __e: function(t, e, r, a) {
  for (var s, i, d; e = e.__; ) if ((s = e.__c) && !s.__) try {
    if ((i = s.constructor) && i.getDerivedStateFromError != null && (s.setState(i.getDerivedStateFromError(t)), d = s.__d), s.componentDidCatch != null && (s.componentDidCatch(t, a || {}), d = s.__d), d) return s.__E = s;
  } catch (l) {
    t = l;
  }
  throw t;
} }, Ie = 0, Y.prototype.setState = function(t, e) {
  var r;
  r = this.__s != null && this.__s != this.state ? this.__s : this.__s = F({}, this.state), typeof t == "function" && (t = t(F({}, r), this.props)), t && F(r, t), t != null && this.__v && (e && this._sb.push(e), be(this));
}, Y.prototype.forceUpdate = function(t) {
  this.__v && (this.__e = !0, t && this.__h.push(t), be(this));
}, Y.prototype.render = T, H = [], Fe = typeof Promise == "function" ? Promise.prototype.then.bind(Promise.resolve()) : setTimeout, Ue = function(t, e) {
  return t.__v.__b - e.__v.__b;
}, Q.__r = 0, ae = Math.random().toString(8), B = "__d" + ae, M = "__a" + ae, He = /(PointerCapture)$|Capture$/i, pe = 0, le = ke(!1), ce = ke(!0);
var st = 0;
function n(t, e, r, a, s, i) {
  e || (e = {});
  var d, l, p = e;
  if ("ref" in p) for (l in p = {}, e) l == "ref" ? d = e[l] : p[l] = e[l];
  var c = { type: t, props: p, key: r, ref: d, __k: null, __: null, __b: 0, __e: null, __c: null, constructor: void 0, __v: --st, __i: -1, __u: 0, __source: s, __self: i };
  if (typeof t == "function" && (d = t.defaultProps)) for (l in d) p[l] === void 0 && (p[l] = d[l]);
  return y.vnode && y.vnode(c), c;
}
var W, N, oe, we, X = 0, ze = [], S = y, xe = S.__b, Ne = S.__r, Se = S.diffed, Ce = S.__c, qe = S.unmount, Te = S.__;
function fe(t, e) {
  S.__h && S.__h(N, t, X || e), X = 0;
  var r = N.__H || (N.__H = { __: [], __h: [] });
  return t >= r.__.length && r.__.push({}), r.__[t];
}
function A(t) {
  return X = 1, lt(Ge, t);
}
function lt(t, e, r) {
  var a = fe(W++, 2);
  if (a.t = t, !a.__c && (a.__ = [Ge(void 0, e), function(l) {
    var p = a.__N ? a.__N[0] : a.__[0], c = a.t(p, l);
    p !== c && (a.__N = [c, a.__[1]], a.__c.setState({}));
  }], a.__c = N, !N.__f)) {
    var s = function(l, p, c) {
      if (!a.__c.__H) return !0;
      var u = !1, h = a.__c.props !== l;
      if (a.__c.__H.__.some(function(_) {
        if (_.__N) {
          u = !0;
          var f = _.__[0];
          _.__ = _.__N, _.__N = void 0, f !== _.__[0] && (h = !0);
        }
      }), i) {
        var o = i.call(this, l, p, c);
        return u ? o || h : o;
      }
      return !u || h;
    };
    N.__f = !0;
    var i = N.shouldComponentUpdate, d = N.componentWillUpdate;
    N.componentWillUpdate = function(l, p, c) {
      if (this.__e) {
        var u = i;
        i = void 0, s(l, p, c), i = u;
      }
      d && d.call(this, l, p, c);
    }, N.shouldComponentUpdate = s;
  }
  return a.__N || a.__;
}
function Z(t, e) {
  var r = fe(W++, 3);
  !S.__s && Be(r.__H, e) && (r.__ = t, r.u = e, N.__H.__h.push(r));
}
function ct(t, e) {
  var r = fe(W++, 7);
  return Be(r.__H, e) && (r.__ = t(), r.__H = e, r.__h = t), r.__;
}
function z(t, e) {
  return X = 8, ct(function() {
    return t;
  }, e);
}
function dt() {
  for (var t; t = ze.shift(); ) {
    var e = t.__H;
    if (t.__P && e) try {
      e.__h.some(J), e.__h.some(de), e.__h = [];
    } catch (r) {
      e.__h = [], S.__e(r, t.__v);
    }
  }
}
S.__b = function(t) {
  N = null, xe && xe(t);
}, S.__ = function(t, e) {
  t && e.__k && e.__k.__m && (t.__m = e.__k.__m), Te && Te(t, e);
}, S.__r = function(t) {
  Ne && Ne(t), W = 0;
  var e = (N = t.__c).__H;
  e && (oe === N ? (e.__h = [], N.__h = [], e.__.some(function(r) {
    r.__N && (r.__ = r.__N), r.u = r.__N = void 0;
  })) : (e.__h.some(J), e.__h.some(de), e.__h = [], W = 0)), oe = N;
}, S.diffed = function(t) {
  Se && Se(t);
  var e = t.__c;
  e && e.__H && (e.__H.__h.length && (ze.push(e) !== 1 && we === S.requestAnimationFrame || ((we = S.requestAnimationFrame) || ut)(dt)), e.__H.__.some(function(r) {
    r.u && (r.__H = r.u, r.u = void 0);
  })), oe = N = null;
}, S.__c = function(t, e) {
  e.some(function(r) {
    try {
      r.__h.some(J), r.__h = r.__h.filter(function(a) {
        return !a.__ || de(a);
      });
    } catch (a) {
      e.some(function(s) {
        s.__h && (s.__h = []);
      }), e = [], S.__e(a, r.__v);
    }
  }), Ce && Ce(t, e);
}, S.unmount = function(t) {
  qe && qe(t);
  var e, r = t.__c;
  r && r.__H && (r.__H.__.some(function(a) {
    try {
      J(a);
    } catch (s) {
      e = s;
    }
  }), r.__H = void 0, e && S.__e(e, r.__v));
};
var $e = typeof requestAnimationFrame == "function";
function ut(t) {
  var e, r = function() {
    clearTimeout(a), $e && cancelAnimationFrame(e), setTimeout(t);
  }, a = setTimeout(r, 35);
  $e && (e = requestAnimationFrame(r));
}
function J(t) {
  var e = N, r = t.__c;
  typeof r == "function" && (t.__c = void 0, r()), N = e;
}
function de(t) {
  var e = N;
  t.__c = t.__(), N = e;
}
function Be(t, e) {
  return !t || t.length !== e.length || e.some(function(r, a) {
    return r !== t[a];
  });
}
function Ge(t, e) {
  return typeof e == "function" ? e(t) : e;
}
const pt = "This local link has expired; no task or account change was made.", _t = /* @__PURE__ */ new Set(["contribute", "requests", "compose", "activity", "help", "settings", "tasks"]);
function Pe(t = "") {
  const e = String(t).replace(/^#\/?/, "").split("/").filter(Boolean), r = e[0]?.toLowerCase() || "contribute";
  return _t.has(r) ? { name: r, parts: e.slice(1) } : { name: "contribute", parts: [] };
}
function ue(t) {
  return t ? t.state === "not_joined" ? { name: "join" } : t.state === "pending_approval" ? { name: "pending" } : t.state === "approval_revoked" ? { name: "approval_revoked" } : t.state === "action_needed" ? { name: "action", action: t.action || {} } : t.state === "setup_required" ? { name: "setup", checks: t.action?.checks || [] } : { name: "status", title: { contributing: "Contributing", pausing: "Pausing after this task…", paused: "Paused", idle: "Ready when you are" }[t.state] || "Checking status", control: ["contributing", "pausing"].includes(t.state) ? "pause" : "start" } : { name: "loading" };
}
function ht(t) {
  const e = String(t || "").toLowerCase();
  return ["failed", "error", "returned"].includes(e) ? "failed" : e === "settled" ? "settled" : e === "claimed" ? "claimed" : ["submitted", "evaluating", "running"].includes(e) ? "running" : "queued";
}
function mt(t = {}) {
  const e = ht(t?.status), r = e === "failed" ? ["queued", "claimed", "running", "failed"] : ["queued", "claimed", "running", "settled"];
  return r.map((a, s) => ({ name: a, complete: s < r.indexOf(e), current: a === e, timestamp: t?.[`${a}_at`] || (a === "queued" ? t?.published_at : null) }));
}
function ee(t) {
  const e = { anthropic: "Anthropic (Claude)", claude: "Anthropic (Claude)", openai: "OpenAI", github: "GitHub", google: "Google" }, r = String(t || "provider").trim();
  return e[r.toLowerCase()] || r;
}
function ft(t = {}) {
  return t.capacity_kind || t.capacity?.kind || t.kind || t.auth_kind || t.capacity_type || "not captured";
}
function Ye(t) {
  const e = (t?.accounts || t?.providers || [])[0];
  if (!e) return "your configured provider account";
  const r = ee(e.provider || e.service || e.name), a = String(ft(e)).toLowerCase();
  return a.includes("local") ? `the ${r} local model` : a.includes("api") ? `your ${r} API key` : `your ${r} account`;
}
function Je(t) {
  const e = String(t || "").toLowerCase();
  return ["contributing", "claimed", "running", "submitted", "evaluating"].includes(e) ? "active" : ["paused", "action_needed", "pending_approval", "pausing"].includes(e) ? "attention" : ["failed", "error", "approval_revoked", "unreachable", "session_expired"].includes(e) ? "problem" : "ready";
}
function Ve(t) {
  return String(t || "queued").replace(/[_-]+/g, " ").replace(/\b\w/g, (e) => e.toUpperCase());
}
const gt = ':root{--ink:#17212b;--muted:#5d6b76;--line:#d9e0e5;--surface:#fff;--page:#f7f9fa;--space-1:4px;--space-2:8px;--space-3:12px;--space-4:16px;--space-5:24px;--space-6:32px;--active:#19597e;--active-bg:#e6f0f7;--ready:#176a46;--ready-bg:#e1f3e8;--attention:#b37d17;--attention-bg:#fff4dc;--problem:#8b3513;--problem-bg:#fff0eb;font-family:Inter,ui-sans-serif,system-ui,sans-serif;color:var(--ink);background:var(--page)}*{box-sizing:border-box}body{margin:0;background:var(--page)}button,input,textarea{font:inherit}button,.button-link{border:0;border-radius:8px;padding:10px 14px;background:#19597e;color:#fff;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;gap:6px}button.secondary,.button-link.secondary{background:#fff;color:#19597e;border:1px solid #9fb4c2}button:disabled{opacity:.55;cursor:not-allowed}a{color:#19597e}#app>main,#main-content{width:min(1040px,calc(100% - 32px));margin:var(--space-6) auto}.app-header{min-height:64px;padding:0 max(16px,calc((100vw - 1040px)/2));display:flex;align-items:center;gap:var(--space-5);background:#fff;border-bottom:1px solid var(--line)}.brand{display:flex;gap:var(--space-2);color:var(--ink);text-decoration:none;font-weight:760;white-space:nowrap}.brand-mark{width:24px;height:24px;display:grid;place-items:center;border-radius:7px;color:#fff;background:#19597e}.primary-nav{margin-left:auto;display:flex;gap:var(--space-4)}.primary-nav a{padding:22px 0 18px;color:var(--muted);text-decoration:none;border-bottom:3px solid transparent}.primary-nav a[aria-current=page]{color:var(--ink);border-color:#19597e;font-weight:700}.gear{font-size:20px;color:var(--ink);text-decoration:none}.skip-link{position:absolute;left:-999px}.skip-link:focus{left:8px;top:8px;z-index:3;background:#fff;padding:8px}.view-stack{display:grid;gap:var(--space-4)}.panel{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:var(--space-5)}.panel-heading{margin-bottom:var(--space-4)}.panel h2{font-size:1.125rem;margin:0 0 var(--space-1)}.panel h3{margin-top:var(--space-5)}.muted,.detail,.quiet-note,.field-help{color:var(--muted)}.contribution-state{display:flex;gap:var(--space-3);align-items:flex-start}.status-label{font-size:1.5rem;line-height:1.2;margin:0;font-weight:760}.status-dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--ready)}.status-dot.large{margin-top:8px;width:14px;height:14px}.status-dot[data-status=active]{background:var(--active)}.status-dot[data-status=ready]{background:var(--ready)}.status-dot[data-status=attention]{background:var(--attention)}.status-dot[data-status=problem]{background:var(--problem)}.collective-line{font-weight:650}.actions{display:flex;flex-wrap:wrap;gap:var(--space-2);margin:var(--space-4) 0}.guard{padding:var(--space-3);background:var(--ready-bg);color:var(--ready);border-radius:8px}.notice{margin:0 0 var(--space-4);padding:var(--space-3);border:1px solid var(--problem);background:var(--problem-bg);color:var(--problem);border-radius:8px}.notice[data-status=attention]{border-color:var(--attention);background:var(--attention-bg);color:#77530d}.empty-state{padding:var(--space-4);background:#fff;border:1px dashed #afbec8;border-radius:8px}.empty-state strong{display:block}.task-list,.request-list,.history-list,.roster,.file-list{list-style:none;padding:0;margin:var(--space-4) 0 0}.task-row,.request-list li,.history-list li,.roster li{padding:var(--space-3) 0;border-top:1px solid var(--line)}.task-row,.request-select,.history-list li,.roster li{display:flex;justify-content:space-between;gap:var(--space-4);align-items:flex-start}.request-select{color:inherit;text-decoration:none;display:flex;width:100%}.request-select small{display:block;color:var(--muted);margin-top:var(--space-1)}.receipt-chips{display:flex;gap:var(--space-2);flex-wrap:wrap}.receipt-chip,.role-chip{padding:3px 7px;border-radius:999px;background:#edf1f3;font-size:.85rem}.consent-card{border-color:#b2cad8;box-shadow:0 4px 14px #17324f12}.full-prompt{white-space:pre-wrap;line-height:1.5}.chip{display:inline-flex;align-items:center;gap:6px;width:fit-content;padding:3px 8px;border-radius:999px;font-size:.85rem;font-weight:650;color:var(--ready);background:var(--ready-bg)}.chip[data-status=active]{color:var(--active);background:var(--active-bg)}.chip[data-status=attention]{color:#77530d;background:var(--attention-bg)}.chip[data-status=problem]{color:var(--problem);background:var(--problem-bg)}.timeline{padding:0;list-style:none;display:flex;gap:0;overflow:auto}.timeline li{min-width:130px;position:relative;padding:24px 12px 0 0;color:var(--muted)}.timeline li:before{content:"";position:absolute;top:7px;left:0;width:100%;height:2px;background:var(--line)}.timeline li:first-child:before{width:100%}.timeline li:after{content:"";position:absolute;top:1px;left:0;width:14px;height:14px;border-radius:50%;background:#fff;border:2px solid #a6b3bb}.timeline li.complete:after,.timeline li.current:after{border-color:var(--active);background:var(--active)}.timeline li strong,.timeline li span{display:block}.timeline li span{font-size:.85rem;margin-top:var(--space-1)}.execution-log{white-space:pre-wrap;overflow:auto;padding:var(--space-3);background:#17212b;color:#e9f0f4;border-radius:8px;max-height:400px}.receipt{display:grid;grid-template-columns:140px 1fr;gap:var(--space-2) var(--space-3)}.receipt dt{font-weight:700}.receipt dd{margin:0}.back-link{display:block;margin-bottom:calc(var(--space-4) * -1)}.segmented{display:flex;gap:var(--space-1);padding:var(--space-1);width:fit-content;border-radius:8px;background:#edf1f3}.segmented button{color:var(--muted);background:transparent;padding:7px 10px}.segmented button[aria-selected=true]{background:#fff;color:var(--ink);box-shadow:0 1px 2px #0002}.history-list li span,.roster li small{color:var(--muted)}.provider-card{padding:var(--space-3);border:1px solid var(--line);border-radius:8px;margin-top:var(--space-2)}.day-chips{display:flex;gap:var(--space-2);flex-wrap:wrap;margin:var(--space-2) 0}.day-chips button{background:#fff;color:var(--ink);border:1px solid var(--line);padding:8px 10px}.day-chips button.selected{background:var(--active-bg);color:var(--active);border-color:var(--active)}form{display:grid;gap:var(--space-2)}label{font-weight:650;display:grid;gap:var(--space-1)}input,textarea{width:100%;padding:9px;border:1px solid #aebdc7;border-radius:7px;background:#fff}input[type=checkbox]{width:auto;margin-right:var(--space-1)}textarea{min-height:120px;resize:vertical}.form-feedback{min-height:1.5rem;color:var(--problem)}.one-time-code-wrap{display:inline-flex;gap:var(--space-2);align-items:center}.one-time-code{padding:4px 6px;background:#eef1f3;border-radius:4px;cursor:pointer}.full-bleed{display:grid;place-items:center;min-height:100vh;margin:0!important;width:100%!important}.full-bleed .panel{max-width:600px;width:calc(100% - 32px)}.stop-now{margin:var(--space-3) 0}@media(max-width:700px){.app-header{gap:var(--space-2);flex-wrap:wrap;padding:var(--space-2) var(--space-4)}.primary-nav{margin-left:0;order:3;width:100%;gap:var(--space-3);overflow:auto}.primary-nav a{padding:var(--space-2) 0}.brand{font-size:.95rem}#app>main,#main-content{width:min(100% - 24px,1040px);margin:var(--space-4) auto}.panel{padding:var(--space-4)}.timeline li{min-width:108px}.task-row,.history-list li{flex-direction:column;gap:var(--space-2)}.receipt{grid-template-columns:1fr;gap:var(--space-1)}.receipt dd{margin-bottom:var(--space-2)}}', vt = 1500, Re = { display_id: "", prompt: "", source: "", git_url: "", git_ref: "", git_probe: "", github_access_required: !1, files: [], network: !1, error: "" }, bt = [["contribute", "Contribute"], ["requests", "Requests"], ["activity", "Activity"], ["help", "Help"]], D = (t) => Array.isArray(t) ? t : [], ge = (t) => {
  const e = new Date(t || "");
  return Number.isFinite(e.getTime()) ? new Intl.DateTimeFormat(void 0, { dateStyle: "medium", timeStyle: "short" }).format(e) : "Not captured";
}, yt = (t) => typeof t == "number" ? `${Math.max(0, Math.round(t / 1e3))} seconds` : t || "Not captured — the harness did not report a duration.", kt = (t) => String(t || "").split(/\r?\n/).map((e) => e.trim()).find(Boolean) || "Prompt preview is not available.", Ae = (t) => String(t || "").replace(/^sha256:/, ""), wt = async (t) => {
  const e = new Uint8Array(await t.arrayBuffer());
  let r = "";
  for (let a = 0; a < e.length; a += 32768) r += String.fromCharCode(...e.subarray(a, a + 32768));
  return { name: t.name, relative_path: t.webkitRelativePath || t.name, data_base64: btoa(r) };
};
function C({ title: t, lead: e, children: r, className: a = "" }) {
  return /* @__PURE__ */ n("section", { className: `panel ${a}`, children: [
    /* @__PURE__ */ n("div", { className: "panel-heading", children: [
      t && /* @__PURE__ */ n("h2", { children: t }),
      e && /* @__PURE__ */ n("p", { className: "muted", children: e })
    ] }),
    r
  ] });
}
function te({ value: t }) {
  const e = Je(t);
  return /* @__PURE__ */ n("span", { className: "chip", "data-status": e, children: [
    /* @__PURE__ */ n("span", { className: "status-dot", "data-status": e }),
    Ve(t)
  ] });
}
function O({ status: t = "problem", children: e }) {
  return e ? /* @__PURE__ */ n("div", { className: "notice", "data-status": t, role: "status", children: e }) : null;
}
function xt({ value: t }) {
  const e = () => {
    navigator.clipboard?.writeText(t);
  };
  return /* @__PURE__ */ n("span", { className: "one-time-code-wrap", children: [
    /* @__PURE__ */ n("code", { className: "one-time-code", tabIndex: "0", onClick: e, children: t }),
    /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: e, children: "Copy code" })
  ] });
}
function se({ route: t }) {
  return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n("a", { className: "skip-link", href: "#main-content", children: "Skip to content" }),
    /* @__PURE__ */ n("header", { className: "app-header", children: [
      /* @__PURE__ */ n("a", { className: "brand", href: "#/contribute", children: [
        /* @__PURE__ */ n("span", { className: "brand-mark", children: "W" }),
        /* @__PURE__ */ n("span", { children: "Waspflow Federation" })
      ] }),
      /* @__PURE__ */ n("nav", { className: "primary-nav", "aria-label": "Federation sections", children: bt.map(([e, r]) => /* @__PURE__ */ n("a", { href: `#/${e}`, "aria-current": t === e ? "page" : void 0, children: r })) }),
      /* @__PURE__ */ n("a", { className: "gear", href: "#/settings/device", "aria-label": "Settings", title: "Settings", children: "⚙" })
    ] })
  ] });
}
function Ke({ view: t, status: e, control: r }) {
  const [a, s] = A("");
  if (t.name === "loading") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: "Checking Federation status", lead: "Loading your local Federation state before showing the next step." }) });
  if (t.name === "join") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: "Join your collective", lead: "Paste the link or code your collective owner sent you.", children: [
    /* @__PURE__ */ n("label", { htmlFor: "invite", children: "Invite" }),
    /* @__PURE__ */ n("textarea", { id: "invite", value: a, onInput: (l) => s(l.currentTarget.value), placeholder: "Paste an invite link, join command, or token" }),
    /* @__PURE__ */ n("div", { className: "actions", children: /* @__PURE__ */ n("button", { type: "button", onClick: () => r("/join", { invite: a }), children: "Join" }) }),
    /* @__PURE__ */ n("p", { className: "quiet-note", children: "Your machine will not do anything until the collective owner approves you." })
  ] }) });
  if (t.name === "pending") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: "Pending approval", lead: "Your collective owner needs to approve this computer.", children: [
    /* @__PURE__ */ n("p", { children: e?.collective_name ? `You’re joining ${e.collective_name}.` : "No task can start until approval is granted." }),
    /* @__PURE__ */ n("p", { className: "muted", children: "Not sure this is right? Ask whoever invited you." }),
    /* @__PURE__ */ n(O, { status: "attention", children: e?.coordinator_unavailable ? "Your collective is unreachable right now. Approval will refresh when it returns." : e?.detail })
  ] }) });
  if (t.name === "approval_revoked") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: "Approval was revoked", lead: "No new work will start on this machine.", children: [
    /* @__PURE__ */ n("p", { children: e?.detail || "Ask your collective owner to approve this machine again." }),
    /* @__PURE__ */ n("button", { type: "button", onClick: () => location.reload(), children: "Refresh approval" })
  ] }) });
  if (t.name === "setup") return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: "Your sandbox needs attention", lead: "Complete this once, then come back to contribute.", children: [
    /* @__PURE__ */ n("ol", { children: (t.checks.length ? t.checks : [{ detail: "Open Federation again after Docker Sandbox setup is complete." }]).map((l) => /* @__PURE__ */ n("li", { children: [
      l.detail || l.name,
      " ",
      l.fix || ""
    ] })) }),
    /* @__PURE__ */ n("p", { children: e?.detail })
  ] }) });
  const i = t.action || {}, d = ee(i.service || "your provider");
  return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: i.kind === "awaiting_browser" ? `Sign in to ${d}` : "Sign-in needs attention", lead: i.kind === "awaiting_browser" ? "Finish this one browser step, then return here." : `${d} sign-in isn't available from this screen yet.`, children: [
    /* @__PURE__ */ n("p", { children: i.kind === "awaiting_browser" ? "No task will resume automatically. Federation will show the result here after you finish." : e?.detail || "Contact your collective owner, then try again later." }),
    i.kind === "awaiting_browser" && /* @__PURE__ */ n("button", { type: "button", onClick: () => window.open(i.url, "_blank", "noopener"), children: [
      "Sign in to ",
      d
    ] }),
    i.code && /* @__PURE__ */ n("p", { children: [
      "Confirmation code: ",
      /* @__PURE__ */ n(xt, { value: i.code })
    ] })
  ] }) });
}
function E({ children: t }) {
  return /* @__PURE__ */ n("main", { id: "main-content", className: "full-bleed", children: t });
}
function Nt({ status: t, settings: e, tasks: r, identity: a, coordinatorUnavailable: s, control: i, goTask: d, beginGitHub: l }) {
  const p = ue(t), [c, u] = A(null), [h, o] = A(!1);
  if (p.name !== "status") return /* @__PURE__ */ n(Ke, { view: p, status: t, control: i });
  const _ = p.control === "pause", f = t?.contribution || {}, b = c || r[0];
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n(C, { title: "Your contribution", children: [
      /* @__PURE__ */ n("div", { className: "contribution-state", children: [
        /* @__PURE__ */ n("span", { className: "status-dot large", "data-status": Je(t?.state) }),
        /* @__PURE__ */ n("div", { children: [
          /* @__PURE__ */ n("p", { className: "status-label", children: p.title }),
          /* @__PURE__ */ n("p", { className: "detail", children: _ && f.display_id ? `Working on “${f.display_id}”${f.requester || f.author ? ` for ${f.requester || f.author}` : ""}` : t?.detail || "Nothing will run until you approve a task." })
        ] })
      ] }),
      e?.collective_name || t?.collective_name ? /* @__PURE__ */ n("p", { className: "collective-line", children: [
        "Collective: ",
        e?.collective_name || t?.collective_name
      ] }) : null,
      /* @__PURE__ */ n(O, { status: "problem", children: s ? "Your collective is unreachable right now. Nothing changed on this computer." : null }),
      /* @__PURE__ */ n("div", { className: "actions", children: [
        _ ? /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => i("/contribute/pause"), children: "Pause after this task" }) : null,
        _ && f.task_digest ? /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => d(f.task_digest), children: "Watch what it’s doing →" }) : null
      ] }),
      _ && /* @__PURE__ */ n("div", { className: "stop-now", children: h ? /* @__PURE__ */ n(T, { children: [
        /* @__PURE__ */ n("p", { children: "Stop now abandons the current task. Waspflow records it as returned." }),
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => i("/contribute/stop", { confirm: !0 }), children: "Stop now" }),
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => o(!1), children: "Keep working" })
      ] }) : /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => o(!0), children: "Stop now" }) }),
      /* @__PURE__ */ n("div", { className: "guard", children: /* @__PURE__ */ n("strong", { children: "You approve every task before it starts. Nothing runs while paused." }) })
    ] }),
    !_ && !s && (b ? /* @__PURE__ */ n(C, { title: c ? "Review this task" : "Tasks ready for review", lead: c ? "Read the full request before deciding whether to use your account." : "Nothing runs without your say.", className: c ? "consent-card" : "", children: c ? /* @__PURE__ */ n(T, { children: [
      /* @__PURE__ */ n("p", { children: [
        /* @__PURE__ */ n("strong", { children: b.display_id || "Untitled task" }),
        " from ",
        b.author || "Unknown requester"
      ] }),
      /* @__PURE__ */ n("p", { className: "full-prompt", children: b.prompt || b.prompt_preview || "Prompt was not included." }),
      /* @__PURE__ */ n("p", { children: [
        "Will use: ",
        Ye(a),
        " · isolated sandbox",
        b.network === "enabled" || b.git_source ? " · internet access" : ""
      ] }),
      /* @__PURE__ */ n("p", { children: "Estimated: a few minutes, based on similar tasks." }),
      /* @__PURE__ */ n(Qe, { task: b }),
      /* @__PURE__ */ n("div", { className: "actions", children: [
        b.git_source?.authentication_required && !D(a?.providers).some((w) => w.service === "github" && w.authed) ? /* @__PURE__ */ n("button", { type: "button", onClick: l, children: "Set up GitHub access" }) : /* @__PURE__ */ n("button", { type: "button", onClick: () => i("/contribute/start", { task_digest: b.task_digest }), children: "Accept and run" }),
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => u(null), children: "Skip this one" })
      ] })
    ] }) : /* @__PURE__ */ n(T, { children: [
      /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => u(b), children: "Review the next task" }),
      /* @__PURE__ */ n(St, { tasks: r, onSelect: u })
    ] }) }) : /* @__PURE__ */ n("div", { className: "empty-state", children: [
      /* @__PURE__ */ n("strong", { children: "No tasks are waiting." }),
      /* @__PURE__ */ n("p", { children: "You’ll see a review card here the moment one is ready — nothing runs without your say." })
    ] }))
  ] });
}
function Qe({ task: t }) {
  return /* @__PURE__ */ n("div", { className: "receipt-chips", children: [
    (t?.github_access_required || t?.git_source?.authentication_required) && /* @__PURE__ */ n("span", { className: "receipt-chip", children: "Needs: GitHub" }),
    (t?.network === "enabled" || t?.git_source) && /* @__PURE__ */ n("span", { className: "receipt-chip", children: "Needs: internet" })
  ] });
}
function St({ tasks: t, onSelect: e }) {
  return /* @__PURE__ */ n("ul", { className: "task-list", children: t.map((r) => /* @__PURE__ */ n("li", { className: "task-row", children: [
    /* @__PURE__ */ n("div", { children: [
      /* @__PURE__ */ n("strong", { children: r.display_id || "Untitled task" }),
      /* @__PURE__ */ n("p", { className: "muted", children: r.author ? `from ${r.author}` : "Requester not captured yet" }),
      /* @__PURE__ */ n("p", { children: kt(r.prompt_preview || r.prompt) }),
      /* @__PURE__ */ n(Qe, { task: r })
    ] }),
    /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => e(r), children: "Review" })
  ] })) });
}
function Ct({ digest: t, task: e, log: r, loadLog: a, resultHref: s }) {
  const i = String(e?.status || "").toLowerCase() === "settled";
  return Z(() => {
    t && a(t);
  }, [t]), /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n("a", { className: "back-link", href: "#/requests", children: "← Requests" }),
    /* @__PURE__ */ n(C, { title: e?.display_id || "Task", lead: /* @__PURE__ */ n(te, { value: e?.status || "queued" }), children: [
      /* @__PURE__ */ n(qt, { task: e }),
      /* @__PURE__ */ n("h3", { children: "Live transcript" }),
      /* @__PURE__ */ n(Tt, { log: r }),
      /* @__PURE__ */ n("h3", { children: "What was asked" }),
      /* @__PURE__ */ n("p", { className: "full-prompt", children: e?.prompt || e?.prompt_preview || "Task details are still loading." }),
      i && /* @__PURE__ */ n("details", { children: [
        /* @__PURE__ */ n("summary", { children: "Result and receipt" }),
        /* @__PURE__ */ n($t, { task: e }),
        s && /* @__PURE__ */ n("a", { className: "button-link", href: s, children: "Download result" })
      ] })
    ] })
  ] });
}
function qt({ task: t }) {
  return /* @__PURE__ */ n("ol", { className: "timeline", children: mt(t).map((e) => /* @__PURE__ */ n("li", { className: e.complete ? "complete" : e.current ? "current" : "", children: [
    /* @__PURE__ */ n("strong", { children: Ve(e.name) }),
    /* @__PURE__ */ n("span", { children: e.timestamp ? ge(e.timestamp) : e.current ? "In progress" : "Waiting" })
  ] })) });
}
function Tt({ log: t }) {
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
function $t({ task: t }) {
  const e = t?.execution_metadata || t?.receipt || {}, r = [["Harness", e.harness_id], ["Model", t?.model || e.model], ["Tokens", t?.tokens || e.tokens || Pt(e)], ["Duration", yt(t?.duration || e.duration || e.duration_ms)], ["Sandbox", t?.sandbox_id || e.sandbox_id]];
  return /* @__PURE__ */ n("dl", { className: "receipt", children: r.map(([a, s]) => /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n("dt", { children: a }),
    /* @__PURE__ */ n("dd", { children: s || "Not captured — this task ran before receipts were enabled." })
  ] })) });
}
function Pt(t) {
  const e = t.usage || t;
  return e.input_tokens !== void 0 || e.output_tokens !== void 0 ? `${e.input_tokens || e.tokens_in || 0} tokens in · ${e.output_tokens || e.tokens_out || 0} tokens out` : "";
}
function Rt({ requests: t, submission: e, form: r, setForm: a, submit: s, probeGit: i, acknowledge: d }) {
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    e && /* @__PURE__ */ n(C, { title: "Submission status", children: [
      /* @__PURE__ */ n(te, { value: e.status || "pending" }),
      /* @__PURE__ */ n("p", { children: e.detail || "Your request is being published." }),
      e.error && /* @__PURE__ */ n(O, { children: e.error }),
      /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: d, children: "Acknowledge" })
    ] }),
    /* @__PURE__ */ n(C, { title: "Requests", lead: "Submitted tasks and their live progress.", children: [
      /* @__PURE__ */ n("div", { className: "actions", children: /* @__PURE__ */ n("a", { className: "button-link", href: "#/compose", children: "+ New request" }) }),
      t.length ? /* @__PURE__ */ n("ul", { className: "request-list", children: t.map((l) => /* @__PURE__ */ n("li", { children: /* @__PURE__ */ n("a", { className: "request-select", href: `#/tasks/${encodeURIComponent(l.task_digest)}`, children: [
        /* @__PURE__ */ n("span", { children: [
          /* @__PURE__ */ n("strong", { children: l.display_id || "Untitled task" }),
          /* @__PURE__ */ n("small", { children: l.published_at ? ge(l.published_at) : "Recently submitted" })
        ] }),
        /* @__PURE__ */ n(te, { value: l.status })
      ] }) })) }) : /* @__PURE__ */ n("div", { className: "empty-state", children: [
        /* @__PURE__ */ n("strong", { children: "No requests yet." }),
        /* @__PURE__ */ n("p", { children: "Submitted tasks and their live progress will show up here." })
      ] })
    ] })
  ] });
}
function At({ form: t, setForm: e, submit: r, probeGit: a }) {
  const s = (l) => (p) => e((c) => ({ ...c, [l]: p.currentTarget.type === "checkbox" ? p.currentTarget.checked : p.currentTarget.value, error: "" })), i = (l) => e((p) => ({ ...p, files: [...p.files, ...Array.from(l.currentTarget.files || [])], error: "" }));
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n("a", { className: "back-link", href: "#/requests", children: "← Requests" }),
    /* @__PURE__ */ n(C, { title: "New request", lead: "Describe the outcome for your collective.", children: /* @__PURE__ */ n("form", { onSubmit: (l) => {
      l.preventDefault(), r(t);
    }, children: [
      /* @__PURE__ */ n("label", { htmlFor: "task-name", children: "Task name" }),
      /* @__PURE__ */ n("input", { id: "task-name", value: t.display_id, onInput: s("display_id"), required: !0 }),
      /* @__PURE__ */ n("label", { htmlFor: "task-prompt", children: "What should this task accomplish?" }),
      /* @__PURE__ */ n("textarea", { id: "task-prompt", value: t.prompt, onInput: s("prompt"), required: !0 }),
      /* @__PURE__ */ n("label", { htmlFor: "task-files", children: [
        "Add files (optional)",
        /* @__PURE__ */ n("input", { id: "task-files", type: "file", multiple: !0, onChange: i })
      ] }),
      /* @__PURE__ */ n("label", { htmlFor: "task-folder-upload", children: [
        "Add folder (optional)",
        /* @__PURE__ */ n("input", { id: "task-folder-upload", type: "file", webkitdirectory: "", onChange: i })
      ] }),
      t.files.length > 0 && /* @__PURE__ */ n("ul", { className: "file-list", children: t.files.map((l, p) => /* @__PURE__ */ n("li", { children: [
        l.webkitRelativePath || l.name,
        " · ",
        l.size,
        " bytes ",
        /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => e((c) => ({ ...c, files: c.files.filter((u, h) => h !== p) })), children: "Remove" })
      ] })) }),
      /* @__PURE__ */ n("details", { children: [
        /* @__PURE__ */ n("summary", { children: "Advanced" }),
        /* @__PURE__ */ n("label", { htmlFor: "task-folder", children: "Use a folder already on this computer (where Waspflow runs)" }),
        /* @__PURE__ */ n("input", { id: "task-folder", value: t.source, onInput: s("source") }),
        /* @__PURE__ */ n("label", { htmlFor: "task-git-url", children: "Git repository (optional)" }),
        /* @__PURE__ */ n("input", { id: "task-git-url", value: t.git_url, onInput: s("git_url"), onBlur: () => t.git_url && a(t.git_url) }),
        /* @__PURE__ */ n("label", { htmlFor: "task-git-ref", children: "Branch or ref (optional)" }),
        /* @__PURE__ */ n("input", { id: "task-git-ref", value: t.git_ref, onInput: s("git_ref") }),
        /* @__PURE__ */ n("label", { children: [
          /* @__PURE__ */ n("input", { type: "checkbox", checked: t.github_access_required, onChange: s("github_access_required") }),
          " Task needs GitHub access"
        ] }),
        /* @__PURE__ */ n("label", { children: [
          /* @__PURE__ */ n("input", { type: "checkbox", checked: t.network, onChange: s("network"), disabled: !!t.git_url }),
          " Allow internet access"
        ] }),
        /* @__PURE__ */ n("p", { className: "field-help", children: t.git_url ? "This only lets the task read the repository it names — never your other GitHub activity." : "When on, tasks can fetch public resources." })
      ] }),
      /* @__PURE__ */ n("p", { className: "form-feedback", role: "alert", children: t.error }),
      /* @__PURE__ */ n("button", { type: "submit", children: "Submit task" })
    ] }) })
  ] });
}
function It({ ledger: t, requests: e }) {
  const [r, a] = A("did"), s = r === "did" ? t.filter((i) => i.role !== "requester" && i.author !== "me") : e;
  return /* @__PURE__ */ n("div", { className: "view-stack", children: /* @__PURE__ */ n(C, { title: "Activity", children: [
    /* @__PURE__ */ n("div", { className: "segmented", role: "tablist", children: [
      /* @__PURE__ */ n("button", { type: "button", "aria-selected": r === "did", onClick: () => a("did"), children: "What I did" }),
      /* @__PURE__ */ n("button", { type: "button", "aria-selected": r === "asked", onClick: () => a("asked"), children: "What I asked for" })
    ] }),
    s.length ? /* @__PURE__ */ n("ul", { className: "history-list", children: s.map((i) => /* @__PURE__ */ n("li", { children: [
      /* @__PURE__ */ n("strong", { children: i.display_id || "Untitled task" }),
      /* @__PURE__ */ n("span", { children: r === "did" ? `Completed for ${i.requester || i.author || "your collective"}` : "Requested by you" }),
      /* @__PURE__ */ n(te, { value: i.status })
    ] })) }) : /* @__PURE__ */ n("div", { className: "empty-state", children: [
      /* @__PURE__ */ n("strong", { children: r === "did" ? "Nothing completed yet." : "No requests yet." }),
      /* @__PURE__ */ n("p", { children: r === "did" ? "Every task you run will get a full private receipt here." : "Submitted tasks and their live progress will show up here." })
    ] })
  ] }) });
}
function Ft({ section: t, identity: e, settings: r, roster: a, save: s, signIn: i, status: d }) {
  const [l, p] = A(r?.schedule || { enabled: !1, start: "", end: "", days: "", timezone: Intl.DateTimeFormat().resolvedOptions().timeZone });
  if (Z(() => {
    r?.schedule && p(r.schedule);
  }, [r]), t === "collective") return /* @__PURE__ */ n("div", { className: "view-stack", children: /* @__PURE__ */ n(C, { title: "Collective", lead: "Read-only awareness for this shared collective.", children: [
    /* @__PURE__ */ n("p", { children: r?.collective_name || e?.collective_name || "Collective name not captured yet." }),
    /* @__PURE__ */ n("h3", { children: "Members" }),
    /* @__PURE__ */ n("ul", { className: "roster", children: a.map((u) => /* @__PURE__ */ n("li", { children: [
      /* @__PURE__ */ n("strong", { children: u.display_name || u.name || u.key_id }),
      /* @__PURE__ */ n("span", { className: "role-chip", children: u.role || "Member" }),
      /* @__PURE__ */ n("small", { children: u.joined_at ? `Joined ${ge(u.joined_at)}` : "Join date not captured" })
    ] })) }),
    /* @__PURE__ */ n("details", { children: [
      /* @__PURE__ */ n("summary", { children: "Technical details" }),
      /* @__PURE__ */ n("p", { children: [
        "Connection address: ",
        e?.coordinator_url || "Not captured"
      ] })
    ] }),
    /* @__PURE__ */ n("p", { className: "muted", children: "Membership changes happen on the operator’s machine today." })
  ] }) });
  const c = D(e?.accounts || e?.providers);
  return /* @__PURE__ */ n("div", { className: "view-stack", children: /* @__PURE__ */ n(C, { title: "Device & accounts", lead: "Settings for this computer only.", children: [
    /* @__PURE__ */ n("p", { children: [
      "Your machine’s ID: ",
      e?.key_id || "Not detected yet",
      " — this is how the collective recognizes this computer, not a person."
    ] }),
    /* @__PURE__ */ n("h3", { children: "Schedule" }),
    /* @__PURE__ */ n("label", { children: [
      /* @__PURE__ */ n("input", { type: "checkbox", checked: l.enabled, onChange: (u) => p({ ...l, enabled: u.currentTarget.checked }) }),
      " Contribute on a schedule"
    ] }),
    /* @__PURE__ */ n("div", { className: "day-chips", children: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((u) => /* @__PURE__ */ n("button", { type: "button", className: String(l.days || "").split(",").includes(u) ? "selected" : "", onClick: () => {
      const h = new Set(String(l.days || "").split(",").filter(Boolean));
      h.has(u) ? h.delete(u) : h.add(u), p({ ...l, days: [...h].join(",") });
    }, children: u })) }),
    /* @__PURE__ */ n("label", { children: [
      "Start",
      /* @__PURE__ */ n("input", { value: l.start || "", onInput: (u) => p({ ...l, start: u.currentTarget.value }) })
    ] }),
    /* @__PURE__ */ n("label", { children: [
      "End",
      /* @__PURE__ */ n("input", { value: l.end || "", onInput: (u) => p({ ...l, end: u.currentTarget.value }) })
    ] }),
    /* @__PURE__ */ n("p", { className: "muted", children: [
      "Schedule times are in ",
      l.timezone || "your local timezone",
      "."
    ] }),
    /* @__PURE__ */ n("button", { type: "button", onClick: () => s({ ...r, schedule: l }), children: "Save device settings" }),
    /* @__PURE__ */ n("h3", { children: "Accounts" }),
    c.map((u) => /* @__PURE__ */ n("div", { className: "provider-card", children: [
      /* @__PURE__ */ n("strong", { children: ee(u.service || u.provider) }),
      /* @__PURE__ */ n("p", { children: u.authed ? "Ready to use" : "Not detected yet — checking your sign-in…" }),
      !u.authed && /* @__PURE__ */ n("button", { type: "button", className: "secondary", onClick: () => i(u.service || u.provider), children: [
        "Sign in to ",
        ee(u.service || u.provider)
      ] })
    ] })),
    /* @__PURE__ */ n("h3", { children: "Docker account" }),
    /* @__PURE__ */ n("p", { children: e?.docker_account || (e?.docker_status === "failed" ? "Not detected yet — checking your Docker sign-in…" : "Checking…") }),
    d?.detail?.match(/sign-in could not start/i) && /* @__PURE__ */ n(O, { status: "attention", children: [
      "Sign-in needs attention: ",
      d.detail
    ] })
  ] }) });
}
function Ut({ identity: t }) {
  return /* @__PURE__ */ n("div", { className: "view-stack", children: [
    /* @__PURE__ */ n(C, { title: "How Federation works", lead: "A trusted collective shares spare capacity without sharing your computer.", children: /* @__PURE__ */ n("ol", { children: [
      /* @__PURE__ */ n("li", { children: "A requester packages one chosen folder and describes the work." }),
      /* @__PURE__ */ n("li", { children: "A contributor accepts a task only when contributing is on." }),
      /* @__PURE__ */ n("li", { children: "The task runs in an isolated Docker sandbox and returns a receipt and result." })
    ] }) }),
    /* @__PURE__ */ n(C, { title: "Your safety boundary", children: /* @__PURE__ */ n("p", { children: "Everything else is blocked. Tasks cannot read your other files, reach your home network, or see other tasks." }) }),
    /* @__PURE__ */ n(C, { title: "Questions people ask", children: [
      /* @__PURE__ */ n("details", { open: !0, children: [
        /* @__PURE__ */ n("summary", { children: "Whose account is used?" }),
        /* @__PURE__ */ n("p", { children: [
          Ye(t),
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
function Ht() {
  const t = new URLSearchParams(location.search).get("token") || "", [e, r] = A({ status: null, tasks: [], requests: [], ledger: [], identity: null, settings: null, roster: [], coordinatorUnavailable: !1, sessionExpired: !1, daemonUnavailable: !1, message: "", submission: null }), [a, s] = A(Re), [i, d] = A(() => Pe(location.hash)), [l, p] = A(null), [c, u] = A(null), h = z(async (m, g = {}) => {
    const x = await fetch(m, { ...g, headers: { "x-waspflow-session-token": t, ...g.body ? { "content-type": "application/json" } : {} } });
    let q = {};
    try {
      q = await x.json();
    } catch {
    }
    if (!x.ok) {
      const P = new Error(q.error || "Waspflow could not complete that request.");
      throw P.status = x.status, P;
    }
    return q;
  }, [t]), o = z(async () => {
    try {
      const m = await h("/status"), g = !m.coordinator_unavailable, [x, q, P, R, U, $, I] = await Promise.all([m.state === "idle" ? h("/tasks").catch(() => []) : Promise.resolve([]), h("/ledger").catch(() => []), h("/identity").catch(() => null), h("/settings").catch(() => null), g ? h("/roster").catch(() => []) : Promise.resolve([]), g ? h("/activity").catch(() => []) : Promise.resolve([]), g ? h("/requests").catch(() => null) : Promise.resolve(null)]);
      r((Xe) => ({ ...Xe, status: m, tasks: D(x), ledger: D(q), identity: P || { key_id: m.key_id, coordinator_url: m.coordinator_url }, settings: R, roster: D(U?.roster || U), requests: I ? D(I) : D(q).filter((ie) => ie.author === "me" || ie.role === "requester" || ie.requester === !0), coordinatorUnavailable: !!m.coordinator_unavailable, daemonUnavailable: !1 }));
    } catch (m) {
      m.status === 401 ? r((g) => ({ ...g, sessionExpired: !0 })) : r((g) => ({ ...g, daemonUnavailable: !0 }));
    }
  }, [h]);
  Z(() => {
    const m = () => d(Pe(location.hash));
    if (addEventListener("hashchange", m), e.sessionExpired) return () => removeEventListener("hashchange", m);
    o();
    const g = setInterval(o, vt);
    return () => {
      removeEventListener("hashchange", m), clearInterval(g);
    };
  }, [o, e.sessionExpired]);
  const _ = async (m, g) => {
    try {
      const x = await h(m, { method: "POST", body: g ? JSON.stringify(g) : void 0 });
      r((q) => ({ ...q, status: x, message: "" }));
    } catch (x) {
      r((q) => ({ ...q, message: x.message }));
    }
  }, f = async (m) => {
    try {
      const g = await Promise.all(m.files.map(wt));
      if (g.reduce((R, U) => R + Math.floor(U.data_base64.length * 3 / 4), 0) > 20 * 1024 * 1024) throw new Error("Attachments are limited to 20 MB. Choose fewer or smaller files.");
      const q = { ...m, attachments: g, network: m.git_url || m.network ? "enabled" : "disabled" };
      delete q.files;
      const P = await h("/submit", { method: "POST", body: JSON.stringify(q) });
      s(Re), r((R) => ({ ...R, status: P, submission: P.submission, message: "" })), location.hash = "#/requests";
    } catch (g) {
      s((x) => ({ ...x, error: g.message }));
    }
  }, b = z(async (m) => {
    if (m)
      try {
        const g = await h(`/tasks/${encodeURIComponent(Ae(m))}`);
        p(g);
      } catch {
        p(null);
      }
  }, [h]), w = z(async (m) => {
    try {
      const g = await h(`/tasks/${encodeURIComponent(Ae(m))}/log?since=0`);
      u(g);
    } catch {
      u(null);
    }
  }, [h]), k = i.name === "tasks" ? decodeURIComponent(i.parts[0] || "") : "";
  if (Z(() => {
    k && b(k);
  }, [k, b]), e.sessionExpired) return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: "This local link has expired", lead: pt, children: /* @__PURE__ */ n("button", { type: "button", onClick: () => {
    location.href = "waspflow://federation/reconnect";
  }, children: "Reconnect Federation" }) }) });
  if (e.daemonUnavailable) return /* @__PURE__ */ n(E, { children: /* @__PURE__ */ n(C, { title: "Federation isn’t running right now", lead: "Nothing changed since the last time this page could connect.", children: /* @__PURE__ */ n("button", { type: "button", onClick: () => location.href = "waspflow://federation/reconnect", children: "Reconnect Federation" }) }) });
  if (i.name === "tasks") return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n(se, { route: "requests" }),
    /* @__PURE__ */ n("main", { id: "main-content", children: /* @__PURE__ */ n(Ct, { digest: k, task: l, log: c, loadLog: w, resultHref: k ? `/result/${encodeURIComponent(k)}?token=${encodeURIComponent(t)}` : null }) })
  ] });
  if (i.name === "compose") return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n(se, { route: "requests" }),
    /* @__PURE__ */ n("main", { id: "main-content", children: /* @__PURE__ */ n(At, { form: a, setForm: s, submit: f, probeGit: (m) => h("/git/probe", { method: "POST", body: JSON.stringify({ git_url: m }) }) }) })
  ] });
  if (i.name === "contribute" && ue(e.status).name !== "status") return /* @__PURE__ */ n(Ke, { view: ue(e.status), status: e.status, control: _ });
  const v = i.name === "contribute" ? /* @__PURE__ */ n(Nt, { ...e, control: _, goTask: (m) => {
    location.hash = `#/tasks/${encodeURIComponent(m)}`;
  }, beginGitHub: () => _("/identity/signin", { service: "github" }) }) : i.name === "requests" ? /* @__PURE__ */ n(Rt, { requests: e.requests, submission: e.submission, form: a, setForm: s, submit: f, probeGit: () => {
  }, acknowledge: () => _("/submit/ack") }) : i.name === "activity" ? /* @__PURE__ */ n(It, { ledger: e.ledger, requests: e.requests }) : i.name === "settings" ? /* @__PURE__ */ n(Ft, { section: i.parts[0] || "device", identity: e.identity, settings: e.settings, roster: e.roster, save: (m) => h("/settings", { method: "POST", body: JSON.stringify(m) }).then((g) => r((x) => ({ ...x, settings: g }))), signIn: (m) => _("/identity/signin", { service: m }), status: e.status }) : /* @__PURE__ */ n(Ut, { identity: e.identity });
  return /* @__PURE__ */ n(T, { children: [
    /* @__PURE__ */ n(se, { route: i.name }),
    /* @__PURE__ */ n("main", { id: "main-content", children: [
      /* @__PURE__ */ n(O, { children: e.message }),
      v
    ] })
  ] });
}
if (typeof document < "u") {
  const t = document.createElement("style");
  t.textContent = gt, document.head.append(t);
  const e = document.getElementById("app");
  e.textContent = "", ot(/* @__PURE__ */ n(Ht, {}), e);
}
export {
  ft as capacityKind,
  ht as lifecycleStage,
  Ye as providerCapacitySubject,
  ee as providerDisplayName,
  Pe as routeFromHash,
  Je as statusRole,
  mt as taskTimeline,
  ue as viewForStatus
};
