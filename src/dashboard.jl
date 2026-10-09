# ─────────────────────────────────────────────────────────────────────────────
# Statisches Dashboard (Port von plot_dashboard.R) als abhängigkeitsfreies SVG
#
# Panels, Beschriftungen und Kennzahlen entsprechen dem R-Paket. Wie im
# R-Original rechnet das Statistik-Panel eine vereinfachte „Sharpe Ratio“
# (CAGR − 2 %) / (σ · √252), und die Währungsachse ist standardmäßig mit „$“
# beschriftet (`currency` ändert das Symbol).
# ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_COLORS = Dict("primary" => "#2E86AB", "secondary" => "#A23B72", "positive" => "#06A77D",
                            "negative" => "#D62246", "neutral" => "#6C757D", "background" => "#F8F9FA",
                            "grid" => "#E9ECEF")
const _MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

"""
    SimLevDashboard

Ein gerendertes Dashboard (SVG). Wird in Jupyter, Pluto und VS Code direkt
angezeigt; `write(path, d)` bzw. [`export_dashboard`](@ref) speichern es.
"""
struct SimLevDashboard
    svg::String
end
Base.show(io::IO, ::MIME"image/svg+xml", d::SimLevDashboard) = print(io, d.svg)
Base.show(io::IO, d::SimLevDashboard) = print(io, "SimLevDashboard(SVG, ", sizeof(d.svg), " Bytes)")
Base.write(io::IO, d::SimLevDashboard) = write(io, d.svg)

"Nachbildung von R's `pretty()` (Algorithmus aus R's src/appl/pretty.c)."
function r_pretty(lo::Float64, hi::Float64, n::Int = 5)
    (isfinite(lo) && isfinite(hi)) || return [0.0]
    hi < lo && ((lo, hi) = (hi, lo))
    h = 1.5; h5 = 0.5 + 1.5 * h
    epsv = 1e-10
    min_n = n ÷ 3
    dx = hi - lo
    local cell::Float64
    if dx == 0 && hi == 0
        cell = 1.0; i_small = true
    else
        cell = max(abs(lo), abs(hi))
        u = 1 + (h5 >= 1.5 * h + 0.5 ? 1 / (1 + h) : 1.5 / (1 + h5))
        u *= max(1, n) * eps(Float64)
        i_small = dx < cell * u * 3
    end
    if i_small
        cell > 10 && (cell = 9 + cell / 10)
        cell *= 0.75
        min_n > 1 && (cell /= min_n)
    else
        cell = dx
        n > 1 && (cell /= n)
    end
    base = 10.0^floor(log10(cell))
    unit = base
    if 2 * base - cell < h * (cell - unit)
        unit = 2 * base
        if 5 * base - cell < h5 * (cell - unit)
            unit = 5 * base
            10 * base - cell < h * (cell - unit) && (unit = 10 * base)
        end
    end
    ns = floor(lo / unit + epsv)
    nu = ceil(hi / unit - epsv)
    while ns * unit > lo + epsv * unit
        ns -= 1
    end
    while nu * unit < hi - epsv * unit
        nu += 1
    end
    k = Int(floor(0.5 + nu - ns))
    if k < min_n
        k = min_n - k
        if ns >= 0
            nu += k ÷ 2; ns -= k ÷ 2 + k % 2
        else
            ns -= k ÷ 2; nu += k ÷ 2 + k % 2
        end
    end
    return [i * unit for i in ns:nu]
end

_fmt_currency(x, sym) = abs(x) >= 1e6 ? rsprintf("%s%.1fM", sym, x / 1e6) :
                        abs(x) >= 1e3 ? rsprintf("%s%.0fK", sym, x / 1e3) : rsprintf("%s%.0f", sym, x)
_sg(v) = isnan(v) ? "NA" : rsprintf("%+.2f", v)
_p2(v) = isnan(v) ? "NA" : rsprintf("%.2f", v)
_esc(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
_c(x) = rsprintf("%.1f", x)

# ── Minimaler SVG-Zeichenkontext ────────────────────────────────────────────
mutable struct _Canvas
    io::IOBuffer
end
_svg!(c::_Canvas, s::AbstractString) = (print(c.io, s, "\n"); nothing)
_text!(c, x, y, s; size = 11, color = "#333", anchor = "start", weight = "normal", baseline = "middle", rot = 0, halo = false) =
    _svg!(c, "<text x=\"$(_c(x))\" y=\"$(_c(y))\" font-size=\"$size\" fill=\"$color\" text-anchor=\"$anchor\" " *
             "font-weight=\"$weight\" dominant-baseline=\"$baseline\"" *
             (halo ? " stroke=\"white\" stroke-width=\"3\" paint-order=\"stroke\" stroke-linejoin=\"round\"" : "") *
             (rot != 0 ? " transform=\"rotate($rot $(_c(x)) $(_c(y)))\"" : "") * ">$(_esc(s))</text>")
_line!(c, x1, y1, x2, y2; color = "#999", width = 1, dash = "") =
    _svg!(c, "<line x1=\"$(_c(x1))\" y1=\"$(_c(y1))\" x2=\"$(_c(x2))\" y2=\"$(_c(y2))\" stroke=\"$color\" " *
             "stroke-width=\"$width\"" * (isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") * "/>")
_rect!(c, x, y, w, h; fill = "none", stroke = "none", sw = 1, opacity = 1) =
    _svg!(c, "<rect x=\"$(_c(x))\" y=\"$(_c(y))\" width=\"$(_c(w))\" height=\"$(_c(h))\" fill=\"$fill\" " *
             "stroke=\"$stroke\" stroke-width=\"$sw\"" * (opacity < 1 ? " fill-opacity=\"$opacity\"" : "") * "/>")
_hexalpha(a::AbstractString) = parse(Int, a; base = 16) / 255

"Ein Plot-Bereich mit linearer Abbildung von Daten- auf Bildkoordinaten."
struct _Panel
    x0::Float64; y0::Float64; w::Float64; h::Float64
    xlo::Float64; xhi::Float64; ylo::Float64; yhi::Float64
end
_px(p::_Panel, x) = p.x0 + (x - p.xlo) / (p.xhi == p.xlo ? 1.0 : p.xhi - p.xlo) * p.w
_py(p::_Panel, y) = p.y0 + p.h - (y - p.ylo) / (p.yhi == p.ylo ? 1.0 : p.yhi - p.ylo) * p.h

# Ausdünnung langer Reihen für die Darstellung (Min/Max je Bildspalte)
function _decimate(xs::Vector{Float64}, ys::Vector{Float64}, maxn::Int = 1600)
    n = length(xs)
    n <= maxn && return xs, ys
    bucket = ceil(Int, n / (maxn ÷ 2))
    ox = Float64[]; oy = Float64[]
    for s in 1:bucket:n
        e = min(n, s + bucket - 1)
        seg = s:e
        vals = ys[seg]
        good = findall(isfinite, vals)
        isempty(good) && continue
        imin = seg[good[argmin(vals[good])]]; imax = seg[good[argmax(vals[good])]]
        for i in sort(unique([imin, imax]))
            push!(ox, xs[i]); push!(oy, ys[i])
        end
    end
    return ox, oy
end

function _path(p::_Panel, xs, ys)
    io = IOBuffer(); first = true
    for (x, y) in zip(xs, ys)
        if !isfinite(y)
            first = true; continue
        end
        print(io, first ? "M" : "L", _c(_px(p, x)), " ", _c(_py(p, y)))
        first = false
    end
    return String(take!(io))
end
_polyline!(c, p, xs, ys; color, width = 1.5, dash = "") =
    _svg!(c, "<path d=\"$(_path(p, xs, ys))\" fill=\"none\" stroke=\"$color\" stroke-width=\"$width\" stroke-linejoin=\"round\"" *
             (isempty(dash) ? "" : " stroke-dasharray=\"$dash\"") * "/>")
function _area!(c, p, xs, ys, base; color, opacity)
    d = _path(p, xs, ys)
    isempty(d) && return
    _svg!(c, "<path d=\"$d L$(_c(_px(p, xs[end]))) $(_c(_py(p, base))) L$(_c(_px(p, xs[1]))) $(_c(_py(p, base))) Z\" " *
             "fill=\"$color\" fill-opacity=\"$(round(opacity; digits = 3))\" stroke=\"none\"/>")
end

# Datums-Achse: Jahres- oder Monatsmarken
function _date_ticks(z0::Float64, z1::Float64)
    d0 = from_days(Int(floor(z0))); d1 = from_days(Int(ceil(z1)))
    years = Dates.year(d1) - Dates.year(d0)
    ticks = Tuple{Float64,String}[]
    if years >= 2
        step = years <= 8 ? 1 : years <= 16 ? 2 : years <= 40 ? 5 : 10
        for y in Dates.year(d0):Dates.year(d1)
            (y % step == 0) || continue
            z = Float64(days_from_civil(y, 1, 1))
            z0 <= z <= z1 && push!(ticks, (z, string(y)))
        end
    else
        months = 12 * years + Dates.month(d1) - Dates.month(d0)
        step = months <= 8 ? 1 : months <= 16 ? 2 : months <= 30 ? 3 : 6
        y, m = Dates.year(d0), Dates.month(d0)
        while true
            z = Float64(days_from_civil(y, m, 1))
            z > z1 && break
            ((m - 1) % step == 0 && z >= z0) && push!(ticks, (z, rsprintf("%s %d", _MONTHS[m], y)))
            m += 1; m > 12 && (m = 1; y += 1)
        end
    end
    return ticks
end

function _frame!(c, p::_Panel, col; title = "", xlabel = "", ylabel = "", yticks = Float64[], ylabels = String[],
                 xticks = Tuple{Float64,String}[], grid = true)
    _rect!(c, p.x0, p.y0, p.w, p.h; fill = "white", stroke = "#CED4DA", sw = 0.8)
    if grid
        for t in yticks
            p.ylo <= t <= p.yhi && _line!(c, p.x0, _py(p, t), p.x0 + p.w, _py(p, t); color = col["grid"], width = 0.8)
        end
        for (t, _) in xticks
            _line!(c, _px(p, t), p.y0, _px(p, t), p.y0 + p.h; color = col["grid"], width = 0.8)
        end
    end
    for (t, l) in zip(yticks, ylabels)
        p.ylo <= t <= p.yhi && _text!(c, p.x0 - 6, _py(p, t), l; size = 10, color = "#495057", anchor = "end")
    end
    for (t, l) in xticks
        _text!(c, _px(p, t), p.y0 + p.h + 14, l; size = 10, color = "#495057", anchor = "middle")
    end
    isempty(title) || _text!(c, p.x0 + p.w / 2, p.y0 - 16, title; size = 15, color = col["primary"], anchor = "middle", weight = "bold")
    isempty(xlabel) || _text!(c, p.x0 + p.w / 2, p.y0 + p.h + 32, xlabel; size = 11, color = "#495057", anchor = "middle")
    isempty(ylabel) || _text!(c, p.x0 - 54, p.y0 + p.h / 2, ylabel; size = 11, color = "#495057", anchor = "middle", rot = -90)
end

_finite_range(v) = (f = filter(isfinite, v); isempty(f) ? (0.0, 1.0) : (minimum(f), maximum(f)))

function _ylim(lo, hi)
    lo == hi && return (lo - 1, hi + 1)
    pad = (hi - lo) * 0.04
    return (lo - pad, hi + pad)
end

# ── Panels ──────────────────────────────────────────────────────────────────

function _panel_performance(c, cell, x, col, compare, currency)
    xs = Float64.(to_days.(x.dates)); ys = x.worth
    lo, hi = _finite_range(ys)
    if compare !== nothing
        l2, h2 = _finite_range(compare.worth); lo = min(lo, l2); hi = max(hi, h2)
    end
    ticks = r_pretty(lo, hi)
    ylo, yhi = _ylim(min(lo, ticks[1]), max(hi, ticks[end]))
    p = _Panel(cell..., xs[1], xs[end] == xs[1] ? xs[1] + 1 : xs[end], ylo, yhi)
    _frame!(c, p, col; title = "Portfolio Performance", ylabel = "Portfolio Value", yticks = ticks,
            ylabels = [_fmt_currency(t, currency) for t in ticks], xticks = _date_ticks(p.xlo, p.xhi))
    dx, dy = _decimate(xs, ys)
    _area!(c, p, dx, dy, lo; color = col["primary"], opacity = _hexalpha("30"))
    _polyline!(c, p, dx, dy; color = col["primary"], width = 2.5)
    if compare !== nothing
        cx, cy = _decimate(Float64.(to_days.(compare.dates)), compare.worth)
        _polyline!(c, p, cx, cy; color = col["secondary"], width = 2.5, dash = "8,5")
        _rect!(c, p.x0 + 10, p.y0 + 8, 120, 40; fill = "white", stroke = col["grid"])
        _line!(c, p.x0 + 18, p.y0 + 20, p.x0 + 40, p.y0 + 20; color = col["primary"], width = 2.5)
        _text!(c, p.x0 + 46, p.y0 + 20, "Strategy 1"; size = 10)
        _line!(c, p.x0 + 18, p.y0 + 36, p.x0 + 40, p.y0 + 36; color = col["secondary"], width = 2.5, dash = "6,4")
        _text!(c, p.x0 + 46, p.y0 + 36, "Strategy 2"; size = 10)
    end
    _text!(c, _px(p, xs[end]) - 4, _py(p, ys[end]) - 14, _fmt_currency(ys[end], currency);
           size = 11, color = col["primary"], anchor = "end", weight = "bold", halo = true)
end

function _panel_drawdown(c, cell, x, col)
    xs = Float64.(to_days.(x.dates)); dd = -100 .* x.drawdowns
    lo, _ = _finite_range(dd)
    lo = lo < 0 ? lo * 1.1 : -1.0
    ticks = r_pretty(lo, 0.0)
    p = _Panel(cell..., xs[1], xs[end] == xs[1] ? xs[1] + 1 : xs[end], min(lo, ticks[1]), 0.0)
    _frame!(c, p, col; title = "Drawdown Analysis", ylabel = "Drawdown (%)", yticks = ticks,
            ylabels = [rsprintf("%g", t) for t in ticks], xticks = _date_ticks(p.xlo, p.xhi))
    dx, dy = _decimate(xs, dd)
    _area!(c, p, dx, dy, 0.0; color = col["negative"], opacity = _hexalpha("40"))
    _polyline!(c, p, dx, dy; color = col["negative"], width = 2)
    mdd = maximum(filter(isfinite, x.drawdowns); init = 0.0) * 100
    _line!(c, p.x0, _py(p, -mdd), p.x0 + p.w, _py(p, -mdd); color = col["negative"], width = 1.5, dash = "6,4")
    _text!(c, p.x0 + 6, _py(p, -mdd) - 8, rsprintf("Max: %.1f%%", mdd); size = 10, color = col["negative"], weight = "bold", halo = true)
end

function _panel_distribution(c, cell, x, col)
    w = x.worth
    rets = Float64[]
    for i in 2:length(w)
        v = (log(w[i] > 0 ? w[i] : NaN) - log(w[i-1] > 0 ? w[i-1] : NaN)) * 100
        isfinite(v) && push!(rets, v)
    end
    title = "Daily Returns Distribution"
    if length(rets) <= 1
        p = _Panel(cell..., 0.0, 1.0, 0.0, 1.0)
        _frame!(c, p, col; title = title, xlabel = "Daily Return (%)", ylabel = "Frequency")
        return
    end
    lo, hi = minimum(rets), maximum(rets)
    br = r_pretty(lo, hi, 50)
    length(br) < 2 && (br = collect(range(lo, hi; length = 51)))
    counts = zeros(Int, length(br) - 1)
    for r in rets
        k = searchsortedlast(br, r)
        k = clamp(r == br[1] ? 1 : (r == br[k] ? k - 1 : k), 1, length(counts))
        counts[k] += 1
    end
    mu, sd = r_mean(rets), r_sd(rets)
    xs = collect(range(lo, hi; length = 100))
    bw = br[2] - br[1]     # Normalverteilung auf die tatsächliche Klassenbreite skaliert
    yn = sd > 0 ? [exp(-0.5 * ((v - mu) / sd)^2) / (sd * sqrt(2π)) * length(rets) * bw for v in xs] : Float64[]
    ymax = max(maximum(counts), isempty(yn) ? 0.0 : maximum(yn))
    yt = r_pretty(0.0, Float64(ymax))
    p = _Panel(cell..., br[1], br[end], 0.0, max(yt[end], ymax))
    xt = r_pretty(br[1], br[end])
    _frame!(c, p, col; title = title, xlabel = "Daily Return (%)", ylabel = "Frequency", yticks = yt,
            ylabels = [rsprintf("%g", t) for t in yt], xticks = [(t, rsprintf("%g", t)) for t in xt if br[1] <= t <= br[end]])
    for k in eachindex(counts)
        counts[k] == 0 && continue
        x1, x2 = _px(p, br[k]), _px(p, br[k+1])
        _rect!(c, x1, _py(p, counts[k]), x2 - x1, _py(p, 0) - _py(p, counts[k]);
               fill = col["primary"], stroke = col["primary"], sw = 0.6, opacity = _hexalpha("80"))
    end
    isempty(yn) || _polyline!(c, p, xs, yn; color = col["secondary"], width = 2, dash = "6,4")
    _line!(c, _px(p, mu), p.y0, _px(p, mu), p.y0 + p.h; color = col["positive"], width = 2, dash = "6,4")
    s = x.statistics
    for (i, t) in enumerate((rsprintf("Mean: %.2f%%", mu), rsprintf("SD: %.2f%%", sd), "Skew: " * _p2(s.skewness),
                             "Kurt: " * _p2(s.kurtosis)))
        _text!(c, p.x0 + p.w - 8, p.y0 + 12 + 14 * (i - 1), t; size = 10, color = col["primary"], anchor = "end", halo = true)
    end
end

function _panel_rolling(c, cell, x, col, window)
    w = x.worth; n = length(w)
    xs = Float64.(to_days.(x.dates))
    idx = window:n
    rr = [((w[i] / w[i-window+1])^(252 / window) - 1) * 100 for i in idx]
    rx = xs[idx]
    lo, hi = _finite_range(rr)
    !isnan(x.cagr) && ((lo, hi) = (min(lo, x.cagr * 100), max(hi, x.cagr * 100)))
    lo, hi = min(lo, 0.0), max(hi, 0.0)
    ticks = r_pretty(lo, hi)
    p = _Panel(cell..., rx[1], rx[end] == rx[1] ? rx[1] + 1 : rx[end], min(lo, ticks[1]), max(hi, ticks[end]))
    _frame!(c, p, col; title = rsprintf("%d-Day Rolling Returns (Annualized)", window), ylabel = "Annualized Return (%)",
            yticks = ticks, ylabels = [rsprintf("%g", t) for t in ticks], xticks = _date_ticks(p.xlo, p.xhi))
    _line!(c, p.x0, _py(p, 0), p.x0 + p.w, _py(p, 0); color = col["neutral"], width = 1, dash = "6,4")
    dx, dy = _decimate(rx, rr)
    # Abschnitte nach Vorzeichen einfärben
    k = 1
    while k <= length(dx)
        sgn = dy[k] >= 0
        j = k
        while j < length(dx) && (dy[j+1] >= 0) == sgn
            j += 1
        end
        seg = k:min(j + 1, length(dx))
        _polyline!(c, p, dx[seg], dy[seg]; color = sgn ? col["positive"] : col["negative"], width = 1.5)
        k = j + 1
    end
    if !isnan(x.cagr)
        cg = x.cagr * 100
        _line!(c, p.x0, _py(p, cg), p.x0 + p.w, _py(p, cg); color = col["primary"], width = 1.5, dash = "6,4")
        _text!(c, p.x0 + 6, _py(p, cg) - 8, rsprintf("CAGR: %.1f%%", cg); size = 10, color = col["primary"], weight = "bold", halo = true)
    end
end

function _blend(c1::String, c2::String, t::Float64)
    a = [parse(Int, c1[i:i+1]; base = 16) for i in (2, 4, 6)]
    b = [parse(Int, c2[i:i+1]; base = 16) for i in (2, 4, 6)]
    m = [round(Int, a[k] + (b[k] - a[k]) * t) for k in 1:3]
    return "#" * join(string.(m; base = 16, pad = 2))
end

function _panel_monthly(c, cell, x, col)
    groups = Dict{Tuple{Int,Int},Vector{Float64}}()
    for (d, v) in zip(x.dates, x.worth)
        push!(get!(groups, (Dates.year(d), Dates.month(d)), Float64[]), v)
    end
    years = sort(unique(k[1] for k in keys(groups)))
    ny = length(years)
    x0, y0, w, h = cell
    _text!(c, x0 + w / 2, y0 - 16, "Monthly Returns Heatmap"; size = 15, color = col["primary"], anchor = "middle", weight = "bold")
    cw = w / 12; ch = h / max(ny, 1)
    for (yi, y) in enumerate(years), m in 1:12
        vals = get(groups, (y, m), Float64[])
        cx = x0 + (m - 1) * cw; cy = y0 + h - yi * ch
        _rect!(c, cx, cy, cw, ch; fill = "white", stroke = col["grid"], sw = 0.5)
        length(vals) > 1 || continue
        v = (vals[end] / vals[1] - 1) * 100
        isfinite(v) || continue
        bin = clamp(floor(Int, v + 10), 0, 19)        # 20 Klassen auf [-10, 10]; außerhalb: Randklasse
        t = (bin + 0.5) / 20
        fillc = t < 0.5 ? _blend(col["negative"], "#FFFFFF", t / 0.5) : _blend("#FFFFFF", col["positive"], (t - 0.5) / 0.5)
        _rect!(c, cx, cy, cw, ch; fill = fillc, stroke = col["grid"], sw = 0.5)
        ny <= 30 && _text!(c, cx + cw / 2, cy + ch / 2, rsprintf("%.1f", v); size = ny > 15 ? 7 : 8,
                           color = abs(v) > 5 ? "white" : "black", anchor = "middle")
    end
    for m in 1:12
        _text!(c, x0 + (m - 0.5) * cw, y0 + h + 14, _MONTHS[m]; size = 10, color = "#495057", anchor = "middle")
    end
    step = ny > 20 ? ceil(Int, ny / 20) : 1
    for (yi, y) in enumerate(years)
        (yi - 1) % step == 0 && _text!(c, x0 - 6, y0 + h - (yi - 0.5) * ch, string(y); size = 10, color = "#495057", anchor = "end")
    end
    _text!(c, x0 + w / 2, y0 + h + 32, "Month"; size = 11, color = "#495057", anchor = "middle")
    _text!(c, x0 - 54, y0 + h / 2, "Year"; size = 11, color = "#495057", anchor = "middle", rot = -90)
end

function _panel_stats(c, cell, x, col, compare, currency)
    x0, y0, w, h = cell
    _text!(c, x0 + w / 2, y0 - 16, "Performance Statistics"; size = 15, color = col["primary"], anchor = "middle", weight = "bold")
    _rect!(c, x0 + 0.02w, y0 + 0.02h, 0.96w, 0.96h; stroke = col["grid"], sw = 2)
    s = x.statistics
    worth = x.worth
    sd252 = s.sd * sqrt(252)
    sharpe_simple = sd252 != 0 ? (x.cagr - 0.02) / sd252 : NaN
    total_ret = (worth[end] / worth[1] - 1) * 100
    mdd = maximum(filter(isfinite, x.drawdowns); init = 0.0) * 100
    sections = Pair{String,Vector{String}}[
        "Performance Metrics" => ["CAGR: " * _sg(x.cagr * 100) * "%", "TTWROR: " * _sg(x.ttwror * 100) * "%",
                                  "Total Return: " * _sg(total_ret) * "%"],
        "Risk Metrics" => [rsprintf("Max Drawdown: %.2f%%", mdd), rsprintf("Daily Volatility: %.2f%%", s.sd * 100),
                           rsprintf("Ann. Volatility: %.2f%%", sd252 * 100)],
        "Return Profile" => ["Sharpe Ratio: " * _p2(sharpe_simple), "Skewness: " * _p2(s.skewness),
                             "Kurtosis: " * _p2(s.kurtosis)],
        "Portfolio Info" => ["Start Value: " * _fmt_currency(worth[1], currency), "End Value: " * _fmt_currency(worth[end], currency),
                             rsprintf("Duration: %d days", length(worth))]]
    if compare !== nothing
        cw = compare.worth
        push!(sections, "Comparison" => ["CAGR Diff: " * _sg((x.cagr - compare.cagr) * 100) * "%",
                                         "Return Diff: " * _sg((worth[end] / worth[1] - cw[end] / cw[1]) * 100) * "%",
                                         "Vol Diff: " * _sg((s.sd - compare.statistics.sd) * sqrt(252) * 100) * "%"])
    end
    ns = length(sections)
    half = cld(ns, 2)
    cols_ = [sections[1:half], sections[half+1:end]]
    nl = maximum(sum(1 + length(r.second) for r in cs; init = 0) + 0.6 * max(length(cs) - 1, 0) for cs in cols_)
    lh = min(19.0, 0.86h / nl)
    fs = clamp(lh * 0.68, 8.5, 12.5)
    for (ci, cs) in enumerate(cols_)
        xx = x0 + (ci == 1 ? 0.06w : 0.53w)
        yy = y0 + 0.08h + lh / 2
        for (name, rows) in cs
            _text!(c, xx, yy, name; size = fs + 1.5, color = col["primary"], weight = "bold")
            yy += lh
            for r in rows
                _text!(c, xx + 12, yy, r; size = fs, color = col["neutral"])
                yy += lh
            end
            yy += 0.6lh
        end
    end
end

function _panel_correlation(c, cell, col)
    x0, y0, w, h = cell
    _text!(c, x0 + w / 2, y0 - 16, "Asset Correlation Matrix"; size = 15, color = col["primary"], anchor = "middle", weight = "bold")
    _text!(c, x0 + w / 2, y0 + h / 2, "Requires asset-level price data"; size = 13, color = col["neutral"], anchor = "middle")
end

function _panel_comparison(c, cell, x, compare, col)
    x0, y0, w, h = cell
    _text!(c, x0 + w / 2, y0 - 16, "Strategy Comparison"; size = 15, color = col["primary"], anchor = "middle", weight = "bold")
    _rect!(c, x0 + 0.02w, y0 + 0.02h, 0.96w, 0.96h; stroke = col["grid"], sw = 2)
    vals(r) = (sd = r.statistics.sd * sqrt(252);
               [r.cagr * 100, maximum(filter(isfinite, r.drawdowns); init = 0.0) * 100, sd * 100, sd != 0 ? (r.cagr - 0.02) / sd : NaN])
    v1, v2 = vals(x), vals(compare)
    Y(f) = y0 + (1 - f) * h
    _text!(c, x0 + 0.35w, Y(0.95), "Strategy 1"; size = 11, color = col["primary"], anchor = "end", weight = "bold")
    _text!(c, x0 + 0.65w, Y(0.95), "Strategy 2"; size = 11, color = col["secondary"], anchor = "end", weight = "bold")
    _text!(c, x0 + 0.95w, Y(0.95), "Diff"; size = 11, color = col["neutral"], anchor = "end", weight = "bold")
    for (k, (name, yy)) in enumerate(zip(("CAGR", "Max DD", "Volatility", "Sharpe"), range(0.8, 0.2; length = 4)))
        a, b = v1[k], v2[k]; dlt = a - b
        _text!(c, x0 + 0.05w, Y(yy), name; size = 12, weight = "bold")
        _text!(c, x0 + 0.35w, Y(yy), _p2(a); size = 11, color = col["primary"], anchor = "end")
        _text!(c, x0 + 0.65w, Y(yy), _p2(b); size = 11, color = col["secondary"], anchor = "end")
        _text!(c, x0 + 0.95w, Y(yy), _sg(dlt); size = 11, color = dlt > 0 ? col["positive"] : col["negative"],
               anchor = "end", weight = "bold")
    end
end

function _grid_shape(style, n, compare::Bool)
    style == "full" && return compare ? (4, 2) : (3, 2)
    style == "compact" && return (2, 2)
    n <= 2 && return (1, max(n, 1))
    n <= 4 && return (2, 2)
    n <= 6 && return (3, 2)
    return (4, 2)
end

"""
    plot_dashboard(x::SimLevResult; style = "full", panels = nothing, compare = nothing,
                   colors = nothing, width = 14, height = 10, currency = "\$", file = nothing)

Erstellt das mehrteilige Dashboard des R-Pakets als SVG und gibt ein
[`SimLevDashboard`](@ref) zurück (in Notebooks direkt sichtbar). `style`:
`"full"` (alle Standard-Panels), `"compact"` (2×2) oder `"custom"` (Panels aus
`panels`: `"performance"`, `"drawdown"`, `"distribution"`, `"rolling"`,
`"monthly"`, `"stats"`). `compare` zeigt ein zweites Ergebnis zum Vergleich.
Mit `file` wird das SVG zusätzlich gespeichert. Breite und Höhe in Zoll.
"""
function plot_dashboard(x::SimLevResult; style = ("full", "compact", "custom"), panels = nothing,
                        compare::Union{Nothing,SimLevResult} = nothing, colors = nothing,
                        width::Real = 14, height::Real = 10, currency::AbstractString = "\$", file = nothing)
    style = match_arg(style, ("full", "compact", "custom"), "style")
    col = copy(DEFAULT_COLORS)
    colors === nothing || for (k, v) in pairs(colors); col[String(k)] = String(v); end
    selected = style == "full" ?
               (compare !== nothing ? ["performance", "drawdown", "distribution", "rolling", "monthly", "correlation", "stats", "comparison"] :
                                      ["performance", "drawdown", "distribution", "rolling", "monthly", "stats"]) :
               style == "compact" ? ["performance", "drawdown", "distribution", "stats"] :
               String.(panels === nothing ? ["performance", "drawdown", "distribution", "rolling", "monthly", "stats"] : collect(panels))
    nrow, ncol = _grid_shape(style, length(selected), compare !== nothing)
    W = round(Int, 100 * width); H = round(Int, 100 * height)
    c = _Canvas(IOBuffer())
    _svg!(c, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$W\" height=\"$H\" viewBox=\"0 0 $W $H\" " *
             "font-family=\"Helvetica, Arial, sans-serif\">")
    _rect!(c, 0, 0, W, H; fill = col["background"])
    cw = W / ncol; ch = H / nrow
    slot = 0
    function next_cell()
        slot >= nrow * ncol && return nothing
        r, k = divrem(slot, ncol)
        slot += 1
        return (k * cw + 78.0, r * ch + 44.0, cw - 78.0 - 24.0, ch - 44.0 - 46.0)
    end
    n_days = length(x.worth)
    for pnl in selected
        if pnl == "rolling"
            window = min(30, n_days ÷ 10)
            (n_days > window && window > 0) || continue
            (cell = next_cell()) === nothing && break
            _panel_rolling(c, cell, x, col, window)
        elseif pnl == "correlation"
            length(x.report) > 1 || continue
            (cell = next_cell()) === nothing && break
            _panel_correlation(c, cell, col)
        elseif pnl == "comparison"
            compare === nothing && continue
            (cell = next_cell()) === nothing && break
            _panel_comparison(c, cell, x, compare, col)
        else
            (cell = next_cell()) === nothing && break
            pnl == "performance" ? _panel_performance(c, cell, x, col, compare, currency) :
            pnl == "drawdown" ? _panel_drawdown(c, cell, x, col) :
            pnl == "distribution" ? _panel_distribution(c, cell, x, col) :
            pnl == "monthly" ? _panel_monthly(c, cell, x, col) :
            pnl == "stats" ? _panel_stats(c, cell, x, col, compare, currency) :
            throw(ArgumentError("unbekanntes Panel '$pnl'"))
        end
    end
    _svg!(c, "</svg>")
    d = SimLevDashboard(String(take!(c.io)))
    file === nothing || write(String(file), d.svg)
    return d
end

"""
    export_dashboard(x::SimLevResult, filename = "dashboard.svg"; width = 14, height = 10, kwargs...)

Speichert das Dashboard. `.svg` und `.html` werden direkt geschrieben; für
`.pdf` und `.png` wird – falls installiert – `rsvg-convert` aufgerufen.
"""
function export_dashboard(x::SimLevResult, filename::AbstractString = "dashboard.svg";
                          width::Real = 14, height::Real = 10, kwargs...)
    d = plot_dashboard(x; width = width, height = height, kwargs...)
    ext = lowercase(splitext(filename)[2])
    if ext == ".svg"
        write(filename, d.svg)
    elseif ext in (".html", ".htm")
        write(filename, "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>SimLev Dashboard</title></head><body style=\"margin:0\">\n" *
                        d.svg * "\n</body></html>\n")
    elseif ext in (".pdf", ".png")
        exe = Sys.which("rsvg-convert")
        exe === nothing && throw(ArgumentError("Für $ext wird 'rsvg-convert' (librsvg) benötigt. Alternativ als .svg speichern."))
        tmp = tempname() * ".svg"
        write(tmp, d.svg)
        run(`$exe -f $(ext[2:end]) -o $filename $tmp`)
        rm(tmp; force = true)
    else
        throw(ArgumentError("Unbekanntes Format '$ext' (unterstützt: .svg, .html, .pdf, .png)"))
    end
    @info "Dashboard exported to: $filename"
    return filename
end

"Zeigt ein Dashboard in Notebooks an; `plot(result)` ist ein Alias von `plot_dashboard(result)`."
plot(x::SimLevResult; kwargs...) = plot_dashboard(x; kwargs...)
