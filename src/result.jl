# ─────────────────────────────────────────────────────────────────────────────
# Ergebnisobjekt der Simulation (R-Klasse `SimLevResult`)
# ─────────────────────────────────────────────────────────────────────────────

"Geordnetes, unveränderliches Dict mit String-Schlüsseln (wie eine benannte R-Liste)."
struct NamedList{V} <: AbstractDict{String,V}
    keys::Vector{String}
    vals::Vector{V}
end
NamedList(p::Vector{<:Pair}) = NamedList([String(x.first) for x in p], [x.second for x in p])
const NamedVec = NamedList{Float64}
const OrderedReport = NamedList

Base.length(d::NamedList) = length(d.keys)
Base.iterate(d::NamedList, i::Int = 1) = i > length(d.keys) ? nothing : (d.keys[i] => d.vals[i], i + 1)
function Base.getindex(d::NamedList, k::Union{AbstractString,Symbol})
    i = findfirst(==(String(k)), d.keys)
    i === nothing && throw(KeyError(String(k)))
    return d.vals[i]
end
Base.getindex(d::NamedList, i::Integer) = d.vals[i]
Base.haskey(d::NamedList, k::Union{AbstractString,Symbol}) = String(k) in d.keys
function Base.get(d::NamedList, k::Union{AbstractString,Symbol}, default)
    i = findfirst(==(String(k)), d.keys)
    return i === nothing ? default : d.vals[i]
end
Base.keys(d::NamedList) = copy(d.keys)
Base.values(d::NamedList) = copy(d.vals)

"""
    SimLevResult

Ergebnis von [`simulation`](@ref). Felder (wie die Listenelemente in R):
`dates`, `filled`, `worth`, `cagr`, `ttwror`, `drawdowns`, `statistics`
(NamedTuple), `buys`, `sells`, `report` (je Asset ein NamedTuple mit
`worth`, `money`, `flows`, `total`, `share`), `tax_report` (NamedTuple).
Zusätzlich enthält `trades` die Lots, Verkäufe, Steuer- und Gebührenbuchungen.

`NA` wird wie in R als NaN mit Nutzlast 1954 geführt; [`isna_strict`](@ref)
unterscheidet es von `NaN`.
"""
struct SimLevResult
    dates::Vector{Date}
    filled::Vector{Bool}
    worth::Vector{Float64}
    cagr::Float64
    ttwror::Float64
    drawdowns::Vector{Float64}
    statistics::NamedTuple
    buys::NamedList{Float64}
    sells::NamedList{Float64}
    report::NamedList
    tax_report::NamedTuple
    trades::NamedList
end

Base.getindex(r::SimLevResult, k::Union{Symbol,AbstractString}) = getfield(r, Symbol(k))

"Text von `print(result)` aus dem R-Paket (zeichengleich)."
function format_result(x::SimLevResult)
    s = x.statistics
    io = IOBuffer()
    p(args...) = print(io, rsprintf(args...))
    print(io, "\n", _RULE, "\n                    SimLev Simulation Results                  \n", _RULE, "\n\n")
    print(io, "  Performance\n  ─────────────────────\n")
    p("  CAGR:             %+.2f%%\n", x.cagr * 100)
    p("  TTWROR:           %+.2f%%\n", x.ttwror * 100)
    p("  Final Value:      %.2f EUR\n", x.worth[end])
    print(io, "\n  Risk\n  ─────────────────────\n")
    p("  Max Drawdown:     %.2f%%\n", s.max_drawdown * 100)
    p("  Avg Drawdown:     %.2f%%\n", s.average_drawdown * 100)
    p("  Ulcer Index:      %.4f\n", s.ulcer_index)
    p("  Longest DD:       %d Tage\n", s.longest_drawdown)
    p("  Avg Recovery:     %s Tage\n", isnan(s.avg_recovery_time) ? "–" : rsprintf("%.0f", s.avg_recovery_time))
    print(io, "\n  Ratios\n  ─────────────────────\n")
    fr(v) = isnan(v) ? "–" : rsprintf("%+.3f", v)
    p("  Sharpe:           %s\n", fr(s.sharpe))
    p("  Sortino:          %s\n", fr(s.sortino))
    p("  Calmar:           %s\n", fr(s.calmar))
    p("  Omega:            %s\n", fr(s.omega))
    p("  Gain/Pain:        %s\n", fr(s.gain_to_pain))
    p("  Serenity:         %s\n", fr(s.serenity))
    p("  Martin Ratio:              %s\n", fr(s.martin_ratio))
    print(io, "\n  Distribution\n  ─────────────────────\n")
    p("  Daily Mean:       %+.4f%%\n", s.mean * 100)
    p("  Daily Std Dev:    %.4f%%\n", s.sd * 100)
    p("  Skewness:         %.3f\n", s.skewness)
    p("  Kurtosis:         %.3f\n", s.kurtosis)
    print(io, "\n")
    tr = x.tax_report
    if tr.total_taxes_paid > 0
        print(io, "  Steuern\n  ─────────────────────\n")
        p("  Gezahlte Steuern: %.2f EUR\n", tr.total_taxes_paid)
        p("  Verlustvortrag:   %.2f EUR (§ 20) / %.2f EUR (§ 23)\n", tr.loss_carryforward_capital, tr.loss_carryforward_private)
        if tr.sparer_pauschbetrag_annual > 0
            p("  SPB genutzt:      %.2f EUR (Ersparnis: %.2f EUR)\n", tr.sparer_pauschbetrag_used, tr.sparer_pauschbetrag_tax_saved)
        end
        print(io, "\n")
    end
    print(io, _RULE)
    return String(take!(io))
end

Base.show(io::IO, ::MIME"text/plain", x::SimLevResult) = print(io, format_result(x))
Base.show(io::IO, x::SimLevResult) =
    print(io, "SimLevResult(", length(x.worth), " Tage, Endwert ", rsprintf("%.2f", x.worth[end]), " EUR)")

"""
    summary(result::SimLevResult; verbose = true)

Kompakte Kennzahlenübersicht wie R's `summary.SimLevResult`. Gibt die Werte
als NamedTuple zurück und druckt sie bei `verbose = true`.
"""
function Base.summary(x::SimLevResult; verbose::Bool = true, io::IO = stdout)
    n_days = length(x.worth)
    s = x.statistics
    start, stop = x.worth[1], x.worth[end]
    res = (n_days = n_days, n_years = r_round(n_days / 365.25, 2), start_value = start, end_value = stop,
           total_return = (stop / start) - 1, cagr = x.cagr, ttwror = x.ttwror,
           sharpe = s.sharpe, sortino = s.sortino, calmar = s.calmar, omega = s.omega,
           gain_to_pain = s.gain_to_pain, serenity = s.serenity, martin_ratio = s.martin_ratio,
           max_drawdown = s.max_drawdown, average_drawdown = s.average_drawdown, ulcer_index = s.ulcer_index,
           longest_drawdown = s.longest_drawdown, avg_recovery_time = s.avg_recovery_time,
           statistics = s, tax_report = x.tax_report)
    if verbose
        p(args...) = print(io, rsprintf(args...))
        print(io, "\n", _RULE, "\n                    SimLev Summary                             \n", _RULE, "\n\n")
        p("  Zeitraum:         %d Tage (%.1f Jahre)\n", n_days, res.n_years)
        p("  Start:            %.2f EUR\n", start)
        p("  Ende:             %.2f EUR\n", stop)
        p("  Gesamtrendite:    %+.2f%%\n", res.total_return * 100)
        p("  CAGR:             %+.2f%%\n", x.cagr * 100)
        p("  TTWROR:           %+.2f%%\n", x.ttwror * 100)
        print(io, "\n")
        f(v; pct = false) = isnan(v) ? "–" : (pct ? rsprintf("%.2f%%", v * 100) : rsprintf("%.3f", v))
        rows = ["Sharpe" => f(s.sharpe), "Sortino" => f(s.sortino), "Calmar" => f(s.calmar),
                "Omega" => f(s.omega), "Gain/Pain" => f(s.gain_to_pain), "Serenity" => f(s.serenity),
                "Martin" => f(s.martin_ratio), "Max DD" => f(s.max_drawdown; pct = true),
                "Avg DD" => f(s.average_drawdown; pct = true), "Ulcer" => f(s.ulcer_index),
                "Longest DD" => rsprintf("%d d", s.longest_drawdown),
                "Avg Recovery" => (isnan(s.avg_recovery_time) ? "–" : rsprintf("%.0f d", s.avg_recovery_time))]
        for (k, v) in rows
            p("  %-16s %s\n", k, v)
        end
        print(io, "\n", _RULE, "\n")
    end
    return res
end
