# ─────────────────────────────────────────────────────────────────────────────
# Eingabedaten: spaltenorientierte Sicht nach R-Semantik
#
# Akzeptiert werden NamedTuples von Vektoren, Dicts (String/Symbol => Vektor)
# und jede Tabelle, die ihre Spalten über `propertynames`/`getproperty`
# bereitstellt (z. B. ein DataFrame aus DataFrames.jl).
# ─────────────────────────────────────────────────────────────────────────────

mutable struct Col
    kind::Symbol                 # :date, :numeric, :logical, :other
    num::Vector{Float64}         # numerisch; logisch als 1.0 / 0.0 / NA
    other::Vector{Any}
end

mutable struct SimData
    names::Vector{String}
    cols::Dict{String,Col}
    days::Vector{Int}
    nrow::Int
    filled::Union{Nothing,Vector{Bool}}
end

Base.haskey(d::SimData, name::AbstractString) = haskey(d.cols, name) || name == "date"

function _raw_columns(data)
    data === nothing && throw(ArgumentError("'data' must be a data.frame"))
    if data isa AbstractDict
        names = [String(string(k)) for k in keys(data)]
        vals = [data[k] for k in keys(data)]
    elseif data isa NamedTuple
        names = [String(k) for k in keys(data)]
        vals = [v for v in values(data)]
    else
        pn = try
            propertynames(data)
        catch
            throw(ArgumentError("'data' must be a data.frame"))
        end
        names = [String(string(k)) for k in pn]
        vals = [getproperty(data, k) for k in pn]
    end
    all(v -> v isa AbstractVector, vals) || throw(ArgumentError("'data' must be a data.frame"))
    return names, vals
end

_date_days(v::AbstractVector{<:Date}) = Int[to_days(x) for x in v]
_date_days(v::AbstractVector{<:DateTime}) = Int[to_days(x) for x in v]
_date_days(v::AbstractVector{<:Integer}) = Int[Int(x) for x in v]
_date_days(v::AbstractVector) = Int[to_days(x) for x in v]

function _classify(v::AbstractVector)
    n = length(v)
    T = eltype(v)
    S = Base.nonmissingtype(T)
    if S <: Bool
        return Col(:logical, Float64[x === missing ? NA : (x ? 1.0 : 0.0) for x in v], Any[])
    elseif S <: Real
        return Col(:numeric, Float64[x === missing ? NA : Float64(x) for x in v], Any[])
    end
    vals = [x for x in v if !(x === missing || x === nothing || (x isa AbstractFloat && isnan(x)))]
    if !isempty(vals) && all(x -> x isa Bool, vals)
        return Col(:logical, Float64[(x === missing || x === nothing) ? NA : (x ? 1.0 : 0.0) for x in v], Any[])
    elseif !isempty(vals) && all(x -> x isa Real && !(x isa Bool), vals)
        return Col(:numeric, Float64[(x === missing || x === nothing) ? NA : Float64(x) for x in v], Any[])
    elseif isempty(vals)
        return Col(:logical, fill(NA, n), Any[])
    end
    return Col(:other, Float64[], Any[x for x in v])
end

function SimData(data)
    names, vals = _raw_columns(data)
    "date" in names || throw(ArgumentError("'data' must contain a 'date' column"))
    cols = Dict{String,Col}()
    days = Int[]
    for (nm, v) in zip(names, vals)
        if nm == "date"
            days = _date_days(v)
            continue
        end
        cols[nm] = _classify(v)
    end
    lens = Set([length(days); [c.kind == :other ? length(c.other) : length(c.num) for c in values(cols)]])
    length(lens) == 1 || throw(ArgumentError("all columns of 'data' must have the same length"))
    return SimData(names, cols, days, first(lens), nothing)
end

function _locf_fill!(v::Vector{Float64})
    nonna = findall(!isnan, v)
    isempty(nonna) && return v
    idx = zeros(Int, length(v))
    idx[nonna] = nonna
    m = 0
    @inbounds for i in eachindex(idx)
        m = max(m, idx[i])
        idx[i] = m
    end
    idx[idx .== 0] .= nonna[1]
    return v[idx]
end

function _fill_calendar!(d::SimData)
    dates = d.days
    start, stop = dates[1], dates[end]
    all_dates = collect(start:stop)
    pos = Dict{Int,Int}()
    for (i, z) in enumerate(dates)
        if start <= z <= stop
            haskey(pos, z) && throw(ArgumentError("doppelte Datumswerte in 'data' werden nicht unterstützt"))
            pos[z] = i
        end
    end
    n = length(all_dates)
    src = [get(pos, z, 0) for z in all_dates]
    filled = src .== 0
    for nm in d.names
        nm == "date" && continue
        c = d.cols[nm]
        if c.kind == :numeric
            out = fill(NA, n)
            for j in 1:n
                src[j] > 0 && (out[j] = c.num[src[j]])
            end
            c.num = _locf_fill!(out)
        elseif c.kind == :logical
            out = zeros(Float64, n)
            for j in 1:n
                if src[j] > 0
                    x = c.num[src[j]]
                    out[j] = isnan(x) ? 0.0 : x       # R: NA in logischen Spalten -> FALSE
                end
            end
            c.num = out
        else
            out = Vector{Any}(nothing, n)
            for j in 1:n
                src[j] > 0 && (out[j] = c.other[src[j]])
            end
            c.other = out
        end
    end
    d.days = all_dates
    d.nrow = n
    d.filled = filled
    return d
end

"`as.logical()` für eine Spalte; NA -> false (für Event-Flags)."
function _as_logical(c::Col)
    if c.kind == :other
        return Bool[x isa AbstractString ? (x in ("TRUE", "true", "T", "True")) :
                    x isa Bool ? x : (x isa Real && !isnan(x) && x != 0) for x in c.other]
    end
    return Bool[!isnan(x) && x != 0 for x in c.num]
end
