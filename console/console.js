/* ============================================================================
 * moonseek web console - interaction logic
 * ----------------------------------------------------------------------------
 * Zero dependencies, no imports, no build step. Plain browser JS.
 * Implements the frozen contract in ../docs/api.md:
 *   GET  /healthz              GET  /_stats
 *   GET  /search   POST /search
 *   GET  /suggest  GET  /terms  GET  /explain
 *   POST /index    POST /index/bulk   DELETE /index?id=
 *
 * SECURITY: every value that reaches the DOM goes through escapeHtml(), except
 * the search snippet, which goes through safeSnippet(): it lets *only* the bare
 * <mark>/</mark> delimiters through and escapes everything else. No innerHTML
 * ever receives a raw value from the network or from the user.
 * ==========================================================================*/
(function () {
  'use strict';

  /* ------------------------------------------------------------------ utils */

  function $(id) { return document.getElementById(id); }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Decode a bounded set of HTML entities (the ones an HTML-escaping server
  // would emit). Unknown entities are left literal. Single pass: no double
  // decoding, so "&amp;lt;" stays "&lt;".
  function decodeEntities(text) {
    var s = String(text == null ? '' : text);
    if (s.indexOf('&') === -1) return s;
    return s.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*);/g, function (whole, body) {
      if (body.charAt(0) === '#') {
        var code = body.charAt(1).toLowerCase() === 'x'
          ? parseInt(body.slice(2), 16)
          : parseInt(body.slice(1), 10);
        if (!isFinite(code) || code <= 0 || code > 0x10FFFF) return whole;
        try { return String.fromCodePoint(code); } catch (e) { return whole; }
      }
      switch (body.toLowerCase()) {
        case 'amp': return '&';
        case 'lt': return '<';
        case 'gt': return '>';
        case 'quot': return '"';
        case 'apos': return "'";
        case 'nbsp': return '\u00a0';
        default: return whole;
      }
    });
  }

  // Only <mark> / </mark> may survive as real tags; anything else (script,
  // img, attributes, stray angle brackets) is escaped. The server may send the
  // snippet raw or already HTML-escaped, so entities are normalised once first.
  function safeSnippet(raw) {
    var decoded = decodeEntities(raw);
    var out = '';
    var re = /<\/?mark\s*>/gi;
    var last = 0, m;
    while ((m = re.exec(decoded)) !== null) {
      out += escapeHtml(decoded.slice(last, m.index));
      out += /^<\//.test(m[0]) ? '</mark>' : '<mark>';
      last = m.index + m[0].length;
    }
    out += escapeHtml(decoded.slice(last));
    return out;
  }

  function formatNum(value, key) {
    key = key || '';
    var n = Number(value);
    if (!isFinite(n)) return String(value == null ? '-' : value);
    if (/ms$/.test(key)) return n.toFixed(n < 1 ? 3 : 2);
    if (/bytes$/.test(key)) return formatBytes(n);
    return n.toLocaleString('en-US');
  }

  function formatBytes(n) {
    n = Number(n) || 0;
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(n < 10 ? 2 : 1)) + ' ' + u[i];
  }

  function clampLimit(v) {
    var n = parseInt(v, 10);
    if (!isFinite(n) || n < 1) n = 10;
    if (n > 1000) n = 1000;
    return n;
  }

  function normalizeBase(url) {
    var u = String(url || '').trim().replace(/\/+$/, '');
    if (!u) u = 'http://127.0.0.1:7700';
    return u;
  }

  // Optional deep-link override: index.html?base=http://host:port (or
  // #base=...). Without it the hard-coded default http://127.0.0.1:7700 is used.
  function initialBase() {
    try {
      var p = new URLSearchParams(location.search).get('base');
      if (p) return p;
      var m = /(?:^|[#&])base=([^&]+)/.exec(location.hash || '');
      if (m) return decodeURIComponent(m[1]);
    } catch (e) { /* ignore */ }
    return $('base').value;
  }

  /* ------------------------------------------------------------------ state */

  var state = {
    base: 'http://127.0.0.1:7700',
    connected: false,
    version: '',
    lastQuery: '',
    filters: {},            // { field: Set(values) }
    statsTimer: null,
    healthTimer: null,
    toastTimer: null,
    statsSample: null
  };

  /* ------------------------------------------------------------------ toast */

  function toast(message, kind) {
    var box = $('toast');
    $('toast-msg').textContent = String(message);
    box.className = 'toast' + (kind === 'ok' ? ' ok' : '');
    box.hidden = false;
    if (state.toastTimer) clearTimeout(state.toastTimer);
    state.toastTimer = setTimeout(function () { box.hidden = true; }, kind === 'ok' ? 3500 : 9000);
  }
  $('toast').querySelector('.toast-close').addEventListener('click', function () { $('toast').hidden = true; });

  /* --------------------------------------------------------------- transport */

  function api(path, options) {
    var url = state.base + path;
    var opts = {}; var k;
    if (options) for (k in options) if (Object.prototype.hasOwnProperty.call(options, k)) opts[k] = options[k];
    var ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    if (ctrl) opts.signal = ctrl.signal;
    var timer = setTimeout(function () { if (ctrl) ctrl.abort(); }, 20000);
    return fetch(url, opts).then(function (res) {
      return res.text().then(function (text) {
        var json = null;
        if (text) { try { json = JSON.parse(text); } catch (e) { json = null; } }
        return { ok: res.ok, status: res.status, json: json, text: text };
      });
    }).then(function (r) {
      clearTimeout(timer);
      return r;
    }, function (err) {
      clearTimeout(timer);
      throw err;
    });
  }

  function describeError(res) {
    if (res && res.json && res.json.error) {
      return res.json.error + (res.json.code ? ' [' + res.json.code + ']' : '') + ' (HTTP ' + res.status + ')';
    }
    var snippet = res && res.text ? String(res.text).slice(0, 160) : '';
    return 'HTTP ' + (res ? res.status : '?') + (snippet ? ' - ' + snippet : '');
  }

  function networkError(err) {
    var msg = err && err.name === 'AbortError' ? '请求超时（20s）' : (err && err.message ? err.message : String(err));
    toast('无法连接到服务：' + msg + '（' + state.base + '）');
    setStatus(false, '连接失败');
  }

  function setStatus(ok, text) {
    var dot = $('dot');
    dot.className = 'dot' + (ok ? ' ok' : ' bad');
    dot.title = text;
    $('status-text').textContent = text;
    state.connected = !!ok;
  }

  /* ---------------------------------------------------------------- connect */

  function connect() {
    state.base = normalizeBase($('base').value);
    $('base').value = state.base;
    setStatus(false, '连接中…');
    return api('/healthz').then(function (res) {
      if (!res.ok) { setStatus(false, '健康检查失败'); toast('GET /healthz 失败：' + describeError(res)); return; }
      var data = res.json || {};
      var status = data.status || '(unknown)';
      state.version = data.version || '';
      $('version').textContent = state.version ? ('v' + state.version) : '—';
      var uptime = data.uptime_ms != null ? Math.round(Number(data.uptime_ms) / 1000) + 's' : '';
      setStatus(status === 'ok' || res.ok, 'ok' + (uptime ? ' · up ' + uptime : ''));
      startPolling();
      refreshStats();
      if (state.lastQuery) doSearch();
      return data;
    }).catch(function (err) { networkError(err); });
  }

  function startPolling() {
    stopPolling();
    state.statsTimer = setInterval(function () {
      if (state.connected) refreshStats();
    }, 2000);
    state.healthTimer = setInterval(function () {
      api('/healthz').then(function (res) {
        if (res.ok && res.json) {
          setStatus(true, 'ok');
          if (res.json.version && !state.version) {
            state.version = res.json.version;
            $('version').textContent = 'v' + state.version;
          }
        } else { setStatus(false, '健康检查失败'); }
      }).catch(function () { setStatus(false, '连接失败'); });
    }, 15000);
  }
  function stopPolling() {
    if (state.statsTimer) { clearInterval(state.statsTimer); state.statsTimer = null; }
    if (state.healthTimer) { clearInterval(state.healthTimer); state.healthTimer = null; }
  }

  /* ------------------------------------------------------------------ stats */

  function refreshStats() {
    return api('/_stats').then(function (res) {
      if (!res.ok) { return; }
      renderStats(res.json || {});
    }).catch(function () { /* polling path: keep quiet, the dot already reports */ });
  }

  function renderStats(s) {
    state.statsSample = s;
    var rows = [
      ['docs', s.docs],
      ['terms', s.terms],
      ['snapshot_bytes', s.snapshot_bytes],
      ['queries_served', s.queries_served],
      ['avg_query_ms', s.avg_query_ms],
      ['p99_query_ms', s.p99_query_ms]
    ];
    var nums = rows.map(function (r) { var n = Number(r[1]); return isFinite(n) ? n : 0; });
    var max = Math.max(1, nums[0] || 0, nums[1] || 0, nums[2] || 0, nums[3] || 0);
    var html = '';
    for (var i = 0; i < rows.length; i++) {
      var key = rows[i][0], raw = rows[i][1], n = nums[i];
      // latency stats are small: scale them against the *other* latency value
      var denom = /_ms$/.test(key) ? Math.max(0.001, nums[4], nums[5]) : max;
      var pct = Math.min(100, (n / denom) * 100);
      html += '<div class="stat">'
        + '<span class="stat-label">' + escapeHtml(key) + '</span>'
        + '<span class="stat-val">' + escapeHtml(formatNum(raw, key)) + '</span>'
        + '<span class="stat-bar" style="width:' + (isFinite(pct) ? pct.toFixed(1) : '0') + '%"></span>'
        + '</div>';
    }
    var extra = [];
    if (Array.isArray(s.fields) && s.fields.length) extra.push('fields: ' + s.fields.join(', '));
    if (s.segments != null) extra.push('segments: ' + s.segments);
    if (s.indexed_docs != null) extra.push('indexed: ' + s.indexed_docs);
    if (s.deleted_docs != null) extra.push('deleted: ' + s.deleted_docs);
    if (extra.length) {
      html += '<div class="stat wide"><span class="stat-label">index</span>'
        + '<span class="stat-val" style="font-size:12px">' + escapeHtml(extra.join(' · ')) + '</span></div>';
    }
    $('stats').innerHTML = html;
  }

  /* ----------------------------------------------------------------- search */

  function facetFields() {
    return ($('facet-fields').value || '').split(',').map(function (x) { return x.trim(); })
      .filter(function (x) { return x.length > 0; });
  }

  function filterParams(params) {
    for (var field in state.filters) {
      if (!Object.prototype.hasOwnProperty.call(state.filters, field)) continue;
      state.filters[field].forEach(function (v) { params.append('filter', field + ':' + v); });
    }
  }

  function selectedCount() {
    var n = 0;
    for (var f in state.filters) if (state.filters[f]) n += state.filters[f].size;
    return n;
  }

  function updateClearBtn() {
    $('clear-filters').hidden = selectedCount() === 0;
  }

  function doSearch() {
    var q = ($('q').value || '').trim();
    if (!q) { toast('请输入查询词'); $('q').focus(); return Promise.resolve(); }
    state.lastQuery = q;
    var limit = clampLimit($('limit').value);
    var params = new URLSearchParams();
    params.set('q', q);
    params.set('limit', String(limit));
    params.set('explain', 'true');
    params.set('snippet_chars', '200');
    var ff = facetFields();
    if (ff.length) params.set('facets', ff.join(','));
    filterParams(params);

    $('search-meta').innerHTML = '<span class="spin"></span> 搜索中…';
    return api('/search?' + params.toString()).then(function (res) {
      if (!res.ok) {
        $('search-meta').innerHTML = '<span style="color:var(--err)">搜索失败</span>';
        toast('GET /search 失败：' + describeError(res));
        return;
      }
      var data = res.json || {};
      renderResults(data, q);
      return runAggs(data);   // keep the aggregation panel in sync
    }).catch(function (err) { networkError(err); });
  }

  function renderResults(data, q) {
    var hits = Array.isArray(data.hits) ? data.hits : [];
    var total = data.total != null ? data.total : hits.length;
    var took = data.took_ms;
    var parts = [];
    parts.push('<span class="k">查询</span><span class="pill">' + escapeHtml(q) + '</span>');
    parts.push('<span class="k">命中</span><b>' + escapeHtml(String(total)) + '</b> 条');
    parts.push('<span class="k">本次耗时</span><b>' + escapeHtml(took == null ? '-' : formatNum(took, 'avg_query_ms')) + '</b> ms');
    parts.push('<span class="k">返回</span>' + escapeHtml(String(hits.length)) + ' 条');
    if (data.clusters && data.clusters.shards_total != null) {
      parts.push('<span class="k">分片</span>' + escapeHtml(String(data.clusters.shards_ok)) + '/' + escapeHtml(String(data.clusters.shards_total)));
    }
    var facetN = selectedCount();
    if (facetN) parts.push('<span class="k">筛选</span>' + escapeHtml(String(facetN)) + ' 项');
    $('search-meta').innerHTML = parts.join('<span class="k">·</span>');

    // results
    var root = $('results');
    if (!hits.length) {
      root.innerHTML = '<div class="empty">没有命中。' + (total === 0 ? '' : '（total=' + escapeHtml(String(total)) + '）') + '</div>';
    } else {
      var html = '';
      for (var i = 0; i < hits.length; i++) html += hitHtml(hits[i], i + 1);
      root.innerHTML = html;
    }

    // facets + suggest
    renderFacets(data.facets || {});
    if (total === 0 && q) { askSuggest(q); } else { $('suggest').hidden = true; }
  }

  function hitHtml(hit, rank) {
    var id = hit && hit.id != null ? String(hit.id) : '(no id)';
    var score = hit && hit.score != null ? Number(hit.score) : null;
    var html = '<article class="hit">';
    html += '<div class="hit-head">'
      + '<span class="hit-rank">#' + escapeHtml(String(rank)) + '</span>'
      + '<code class="hit-id">' + escapeHtml(id) + '</code>'
      + '<span class="hit-score">' + escapeHtml(score == null ? '-' : score.toFixed(4)) + '</span>'
      + '</div>';

    // stored fields (title / keywords / desc / ...), all escaped
    var fields = hit && hit.fields && typeof hit.fields === 'object' ? hit.fields : null;
    if (fields) {
      var fp = [];
      for (var k in fields) {
        if (!Object.prototype.hasOwnProperty.call(fields, k)) continue;
        var v = String(fields[k]);
        if (!v) continue;
        if (v.length > 180) v = v.slice(0, 180) + '…';
        fp.push('<span><span class="fk">' + escapeHtml(k) + ':</span> <span class="fv">' + escapeHtml(v) + '</span></span>');
      }
      if (fp.length) html += '<div class="hit-fields">' + fp.join('') + '</div>';
    }

    if (hit && hit.snippet) {
      html += '<div class="hit-snippet">' + safeSnippet(hit.snippet) + '</div>';
    }

    var explain = hit && Array.isArray(hit.explain) ? hit.explain : null;
    if (explain && explain.length) {
      html += '<details class="explain"><summary>explain · ' + escapeHtml(String(explain.length)) + ' 个词项得分明细</summary>'
        + '<table class="explain-tbl"><thead><tr>'
        + '<th>field</th><th>term</th><th>tf</th><th>df</th><th>idf</th><th>norm</th><th>score</th>'
        + '</tr></thead><tbody>';
      for (var j = 0; j < explain.length; j++) {
        var e = explain[j] || {};
        html += '<tr>'
          + '<td>' + escapeHtml(e.field) + '</td>'
          + '<td>' + escapeHtml(e.term) + '</td>'
          + '<td class="num">' + escapeHtml(fmtMaybe(e.tf)) + '</td>'
          + '<td class="num">' + escapeHtml(fmtMaybe(e.df)) + '</td>'
          + '<td class="num">' + escapeHtml(fmtMaybe(e.idf)) + '</td>'
          + '<td class="num">' + escapeHtml(fmtMaybe(e.norm)) + '</td>'
          + '<td class="num">' + escapeHtml(fmtMaybe(e.score)) + '</td>'
          + '</tr>';
      }
      html += '</tbody></table></details>';
    }
    html += '</article>';
    return html;
  }

  function fmtMaybe(v) {
    if (v == null) return '-';
    var n = Number(v);
    if (!isFinite(n)) return String(v);
    return Number.isInteger(n) ? String(n) : n.toFixed(3);
  }

  function renderFacets(facets) {
    var root = $('facets');
    var keys = facets && typeof facets === 'object' ? Object.keys(facets) : [];
    // remember which field:value pairs still exist, so selected-but-absent
    // chips stay visible and deselectable
    var present = {};
    if (keys.length) {
      var html = '';
      for (var i = 0; i < keys.length; i++) {
        var field = keys[i];
        var list = Array.isArray(facets[field]) ? facets[field] : [];
        present[field] = {};
        html += '<div class="facet-group"><div class="facet-title">' + escapeHtml(field) + '</div><div class="chips">';
        for (var j = 0; j < list.length; j++) {
          var pair = list[j];
          if (!pair) continue;
          var val = String(pair[0]);
          var cnt = pair[1];
          present[field][val] = true;
          html += chipHtml(field, val, cnt, true);
        }
        html += '</div></div>';
      }
      // re-add selected values that vanished from the response
      for (var f2 in state.filters) {
        if (!Object.prototype.hasOwnProperty.call(state.filters, f2)) continue;
        if (!present[f2]) { /* field not in response */ }
        var missing = [];
        state.filters[f2].forEach(function (v) {
          if (!present[f2] || !present[f2][v]) missing.push(v);
        });
        if (missing.length) {
          html += '<div class="facet-group"><div class="facet-title">' + escapeHtml(f2) + '</div><div class="chips">';
          for (var m = 0; m < missing.length; m++) html += chipHtml(f2, missing[m], '–', false);
          html += '</div></div>';
        }
      }
      root.innerHTML = html;
    } else {
      root.innerHTML = '<div class="empty">无分面。</div>';
    }
    updateClearBtn();
  }

  function chipHtml(field, value, count, known) {
    var on = state.filters[field] && state.filters[field].has(value);
    return '<button type="button" class="chip' + (on ? ' on' : '') + '"'
      + ' data-field="' + escapeHtml(field) + '" data-value="' + escapeHtml(value) + '"'
      + (known ? '' : ' data-unknown="1"') + '>'
      + escapeHtml(value) + ' <span class="chip-count">' + escapeHtml(String(count)) + '</span></button>';
  }

  function toggleFilter(field, value) {
    if (!state.filters[field]) state.filters[field] = new Set();
    if (state.filters[field].has(value)) {
      state.filters[field]['delete'](value);
      if (state.filters[field].size === 0) delete state.filters[field];
    } else {
      state.filters[field].add(value);
    }
    updateClearBtn();
  }

  function clearFilters() {
    state.filters = {};
    updateClearBtn();
    if (state.lastQuery) doSearch(); else { $('facets').innerHTML = '<div class="empty">搜索后显示分面。</div>'; }
  }

  /* ---------------------------------------------------------------- suggest */

  function askSuggest(q) {
    api('/suggest?q=' + encodeURIComponent(q)).then(function (res) {
      if (!res.ok || !res.json) { $('suggest').hidden = true; return; }
      var s = res.json.suggestion;
      var fuzzy = Array.isArray(res.json.fuzzy) ? res.json.fuzzy : [];
      var box = $('suggest');
      if (!s) { box.hidden = true; return; }
      var html = '你是不是想搜：<b>' + escapeHtml(s) + '</b>'
        + '<button type="button" data-suggest="' + escapeHtml(s) + '">用此查询</button>';
      if (fuzzy.length) {
        html += ' <span class="hint">候选 ' + fuzzy.slice(0, 6).map(function (f) {
          return escapeHtml(String(f[0])) + '(' + escapeHtml(String(f[1])) + ')';
        }).join(' ') + '</span>';
      }
      box.innerHTML = html;
      box.hidden = false;
    }).catch(function () { $('suggest').hidden = true; });
  }

  /* ------------------------------------------------------------------- aggs */

  function runAggs(fromSearch) {
    var q = ($('q').value || '').trim() || state.lastQuery;
    if (!q) return Promise.resolve();
    var limit = clampLimit($('limit').value);
    var aggs = [];
    var ff = facetFields();
    for (var i = 0; i < ff.length; i++) aggs.push({ type: 'terms', field: ff[i], size: 8 });
    var statsField = ($('agg-stats-field').value || '').trim();
    if (statsField) aggs.push({ type: 'stats', field: statsField });
    var histField = ($('agg-hist-field').value || '').trim();
    var interval = parseInt($('agg-hist-interval').value, 10);
    if (!isFinite(interval) || interval < 1) interval = 1;
    if (histField) aggs.push({ type: 'histogram', field: histField, interval: interval });

    var filters = [];
    for (var field in state.filters) {
      if (!Object.prototype.hasOwnProperty.call(state.filters, field)) continue;
      filters.push({ field: field, values: Array.from(state.filters[field]) });
    }
    var body = { query: q, limit: limit, aggs: aggs, facets: ff, filters: filters };

    var box = $('aggs');
    if (!fromSearch) box.innerHTML = '<div class="empty"><span class="spin"></span> 聚合中…</div>';

    return api('/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }).then(function (res) {
      if (!res.ok) {
        box.innerHTML = '<div class="empty" style="color:var(--err)">聚合失败：' + escapeHtml(describeError(res)) + '</div>';
        return;
      }
      renderAggs((res.json || {}).aggs);
    }).catch(function (err) {
      box.innerHTML = '<div class="empty" style="color:var(--err)">聚合失败：' + escapeHtml(err && err.message ? err.message : String(err)) + '</div>';
    });
  }

  function normBuckets(data) {
    var buckets = data;
    if (data && !Array.isArray(data) && Array.isArray(data.buckets)) buckets = data.buckets;
    if (!Array.isArray(buckets)) return [];
    return buckets.map(function (b) {
      if (Array.isArray(b)) return { key: b[0], count: Number(b[1]) || 0 };
      if (b && typeof b === 'object') return { key: (b.key != null ? b.key : b.value), count: Number(b.count != null ? b.count : b.doc_count) || 0 };
      return { key: String(b), count: 0 };
    });
  }

  function renderAggs(aggs) {
    var root = $('aggs');
    var blocks = [];
    if (!aggs || typeof aggs !== 'object') {
      root.innerHTML = '<div class="empty">无聚合结果。</div>';
      return;
    }
    if (aggs.terms || aggs.stats || aggs.histogram) {
      if (aggs.terms) for (var t in aggs.terms) blocks.push({ kind: 'terms', field: t, data: aggs.terms[t] });
      if (aggs.stats) for (var s in aggs.stats) blocks.push({ kind: 'stats', field: s, data: aggs.stats[s] });
      if (aggs.histogram) for (var h in aggs.histogram) blocks.push({ kind: 'histogram', field: h, data: aggs.histogram[h] });
    } else if (Array.isArray(aggs)) {
      aggs.forEach(function (a) {
        if (!a || typeof a !== 'object') return;
        var kind = a.type || a.kind || (a.stats ? 'stats' : (a.buckets ? 'terms' : 'terms'));
        blocks.push({ kind: kind, field: a.field || a.name || '?', data: (kind === 'stats' && a.stats) ? a.stats : a });
      });
    } else {
      for (var f in aggs) {
        var v = aggs[f];
        if (v && typeof v === 'object' && !Array.isArray(v) && ('avg' in v || 'count' in v)) blocks.push({ kind: 'stats', field: f, data: v });
        else blocks.push({ kind: 'terms', field: f, data: v });
      }
    }
    if (!blocks.length) { root.innerHTML = '<div class="empty">无聚合结果。</div>'; return; }

    var html = '';
    for (var i = 0; i < blocks.length; i++) {
      var b = blocks[i];
      html += '<div class="agg-block">';
      // terms/histogram carry an accidental `field` that may embed a type hint
      var label = String(b.field);
      html += '<div class="agg-block-title"><span class="tag">' + escapeHtml(b.kind) + '</span>' + escapeHtml(label) + '</div>';
      if (b.kind === 'stats') html += statsBlockHtml(b.data);
      else html += barsHtml(normBuckets(b.data), b.kind === 'histogram');
      html += '</div>';
    }
    root.innerHTML = html;
  }

  function barsHtml(buckets, isHist) {
    if (!buckets.length) return '<div class="empty">无桶。</div>';
    var max = 1;
    for (var i = 0; i < buckets.length; i++) max = Math.max(max, buckets[i].count);
    var html = '<div class="bars">';
    for (var j = 0; j < buckets.length; j++) {
      var b = buckets[j];
      var pct = Math.max(1.5, (b.count / max) * 100);
      html += '<div class="bar-row">'
        + '<span class="bar-key" title="' + escapeHtml(b.key) + '">' + escapeHtml(b.key) + '</span>'
        + '<span class="bar-track"><span class="bar-fill' + (isHist ? ' hist' : '') + '" style="width:' + pct.toFixed(1) + '%"></span></span>'
        + '<span class="bar-num">' + escapeHtml(String(b.count)) + '</span>'
        + '</div>';
    }
    html += '</div>';
    return html;
  }

  function statsBlockHtml(stats) {
    var s = stats && typeof stats === 'object' && stats.value && typeof stats.value === 'object' ? stats.value : stats;
    if (!s || typeof s !== 'object') return '<div class="empty">无统计。</div>';
    var cells = [
      ['count', s.count], ['min', s.min], ['max', s.max], ['avg', s.avg], ['sum', s.sum]
    ];
    var html = '<div class="stats-grid">';
    for (var i = 0; i < cells.length; i++) {
      var v = cells[i][1];
      var shown = (v == null) ? '-' : (typeof v === 'number' ? formatNum(v, '') : v);
      html += '<div class="cell"><div class="lbl">' + escapeHtml(cells[i][0]) + '</div><div class="val">' + escapeHtml(String(shown)) + '</div></div>';
    }
    html += '</div>';
    return html;
  }

  /* ----------------------------------------------------------------- ingest */

  var parsedDocs = null;   // { docs: [ {id, fields, facets?, nums?} ] }

  function readFileText(file) {
    return new Promise(function (resolve, reject) {
      var reader = new FileReader();
      reader.onload = function () { resolve(String(reader.result)); };
      reader.onerror = function () { reject(reader.error || new Error('读取失败：' + file.name)); };
      reader.readAsText(file);
    });
  }

  function parseCsvLine(line) {
    var out = [], cur = '', inQ = false, i = 0;
    while (i < line.length) {
      var c = line.charAt(i);
      if (inQ) {
        if (c === '"') {
          if (line.charAt(i + 1) === '"') { cur += '"'; i += 2; continue; }
          inQ = false; i++; continue;
        }
        cur += c; i++; continue;
      }
      if (c === '"') { inQ = true; i++; continue; }
      if (c === ',') { out.push(cur); cur = ''; i++; continue; }
      cur += c; i++;
    }
    out.push(cur);
    return out;
  }

  function isIdentCell(s) { return /^[A-Za-z_][A-Za-z0-9_]*$/.test(String(s).trim()); }

  function normalizeJsonDoc(obj, fallbackId) {
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return null;
    if (obj.fields && typeof obj.fields === 'object' && !Array.isArray(obj.fields)) {
      var d = { id: String(obj.id != null ? obj.id : fallbackId) };
      d.fields = obj.fields;
      if (obj.facets) d.facets = obj.facets;
      if (obj.nums) d.nums = obj.nums;
      return d;
    }
    var fields = {}, has = false;
    for (var k in obj) {
      if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
      if (k === 'id') continue;
      var v = obj[k];
      if (v == null) continue;
      fields[k] = typeof v === 'string' ? v : JSON.stringify(v);
      has = true;
    }
    if (!has) return null;
    return { id: String(obj.id != null ? obj.id : fallbackId), fields: fields };
  }

  function parseFileToDocs(name, text) {
    var lower = name.toLowerCase();
    var docs = [];
    if (/\.jsonl$/.test(lower)) {
      var lines = text.split(/\r?\n/);
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line) continue;
        var parsed;
        try { parsed = JSON.parse(line); } catch (e) { throw new Error('第 ' + (i + 1) + ' 行不是合法 JSON'); }
        var d = normalizeJsonDoc(parsed, name + '#' + docs.length);
        if (d) docs.push(d);
      }
      return docs;
    }
    if (/\.json$/.test(lower)) {
      var root;
      try { root = JSON.parse(text); } catch (e) {
        // tolerate a JSONL body mis-named .json
        var ls = text.split(/\r?\n/).filter(function (x) { return x.trim(); });
        for (var k = 0; k < ls.length; k++) {
          var p; try { p = JSON.parse(ls[k]); } catch (e2) { throw new Error('不是合法 JSON'); }
          var dd = normalizeJsonDoc(p, name + '#' + k); if (dd) docs.push(dd);
        }
        return docs;
      }
      if (Array.isArray(root)) {
        for (var m = 0; m < root.length; m++) { var e3 = normalizeJsonDoc(root[m], name + '#' + m); if (e3) docs.push(e3); }
      } else {
        var one = normalizeJsonDoc(root, name);
        if (one) docs.push(one);
      }
      return docs;
    }
    if (/\.csv$/.test(lower)) {
      var rows = text.split(/\r?\n/).filter(function (r) { return r.trim().length > 0; });
      if (!rows.length) return docs;
      var first = parseCsvLine(rows[0]);
      var header = first.length > 1 && first.every(isIdentCell);
      var cols = header ? first : first.map(function (_, idx) { return 'f' + idx; });
      var start = header ? 1 : 0;
      var idIdx = cols.findIndex(function (c) { return c.toLowerCase() === 'id'; });
      for (var r = start; r < rows.length; r++) {
        var cells = parseCsvLine(rows[r]);
        var fields = {}, any = false;
        for (var c = 0; c < cols.length; c++) {
          var val = cells[c] == null ? '' : cells[c];
          if (c === idIdx) continue;
          if (val !== '') { fields[cols[c]] = val; any = true; }
        }
        var id = idIdx >= 0 && cells[idIdx] ? cells[idIdx] : (name + '#' + (r - start + 1));
        if (any) docs.push({ id: String(id), fields: fields });
      }
      return docs;
    }
    // .md / .txt (and anything else): whole file as `desc`, filename as `title`
    docs.push({ id: name, fields: { title: name, desc: text } });
    return docs;
  }

  function prepareIngest() {
    var files = $('ingest-files').files;
    if (!files || !files.length) { toast('请先选择文件'); return Promise.resolve(null); }
    var listHtml = '';
    var all = [];
    var seq = Promise.resolve();
    var read = [];
    Array.prototype.forEach.call(files, function (file, idx) {
      read.push(readFileText(file).then(function (text) {
        var docs;
        try {
          docs = parseFileToDocs(file.name, text);
          listHtml += '<div class="file-row"><span class="fname">' + escapeHtml(file.name) + '</span>'
            + '<span class="fmeta fok">' + escapeHtml(String(docs.length)) + ' 条</span></div>';
        } catch (e) {
          listHtml += '<div class="file-row"><span class="fname">' + escapeHtml(file.name) + '</span>'
            + '<span class="fmeta fbad">' + escapeHtml(String(e.message || e)) + '</span></div>';
          return;
        }
        for (var i = 0; i < docs.length; i++) all.push(docs[i]);
      }));
    });
    $('ingest-files-list').innerHTML = '';
    $('ingest-status').textContent = '解析中…';
    return Promise.all(read).then(function () {
      $('ingest-files-list').innerHTML = listHtml;
      $('ingest-status').textContent = '已解析 ' + files.length + ' 个文件 / ' + all.length + ' 条文档';
      return all;
    });
  }

  function ingestUpload() {
    prepareIngest().then(function (docs) {
      if (docs == null) return;
      if (!docs.length) { toast('没有可索引的文档'); $('ingest-status').textContent = '没有可索引的文档'; return; }
      var chunkSize = 500;
      var chunks = [];
      for (var i = 0; i < docs.length; i += chunkSize) chunks.push(docs.slice(i, i + chunkSize));
      var sent = 0, indexed = 0, tookTotal = 0;
      $('ingest-progress').hidden = false;
      $('ingest-result').innerHTML = '';
      var run = Promise.resolve();
      chunks.forEach(function (chunk, ci) {
        run = run.then(function () {
          var body = chunk.map(function (d) { return JSON.stringify(d); }).join('\n');
          return api('/index/bulk', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-ndjson; charset=utf-8' },
            body: body
          }).then(function (res) {
            if (!res.ok) { throw new Error('块 ' + (ci + 1) + ' 失败：' + describeError(res)); }
            var data = res.json || {};
            indexed += Number(data.indexed || 0);
            tookTotal += Number(data.took_ms || 0);
            sent += chunk.length;
            var pct = (sent / docs.length) * 100;
            $('ingest-bar').style.width = pct.toFixed(1) + '%';
            $('ingest-status').textContent = '已上传 ' + sent + ' / ' + docs.length + ' 条 · 已索引 ' + indexed + ' 条';
          });
        });
      });
      run.then(function () {
        $('ingest-result').innerHTML = '<span style="color:var(--accent)">完成</span>：索引 <b>' + escapeHtml(String(indexed)) + '</b> 条 · '
          + '服务端耗时 <b>' + escapeHtml(tookTotal.toFixed(2)) + '</b> ms · 共 ' + escapeHtml(String(chunks.length)) + ' 次请求';
        toast('索引完成：' + indexed + ' 条', 'ok');
        refreshStats();
      }).catch(function (err) {
        $('ingest-result').innerHTML = '<span style="color:var(--err)">' + escapeHtml(err && err.message ? err.message : String(err)) + '</span>';
        toast('索引失败：' + (err && err.message ? err.message : String(err)));
      });
    }).catch(function (err) { toast('读取文件失败：' + (err && err.message ? err.message : String(err))); });
  }

  /* ----------------------------------------------------------------- events */

  $('connect').addEventListener('click', connect);
  $('base').addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); connect(); } });
  $('search-btn').addEventListener('click', doSearch);
  $('q').addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); doSearch(); } });
  $('agg-run').addEventListener('click', function () { runAggs(false); });
  $('clear-filters').addEventListener('click', clearFilters);
  $('ingest-run').addEventListener('click', ingestUpload);
  $('ingest-files').addEventListener('change', prepareIngest);

  $('facet-fields').addEventListener('change', function () { if (state.lastQuery) doSearch(); });

  $('facets').addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('.chip') : null;
    if (!btn) return;
    var field = btn.getAttribute('data-field');
    var value = btn.getAttribute('data-value');
    if (field == null || value == null) return;
    toggleFilter(field, value);
    if (state.lastQuery) doSearch();
    else { renderFacets({}); }
  });

  $('suggest').addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('button[data-suggest]') : null;
    if (!btn) return;
    $('q').value = btn.getAttribute('data-suggest') || '';
    doSearch();
  });

  document.addEventListener('keydown', function (e) {
    var t = e.target;
    var typing = t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
    if (e.key === '/' && !typing) { e.preventDefault(); $('q').focus(); $('q').select(); return; }
    if (e.key === 'Escape') {
      if (t === $('q') || !typing) { $('q').value = ''; $('suggest').hidden = true; }
    }
  });

  window.addEventListener('error', function (e) {
    toast('页面错误：' + (e && e.message ? e.message : '未知'));
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e && e.reason;
    toast('未处理的异步错误：' + (r && r.message ? r.message : String(r)));
  });

  /* ------------------------------------------------------------------- boot */

  var bootBase = initialBase();
  if (bootBase) $('base').value = bootBase;
  connect();

  // expose a tiny hook so automated tests / operators can drive the console
  window.moonseekConsole = {
    state: state,
    connect: connect,
    search: doSearch,
    setBase: function (u) { $('base').value = u; state.base = normalizeBase(u); },
    runAggs: function () { return runAggs(false); },
    escapeHtml: escapeHtml,
    safeSnippet: safeSnippet
  };
})();
