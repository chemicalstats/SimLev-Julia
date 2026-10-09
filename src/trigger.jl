# ─────────────────────────────────────────────────────────────────────────────
# Vorberechnung der Event-Trigger-Spalte (Port von compute_rebal_trigger.R)
# ─────────────────────────────────────────────────────────────────────────────

function _getcol(df, name::AbstractString)
    if df isa AbstractDict
        haskey(df, name) && return df[name]
        haskey(df, Symbol(name)) && return df[Symbol(name)]
        return nothing
    end
    s = Symbol(name)
    s in propertynames(df) || return nothing
    return getproperty(df, s)
end

_nrow(df) = df isa AbstractDict ? length(first(values(df))) :
            df isa NamedTuple ? length(first(df)) : length(getproperty(df, first(propertynames(df))))

function _with_col(df, name::AbstractString, v::AbstractVector)
    if df isa NamedTuple
        return merge(df, NamedTuple{(Symbol(name),)}((v,)))
    elseif df isa AbstractDict
        out = copy(df)
        kt = keytype(out)
        out[kt === Symbol ? Symbol(name) : name] = v
        return out
    end
    out = copy(df)
    setproperty!(out, Symbol(name), v)
    return out
end

_f64(x) = x === missing ? NA : Float64(x)

"""
    compute_rebal_trigger(df, type; threshold = 10, lev_col = "target_leverage",
                          vol_col = "sigma_ewma", triggers = nothing,
                          out_col = "rebal_trigger")

Berechnet eine logische Trigger-Spalte für ereignisbasiertes Rebalancing
(`type` = `"abs_leverage"`, `"rel_leverage"`, `"vol_band"` oder `"combined"`).
`threshold` wird **in Prozent** angegeben. Gibt eine Kopie von `df` mit der
Spalte `out_col` zurück (NamedTuple, Dict oder z. B. DataFrame). Tag 1 ist
immer `false`.
"""
function compute_rebal_trigger(df, type::AbstractString; threshold::Real = 10,
                               lev_col::AbstractString = "target_leverage",
                               vol_col::AbstractString = "sigma_ewma",
                               triggers = nothing, out_col::AbstractString = "rebal_trigger")
    n = _nrow(df)
    n < 1 && throw(ArgumentError("compute_rebal_trigger: leerer data.frame."))
    thr = threshold / 100
    trig = falses(n)
    if type == "abs_leverage" || type == "rel_leverage"
        col = _getcol(df, lev_col)
        col === nothing && throw(ArgumentError("Spalte '$lev_col' fehlt."))
        lev = _f64.(col)
        held = lev[1]
        for t in 2:n
            v = lev[t]
            isnan(v) && continue
            isnan(held) && throw(ArgumentError("missing value where TRUE/FALSE needed"))   # wie R's if(NA)
            if type == "abs_leverage"
                if abs(v - held) > thr
                    trig[t] = true; held = v
                end
            else
                if held != 0 && abs(v / held - 1) > thr
                    trig[t] = true; held = v
                end
            end
        end
    elseif type == "vol_band"
        col = _getcol(df, vol_col)
        col === nothing && throw(ArgumentError("Spalte '$vol_col' fehlt."))
        vol = _f64.(col)
        ref = vol[1]
        for t in 2:n
            v = vol[t]
            !isnan(v) && isnan(ref) && throw(ArgumentError("missing value where TRUE/FALSE needed"))
            if !isnan(v) && ref != 0 && abs(v / ref - 1) > thr
                trig[t] = true; ref = v
            end
        end
    elseif type == "combined"
        (triggers === nothing || isempty(triggers)) &&
            throw(ArgumentError("type='combined' benoetigt eine nicht-leere Liste 'triggers'."))
        for sub in triggers
            kw = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(sub))
            st = String(pop!(kw, :type))
            sub_df = compute_rebal_trigger(df, st; out_col = "..__sub__..", kw...)
            trig .|= Bool.(_getcol(sub_df, "..__sub__.."))
        end
    else
        throw(ArgumentError("Unbekannter type='$type'."))
    end
    return _with_col(df, out_col, Vector{Bool}(trig))
end
