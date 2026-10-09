# ─────────────────────────────────────────────────────────────────────────────
# Interaktives HTML-Dashboard (Port von plot_interactive.R, Engine "html")
#
# Erzeugt eine vollständig eigenständige HTML-Datei (Inline-SVG + JavaScript),
# die offline in jedem Browser funktioniert. Die Datei ist zeichengleich zur
# Ausgabe des R-Pakets – bis auf die Kopfzeile, in der R wegen eines Fehlers
# „CAGR NA% · Sharpe NA“ schreibt; hier stehen die echten Werte.
# ─────────────────────────────────────────────────────────────────────────────

include("html_templates.jl")

const _PANELS = ("performance", "drawdown", "weights")
const _PAL = ("#2C7FB8", "#D95F02", "#1B9E77", "#7570B3", "#E7298A", "#66A61E", "#E6AB02", "#A6761D")

"`unique(c(round(seq(1, n, length.out = max_points)), n))` wie in R."
function _thin_index(n::Int, max_points::Int)
    n <= max_points && return collect(1:n)
    n1 = max_points - 1
    by = (n - 1) / n1
    sq = [1.0; [1.0 + k * by for k in 1:n1-1]; Float64(n)]
    out = Int[]
    seen = Set{Int}()
    for v in [Int.(round.(sq, RoundNearest)); n]
        v in seen && continue
        push!(seen, v); push!(out, v)
    end
    return out
end

function _dashboard_data(x::SimLevResult, max_points::Int)
    n = length(x.dates)
    keep = _thin_index(n, max_points)
    assets = collect(keys(x.report))
    totals = [x.report[a].total[keep] for a in assets]
    tot_sum = copy(totals[1])
    for t in totals[2:end]
        tot_sum = tot_sum .+ t
    end
    flows = copy(x.report[assets[1]].flows)
    for a in assets[2:end]
        flows = flows .+ x.report[a].flows
    end
    invested = r_cumsum(flows)[keep]
    weights = [[tot_sum[i] > 0 ? 100 * t[i] / tot_sum[i] : 0.0 for i in eachindex(t)] for t in totals]
    return (dates = [Dates.format(d, dateformat"yyyy-mm-dd") for d in x.dates[keep]],
            filled = x.filled[keep], assets = assets, worth = x.worth[keep], invested = invested,
            totals = totals, weights = weights, drawdown = 100 .* x.drawdowns[keep], result = x)
end

_num2js(v) = "[" * join((isfinite(a) ? rsprintf("%.6g", a) : "null" for a in Float64.(v)), ",") * "]"
_chr2js(v) = "[\"" * join(v, "\",\"") * "\"]"

function _js_panel(pid, title, series, unit; fill_first::Bool = false)
    ser = String[]
    for s in series
        push!(ser, rsprintf("{name:\"%s\",col:\"%s\",w:%s,dash:%s,v:%s}", s.name, s.col, r_num_str(s.width),
                            get(s, :dash, false) ? "true" : "false", _num2js(s.vals)))
    end
    return rsprintf("makePanel(\"%s\",\"%s\",[%s],\"%s\",%s);", pid, title, join(ser, ","), unit,
                    fill_first ? "true" : "false")
end

function _stat_line(x::SimLevResult)
    p(fmt, v) = isnan(v) ? "NA" : rsprintf(fmt, v)
    s = x.statistics
    return "CAGR " * p("%.2f", 100 * x.cagr) * "% &middot; Sharpe " * p("%.2f", s.sharpe) *
           " &middot; Max. Drawdown " * p("%.1f", 100 * s.max_drawdown) * "%"
end

function _dashboard_html(d, panels)
    perf = Any[(name = a, col = _PAL[mod1(i, length(_PAL))], vals = d.totals[i], width = 1.4) for (i, a) in enumerate(d.assets)]
    push!(perf, (name = "Gesamt", col = "#111111", vals = d.worth, width = 2.4))
    push!(perf, (name = "Einzahlungen", col = "#888888", vals = d.invested, width = 1.4, dash = true))
    wser = Any[(name = a, col = _PAL[mod1(i, length(_PAL))], vals = d.weights[i], width = 1.6) for (i, a) in enumerate(d.assets)]
    calls = String[]; divs = String[]
    if "performance" in panels
        push!(divs, "<div class=\"panel\" id=\"performance\"></div>")
        push!(calls, _js_panel("performance", "Portfolio Performance", perf, " EUR"))
    end
    if "drawdown" in panels
        push!(divs, "<div class=\"panel\" id=\"drawdown\"></div>")
        push!(calls, _js_panel("drawdown", "Drawdown",
                               [(name = "Drawdown", col = "#C0392B", vals = d.drawdown, width = 1.6)], " %"; fill_first = true))
    end
    if "weights" in panels
        push!(divs, "<div class=\"panel\" id=\"weights\"></div>")
        push!(calls, _js_panel("weights", "Asset-Gewichte", wser, " %"))
    end
    return _HTML_HEAD * _stat_line(d.result) * _HTML_SUB * join(divs, "\n") * _HTML_MID1 * _chr2js(d.dates) *
           ";\nvar FILLED=" * _num2js(Float64.(d.filled)) * _HTML_SCRIPT * join(calls, "\n") * _HTML_TAIL
end

function _open_in_browser(file::AbstractString)
    try
        if Sys.isapple()
            run(`open $file`; wait = false)
        elseif Sys.iswindows()
            run(`cmd /c start "" $file`; wait = false)
        else
            run(`xdg-open $file`; wait = false)
        end
    catch
        @info "Dashboard geschrieben: $file"
    end
    return nothing
end

"""
    plot_interactive(x::SimLevResult; file = nothing,
                     panels = ["performance", "drawdown", "weights"],
                     max_points = 6000, open = isinteractive())

Interaktives Dashboard mit Hover-Tooltips, synchronem Fadenkreuz über alle
Panels und klickbarer Legende. Schreibt eine eigenständige HTML-Datei (ohne
Abhängigkeiten, offline lauffähig) und gibt ihren Pfad zurück. Lange Reihen
werden für die Darstellung gleichmäßig auf `max_points` Punkte ausgedünnt.
"""
function plot_interactive(x::SimLevResult; file = nothing, panels = _PANELS, max_points::Integer = 6000,
                          open::Bool = isinteractive())
    pl = panels isa AbstractString ? [panels] : collect(panels)
    pl = [match_arg(p, _PANELS, "panels") for p in pl]
    path = file === nothing ? tempname() * "_simlev_dashboard.html" : String(file)
    html = _dashboard_html(_dashboard_data(x, Int(max_points)), pl)
    write(path, html * "\n")
    open && _open_in_browser(path)
    return path
end

"""
    export_html_dashboard(x::SimLevResult, filename = "dashboard.html")

Schreibt das interaktive HTML-Dashboard (siehe [`plot_interactive`](@ref)).
Im R-Paket ist diese Funktion nur ein Platzhalter.
"""
export_html_dashboard(x::SimLevResult, filename::AbstractString = "dashboard.html") =
    plot_interactive(x; file = filename, open = false)
