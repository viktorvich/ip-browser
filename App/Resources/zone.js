// IP Browser: the page's clock in the time zone of the server's exit address.
// One function, applied to every window realm (by the shield) and to every script worker
// made from a Blob (prefixed into its source). Called as zone(global, TZ, NATIVE, FTS, SRC):
// NATIVE maps our functions to the source text of the native ones they stand for, so
// Function.prototype.toString shows the same «[native code]» as before.
function zone(g, TZ, NATIVE, FTS, SRC) {
  'use strict';
  try {
    const R = g.Reflect, apply = R.apply, construct = R.construct, O = g.Object, defP = O.defineProperty, getD = O.getOwnPropertyDescriptor;
    const RD = g.Date, RP = RD && RD.prototype, I = g.Intl, RDTF = I && I.DateTimeFormat;
    if (!TZ || !RD || !RDTF) return;
    const floor = g.Math.floor, round = g.Math.round, abs = g.Math.abs, trunc = g.Math.trunc, str = g.String, num = g.Number;
    const test = g.RegExp.prototype.test, toJSON = g.JSON.stringify;
    if (!NATIVE) {
      // A worker: its own map and its own Function.prototype.toString.
      NATIVE = new g.WeakMap(); FTS = g.Function.prototype.toString;
      const orig = FTS, map = NATIVE;
      const ts = {toString() { const n = map.get(this); return n !== undefined ? n : apply(orig, this, []); }}.toString;
      map.set(ts, apply(FTS, orig, []));
      defP(g.Function.prototype, 'toString', {value: ts, writable: true, configurable: true, enumerable: false});
    }
    const native = (f, like) => { NATIVE.set(f, apply(FTS, like, [])); return f; };
    const put = (o, k, f, like, length) => {
      if (length !== undefined) defP(f, 'length', {value: length, configurable: true});
      native(f, like);
      defP(o, k, {value: f, writable: true, configurable: true, enumerable: false});
    };
    let fmt, nameFmt;
    try {
      fmt = new RDTF('en-US', {timeZone: TZ, hourCycle: 'h23', era: 'short', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric'});
      nameFmt = new RDTF(undefined, {timeZone: TZ, timeZoneName: 'long'});
    } catch (e) { return; }   // a zone this engine does not know: leave the clock alone
    const N = {};
    for (const k of ['getTime', 'setTime', 'getTimezoneOffset', 'getUTCFullYear', 'getUTCMonth', 'getUTCDate', 'getUTCDay', 'getUTCHours',
      'getUTCMinutes', 'getUTCSeconds', 'setUTCFullYear', 'setUTCMonth', 'setUTCDate', 'setUTCHours', 'setUTCMinutes', 'setUTCSeconds',
      'setUTCMilliseconds', 'toLocaleString', 'toLocaleDateString', 'toLocaleTimeString', 'toString', 'toDateString', 'toTimeString',
      'getFullYear', 'getMonth', 'getDate', 'getDay', 'getHours', 'getMinutes', 'getSeconds', 'setFullYear', 'setMonth', 'setDate',
      'setHours', 'setMinutes', 'setSeconds', 'setMilliseconds', 'getYear', 'setYear']) N[k] = RP[k];
    const parts = RDTF.prototype.formatToParts, RDparse = RD.parse, RDUTC = RD.UTC;
    const T = d => apply(N.getTime, d, []);
    const cache = new g.Map();
    const utc = (y, mo, d, h, mi, s) => { const x = new RD(0); apply(N.setUTCFullYear, x, [y, mo, d]); apply(N.setUTCHours, x, [h, mi, s, 0]); return T(x); };
    // Minutes to add to the zone's local time to get UTC (the sign of getTimezoneOffset).
    // Offsets change only on quarter hours, so one answer serves a 15-minute bucket.
    function off(t) {
      if (t !== t) return NaN;
      if (t > 8.64e15) t = 8.64e15; else if (t < -8.64e15) t = -8.64e15;
      const k = floor(t / 900000);
      let v = cache.get(k);
      if (v !== undefined) return v;
      const a = apply(parts, fmt, [t]), p = {};
      for (let i = 0; i < a.length; i++) p[a[i].type] = a[i].value;
      let y = num(p.year); if (str(p.era || '')[0] === 'B') y = 1 - y;
      const base = t - (((t % 1000) + 1000) % 1000);
      v = round((base - utc(y, num(p.month) - 1, num(p.day), num(p.hour) % 24, num(p.minute), num(p.second))) / 60000);
      if (cache.size > 4096) cache.clear();
      cache.set(k, v);
      return v;
    }
    const local = t => new RD(t - off(t) * 60000);
    // A local time to UTC as ECMAScript does: a repeated hour (autumn) means its first
    // occurrence; a skipped hour (spring) is read with the offset from before the change.
    const fromLocal = lt => {
      if (lt !== lt) return NaN;
      const oB = off(lt - 864e5), oA = off(lt + 864e5), tB = lt + oB * 60000, tA = lt + oA * 60000;
      const okB = off(tB) === oB, okA = off(tA) === oA;
      return okB && okA ? (tB < tA ? tB : tA) : okA && !okB ? tA : tB;
    };

    // Reading the local date and time.
    const G = {getFullYear: 'getUTCFullYear', getMonth: 'getUTCMonth', getDate: 'getUTCDate', getDay: 'getUTCDay',
      getHours: 'getUTCHours', getMinutes: 'getUTCMinutes', getSeconds: 'getUTCSeconds'};
    for (const k in G) {
      const u = N[G[k]];
      put(RP, k, {[k]() { const t = T(this); return t !== t ? NaN : apply(u, local(t), []); }}[k], N[k]);
    }
    put(RP, 'getTimezoneOffset', {getTimezoneOffset() { return off(T(this)); }}.getTimezoneOffset, N.getTimezoneOffset);
    if (N.getYear) put(RP, 'getYear', {getYear() { const t = T(this); return t !== t ? NaN : apply(N.getUTCFullYear, local(t), []) - 1900; }}.getYear, N.getYear);

    // Setting the local date and time.
    const S = {setFullYear: ['setUTCFullYear', 3], setMonth: ['setUTCMonth', 2], setDate: ['setUTCDate', 1], setHours: ['setUTCHours', 4],
      setMinutes: ['setUTCMinutes', 3], setSeconds: ['setUTCSeconds', 2], setMilliseconds: ['setUTCMilliseconds', 1]};
    for (const k in S) {
      const u = N[S[k][0]], isYear = k === 'setFullYear';
      put(RP, k, {[k](...a) {
        const t = T(this);
        const x = new RD(t !== t ? (isYear ? 0 : NaN) : t - off(t) * 60000);
        apply(u, x, a);
        return apply(N.setTime, this, [fromLocal(T(x))]);
      }}[k], N[k], S[k][1]);
    }
    if (N.setYear) {
      const sfy = RP.setFullYear;
      put(RP, 'setYear', {setYear(y) {
        y = num(y);
        if (y !== y) return apply(N.setTime, this, [NaN]);
        const i = trunc(y);
        return apply(sfy, this, [i >= 0 && i <= 99 ? 1900 + i : y]);
      }}.setYear, N.setYear);
    }

    // Text of a date.
    const W = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], M = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const p2 = n => (n < 10 ? '0' : '') + n;
    const yr = y => y >= 0 ? (y < 1000 ? ('000' + y).slice(-4) : str(y)) : '-' + ('000000' + (-y)).slice(-6);
    const rawName = t => { const a = apply(parts, nameFmt, [t]); for (let i = 0; i < a.length; i++) if (a[i].type === 'timeZoneName') return a[i].value; return TZ; };
    // Old dates with an offset that has no name: the zone's present name, as the engine says it.
    const zoneName = t => { const n = rawName(t); return n[0] === 'G' && n[1] === 'M' && n[2] === 'T' && (n[3] === '+' || n[3] === '-') ? rawName(g.Date.now()) : n; };
    const gmt = o => { const a = abs(o); return 'GMT' + (o <= 0 ? '+' : '-') + p2(floor(a / 60)) + p2(a % 60); };
    const day = x => W[apply(N.getUTCDay, x, [])] + ' ' + M[apply(N.getUTCMonth, x, [])] + ' ' + p2(apply(N.getUTCDate, x, [])) + ' ' + yr(apply(N.getUTCFullYear, x, []));
    const time = (x, t) => p2(apply(N.getUTCHours, x, [])) + ':' + p2(apply(N.getUTCMinutes, x, [])) + ':' + p2(apply(N.getUTCSeconds, x, [])) + ' ' + gmt(off(t)) + ' (' + zoneName(t) + ')';
    put(RP, 'toString', {toString() { const t = T(this); if (t !== t) return 'Invalid Date'; const x = local(t); return day(x) + ' ' + time(x, t); }}.toString, N.toString);
    put(RP, 'toDateString', {toDateString() { const t = T(this); return t !== t ? 'Invalid Date' : day(local(t)); }}.toDateString, N.toDateString);
    put(RP, 'toTimeString', {toTimeString() { const t = T(this); return t !== t ? 'Invalid Date' : time(local(t), t); }}.toTimeString, N.toTimeString);
    // Options without a zone get the server's; everything else (inherited options too) stays.
    const opt = o => o === undefined ? {timeZone: TZ}
      : (o !== null && typeof o === 'object' && o.timeZone === undefined ? O.create(o, {timeZone: {value: TZ, enumerable: true}}) : o);
    for (const k of ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString']) {
      const nf = N[k];
      put(RP, k, {[k](locales, options) { return apply(nf, this, [locales, opt(options)]); }}[k], nf, 0);
    }

    // Intl: a formatter without a zone formats in the server's zone and says so in resolvedOptions().
    const DTF = function DateTimeFormat(locales, options) {
      return new.target ? construct(RDTF, [locales, opt(options)], new.target) : apply(RDTF, this, [locales, opt(options)]);
    };
    defP(DTF, 'prototype', {value: RDTF.prototype, writable: false, enumerable: false, configurable: false});
    defP(DTF, 'length', {value: 0, configurable: true});
    defP(DTF, 'supportedLocalesOf', {value: RDTF.supportedLocalesOf, writable: true, configurable: true, enumerable: false});
    native(DTF, RDTF);
    defP(RDTF.prototype, 'constructor', {value: DTF, writable: true, configurable: true, enumerable: false});
    defP(I, 'DateTimeFormat', {value: DTF, writable: true, configurable: true, enumerable: false});

    // Date(): local components and zone-less date-time strings are the server's local time.
    const tzRe = /(?:Z|GMT|UTC?|[ECMP][SD]T|[+-]\d\d:?\d\d)\s*(?:\([^)]*\))?\s*$/i, isoDay = /^\s*[+-]?\d{4,6}(?:-\d\d(?:-\d\d)?)?\s*$/;
    const parse = {parse(s) {
      s = str(s);
      const t = apply(RDparse, RD, [s]);
      if (t !== t || apply(test, tzRe, [s]) || apply(test, isoDay, [s])) return t;
      return fromLocal(t - apply(N.getTimezoneOffset, new RD(t), []) * 60000);   // read as the phone's local time, then as the server's
    }}.parse;
    const prim = v => {
      const e = v[g.Symbol.toPrimitive];
      if (e != null) return apply(e, v, ['default']);
      for (const m of ['valueOf', 'toString']) {
        const f = v[m];
        if (typeof f === 'function') { const r = apply(f, v, []); if (r === null || (typeof r !== 'object' && typeof r !== 'function')) return r; }
      }
      throw new g.TypeError('Cannot convert object to primitive value');
    };
    const D = function Date(...a) {
      if (!new.target) return apply(RP.toString, new RD(), []);
      if (a.length === 0) return construct(RD, [], new.target);
      if (a.length === 1) {
        let v = a[0];
        if (v !== null && (typeof v === 'object' || typeof v === 'function')) {
          let dv; try { dv = apply(N.getTime, v, []); } catch (e) {}
          if (dv !== undefined) return construct(RD, [dv], new.target);
          v = prim(v);
        }
        return construct(RD, [typeof v === 'string' ? parse(v) : v], new.target);
      }
      return construct(RD, [fromLocal(apply(RDUTC, RD, a))], new.target);
    };
    defP(D, 'prototype', {value: RP, writable: false, enumerable: false, configurable: false});
    defP(D, 'length', {value: 7, configurable: true});
    for (const k of ['now', 'UTC']) defP(D, k, {value: RD[k], writable: true, configurable: true, enumerable: false});
    put(D, 'parse', parse, RDparse);
    native(D, RD);
    defP(RP, 'constructor', {value: D, writable: true, configurable: true, enumerable: false});
    defP(g, 'Date', {value: D, writable: true, configurable: true, enumerable: false});

    // document.lastModified is written by the engine in the phone's local time.
    const lm = g.Document && getD(g.Document.prototype, 'lastModified');
    if (lm && lm.get) {
      const ng = lm.get;
      const get = getD({get lastModified() {
        const s = apply(ng, this, []), t = apply(RDparse, RD, [s]);
        if (t !== t) return s;
        const x = local(t);
        return p2(apply(N.getUTCMonth, x, []) + 1) + '/' + p2(apply(N.getUTCDate, x, [])) + '/' + yr(apply(N.getUTCFullYear, x, [])) + ' ' +
          p2(apply(N.getUTCHours, x, [])) + ':' + p2(apply(N.getUTCMinutes, x, [])) + ':' + p2(apply(N.getUTCSeconds, x, []));
      }}, 'lastModified').get;
      native(get, ng);
      defP(g.Document.prototype, 'lastModified', {get, set: lm.set, enumerable: lm.enumerable, configurable: true});
    }

    // Temporal, where the engine has it.
    const now = g.Temporal && g.Temporal.Now;
    if (now) {
      if (now.timeZoneId) put(now, 'timeZoneId', {timeZoneId() { return TZ; }}.timeZoneId, now.timeZoneId);
      for (const k of ['zonedDateTimeISO', 'plainDateTimeISO', 'plainDateISO', 'plainTimeISO']) {
        const nf = now[k];
        if (typeof nf === 'function') put(now, k, {[k](tz) { return apply(nf, now, [tz === undefined ? TZ : tz]); }}[k], nf, 0);
      }
    }

    // A script worker made from a Blob runs this same function first (only in a worker scope).
    if (g.Blob && SRC) {
      const RB = g.Blob, prefix = 'if(typeof WorkerGlobalScope!=="undefined")(' + SRC + ')(self,' + toJSON(TZ) + ',null,null,' + toJSON(SRC) + ');\n';
      const B = function Blob(...a) {
        if (!new.target) return apply(RB, this, a);
        try {
          const ty = a[1] && a[1].type;
          if (typeof ty === 'string' && apply(test, /(java|ecma)script/i, [ty]) && a[0] != null && typeof a[0] !== 'string') {
            const list = [prefix];
            for (const p of a[0]) list[list.length] = p;
            a[0] = list;
          }
        } catch (e) {}
        return construct(RB, a, new.target);
      };
      defP(B, 'prototype', {value: RB.prototype, writable: false, enumerable: false, configurable: false});
      defP(B, 'length', {value: 0, configurable: true});
      native(B, RB);
      defP(RB.prototype, 'constructor', {value: B, writable: true, configurable: true, enumerable: false});
      defP(g, 'Blob', {value: B, writable: true, configurable: true, enumerable: false});
    }
  } catch (e) {}
}
