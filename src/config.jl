# ─────────────────────────────────────────────────────────────────────────────
# Asset-Konfiguration und Strategie-Objekte (Port von asset_config.R / strategy.R)
# ─────────────────────────────────────────────────────────────────────────────

const ASSET_CLASSES = ("etf", "etn", "etc", "certificate", "etn_standard", "etn_deliverable")
const ACTION_TYPES = ("bnh", "signal")
const VALID_REGIMES = ("investment_fund", "capital_gains", "private_sale")
const _FIELDS = ("asset_class", "action_type", "asset_share", "asset_spread", "asset_bonus",
                 "deliverable", "asset_start", "tax_regime", "signal_buy", "signal_sell")

"Nachbildung von R's `match.arg` (inklusive eindeutiger Präfixe)."
function match_arg(value, choices, argname::AbstractString)
    choices = Tuple(String(c) for c in choices)
    value === nothing && return choices[1]
    if value isa Union{AbstractVector,Tuple}
        Tuple(String(v) for v in value) == choices && return choices[1]
        length(value) == 1 || throw(ArgumentError("'$argname' must be of length 1"))
        value = first(value)
    end
    v = String(string(value))
    v in choices && return v
    hits = isempty(v) ? String[] : [c for c in choices if startswith(c, v)]
    length(hits) == 1 && return hits[1]
    throw(ArgumentError("'arg' should be one of " * join(("\"$c\"" for c in choices), ", ") *
                        " (argument '$argname')"))
end

"""
    AssetConfig

Validierte Konfiguration eines Assets (R-Klasse `asset_config`). Felder:
`asset_class`, `action_type`, `asset_share`, `asset_spread`, `asset_bonus`,
`deliverable`, `asset_start`, `tax_regime`, `signal_buy`, `signal_sell`.
"""
struct AssetConfig
    asset_class::String
    action_type::String
    asset_share::Float64
    asset_spread::Float64
    asset_bonus::Float64
    deliverable::Bool
    asset_start::Union{Nothing,Date}
    tax_regime::String
    signal_buy::Union{Nothing,String}
    signal_sell::Union{Nothing,String}
end

_opt_date(::Nothing) = nothing
_opt_date(d::Date) = d
_opt_date(d) = from_days(to_days(d))
_opt_str(::Nothing) = nothing
_opt_str(s) = String(string(s))

"""
    asset_config(asset_class = "etf", action_type = "bnh", asset_share = 1.0,
                 asset_spread = 0.1, asset_bonus = 0.0; deliverable = false,
                 asset_start = nothing, tax_regime = nothing,
                 signal_buy = nothing, signal_sell = nothing)

Erstellt und validiert die Konfiguration eines Assets. Raten folgen der
Paket-Konvention **in Prozent**: `asset_spread = 0.1` bedeutet 0,1 % vollen
Bid-Ask-Spread, `asset_bonus = 30` bedeutet 30 % Teilfreistellung.
`asset_share` ist ein relatives Zielgewicht in (0, 1].

Die ersten fünf Argumente können positionell (wie in R) oder als
Schlüsselwort übergeben werden.
"""
function asset_config(cls = nothing, act = nothing,
                      share = nothing, spread = nothing, bonus = nothing;
                      asset_class = nothing, action_type = nothing,
                      asset_share = nothing, asset_spread = nothing, asset_bonus = nothing,
                      deliverable::Bool = false, asset_start = nothing, tax_regime = nothing,
                      signal_buy = nothing, signal_sell = nothing)
    cls !== nothing && asset_class !== nothing && throw(ArgumentError("asset_class doppelt angegeben"))
    act !== nothing && action_type !== nothing && throw(ArgumentError("action_type doppelt angegeben"))
    asset_class = something(cls, asset_class, ASSET_CLASSES)
    action_type = something(act, action_type, ACTION_TYPES)
    share !== nothing && asset_share !== nothing && throw(ArgumentError("asset_share doppelt angegeben"))
    spread !== nothing && asset_spread !== nothing && throw(ArgumentError("asset_spread doppelt angegeben"))
    bonus !== nothing && asset_bonus !== nothing && throw(ArgumentError("asset_bonus doppelt angegeben"))
    s = something(share, asset_share, 1.0)
    sp = something(spread, asset_spread, 0.1)
    bo = something(bonus, asset_bonus, 0.0)

    asset_class = match_arg(asset_class, ASSET_CLASSES, "asset_class")
    action_type = match_arg(action_type, ACTION_TYPES, "action_type")

    if asset_class == "etn_standard"
        @warn "asset_class 'etn_standard' is deprecated. Use 'etn' with deliverable = FALSE."
        asset_class = "etn"
        deliverable = false
    elseif asset_class == "etn_deliverable"
        @warn "asset_class 'etn_deliverable' is deprecated. Use 'etn' with deliverable = TRUE."
        asset_class = "etn"
        deliverable = true
    end

    (s <= 0 || s > 1) && throw(ArgumentError("asset_share must be between 0 (exclusive) and 1 (inclusive)"))
    sp < 0 && throw(ArgumentError("asset_spread must be non-negative"))
    (bo < 0 || bo > 100) && throw(ArgumentError("asset_bonus must be between 0 and 100 percent (e.g., 30 for 30%)"))
    if action_type == "signal" && (signal_buy === nothing || signal_sell === nothing)
        throw(ArgumentError("signal_buy and signal_sell must be specified when action_type = 'signal'"))
    end

    if tax_regime === nothing
        tax_regime = asset_class == "etf" ? "investment_fund" :
                     asset_class in ("etn", "etc") ? (deliverable ? "private_sale" : "capital_gains") :
                     "capital_gains"
    elseif !(String(tax_regime) in VALID_REGIMES)
        throw(ArgumentError("Invalid tax_regime. Must be one of: " * join(VALID_REGIMES, ", ")))
    end

    return AssetConfig(asset_class, action_type, Float64(s), Float64(sp), Float64(bo), deliverable,
                       _opt_date(asset_start), String(tax_regime), _opt_str(signal_buy), _opt_str(signal_sell))
end

"Konvertiert eine AssetConfig in ein Dict (Feldname => Wert)."
function as_dict(a::AssetConfig)
    d = Dict{String,Any}()
    for f in _FIELDS
        d[f] = getfield(a, Symbol(f))
    end
    return d
end

function _config_from_mapping(m)
    kw = Dict{Symbol,Any}()
    unknown = String[]
    for (k, v) in _pairs(m)
        ks = String(string(k))
        ks in _FIELDS ? (kw[Symbol(ks)] = v) : push!(unknown, ks)
    end
    isempty(unknown) || throw(ArgumentError("unused argument(s): " * join(unknown, ", ")))
    return asset_config(; kw...)
end

_pairs(m::AbstractDict) = pairs(m)
_pairs(m::NamedTuple) = pairs(m)
_pairs(m::AbstractVector{<:Pair}) = m
_pairs(m::AssetConfig) = ((Symbol(f), getfield(m, Symbol(f))) for f in _FIELDS)

function Base.show(io::IO, ::MIME"text/plain", a::AssetConfig)
    print(io, "Asset Configuration\n-------------------\n")
    print(io, rsprintf("  Class:        %s\n", a.asset_class))
    print(io, rsprintf("  Action:       %s\n", a.action_type))
    print(io, rsprintf("  Share:        %.1f%%\n", a.asset_share * 100))
    print(io, rsprintf("  Tax Regime:   %s", a.tax_regime))
    a.asset_class == "etf" && print(io, rsprintf("\n  Teilfrei.:    %.0f%%", a.asset_bonus))
    a.asset_class in ("etn", "etc") && print(io, rsprintf("\n  Deliverable:  %s", a.deliverable ? "TRUE" : "FALSE"))
end
Base.show(io::IO, a::AssetConfig) = print(io, "AssetConfig(\"", a.asset_class, "\", \"", a.action_type, "\", ",
                                          a.asset_share, ", ", a.asset_spread, ", ", a.asset_bonus, ")")

"""
    Strategy

Geordnete Sammlung benannter [`AssetConfig`](@ref)-Objekte (R-Klasse `strategy`).
Verhält sich wie ein unveränderliches, geordnetes `AbstractDict{String,AssetConfig}`.
"""
struct Strategy <: AbstractDict{String,AssetConfig}
    names::Vector{String}
    assets::Vector{AssetConfig}
end

Base.length(s::Strategy) = length(s.names)
function Base.iterate(s::Strategy, i::Int = 1)
    i > length(s.names) && return nothing
    return (s.names[i] => s.assets[i], i + 1)
end
Base.haskey(s::Strategy, k::AbstractString) = String(k) in s.names
Base.haskey(s::Strategy, k::Symbol) = haskey(s, String(k))
function Base.getindex(s::Strategy, k::Union{AbstractString,Symbol})
    i = findfirst(==(String(k)), s.names)
    i === nothing && throw(KeyError(String(k)))
    return s.assets[i]
end
function Base.get(s::Strategy, k::Union{AbstractString,Symbol}, default)
    i = findfirst(==(String(k)), s.names)
    return i === nothing ? default : s.assets[i]
end
Base.keys(s::Strategy) = copy(s.names)
Base.values(s::Strategy) = copy(s.assets)

"""
    create_strategy(; NAME = asset_config(...), ...)
    create_strategy("NAME" => asset_config(...), ...)
    create_strategy(; assets = ...)

Erstellt eine Strategie aus benannten Asset-Konfigurationen. Statt
`AssetConfig`-Objekten werden auch NamedTuples/Dicts mit den Feldern von
[`asset_config`](@ref) angenommen. Die Reihenfolge bleibt erhalten.
"""
function create_strategy(args::Pair...; assets = nothing, kwargs...)
    if assets !== nothing && (length(kwargs) > 0 || !isempty(args))
        throw(ArgumentError("Provide either ... arguments or 'assets', not both"))
    end
    items = Pair{String,Any}[]
    if assets !== nothing
        (assets isa Union{AbstractDict,NamedTuple,AbstractVector{<:Pair}}) ||
            throw(ArgumentError("'assets' must be a named list"))
        for (k, v) in _pairs(assets)
            push!(items, String(string(k)) => v)
        end
    else
        for (k, v) in args
            push!(items, String(string(k)) => v)
        end
        for (k, v) in kwargs
            push!(items, String(k) => v)
        end
    end
    isempty(items) && throw(ArgumentError("At least one asset configuration is required"))
    any(p -> isempty(p.first), items) && throw(ArgumentError("All assets must be named"))
    names = String[]
    cfgs = AssetConfig[]
    for (k, v) in items
        cfg = v isa AssetConfig ? v :
              v isa Union{AbstractDict,NamedTuple} ? _config_from_mapping(v) :
              throw(ArgumentError("Asset '$k' must be an asset_config object or list"))
        i = findfirst(==(k), names)
        if i === nothing
            push!(names, k); push!(cfgs, cfg)
        else
            cfgs[i] = cfg
        end
    end
    return Strategy(names, cfgs)
end

_colnames(data) = data isa AbstractDict ? [String(string(k)) for k in keys(data)] :
                  [String(string(k)) for k in propertynames(data)]

"Prüft eine Strategie und – optional – ob alle Spalten in `data` existieren."
function validate_strategy(strategy, data = nothing)
    strategy isa Strategy || throw(ArgumentError("Object is not a strategy"))
    if data !== nothing
        cols = _colnames(data)
        missing_ = [n for n in strategy.names if !(n in cols)]
        isempty(missing_) || throw(ArgumentError("Assets not found in data: " * join(missing_, ", ")))
        for (name, a) in strategy
            if a.action_type == "signal"
                a.signal_buy in cols || throw(ArgumentError("Signal column '$(a.signal_buy)' not found (asset '$name')"))
                a.signal_sell in cols || throw(ArgumentError("Signal column '$(a.signal_sell)' not found (asset '$name')"))
            end
        end
    end
    return true
end

"Fügt ein Asset hinzu und gibt eine neue Strategie zurück."
function add_asset(strategy, name::AbstractString, asset)
    strategy isa Strategy || throw(ArgumentError("First argument must be a strategy object"))
    asset isa AssetConfig || throw(ArgumentError("asset must be an asset_config object"))
    names = copy(strategy.names); cfgs = copy(strategy.assets)
    i = findfirst(==(String(name)), names)
    if i === nothing
        push!(names, String(name)); push!(cfgs, asset)
    else
        cfgs[i] = asset
    end
    return Strategy(names, cfgs)
end

"Aktualisiert Felder eines Assets, validiert neu und gibt eine neue Strategie zurück."
function update_asset(strategy, name::AbstractString; updates...)
    strategy isa Strategy || throw(ArgumentError("First argument must be a strategy object"))
    haskey(strategy, name) || throw(ArgumentError("Asset '$name' not found in strategy"))
    d = as_dict(strategy[name])
    for (k, v) in updates
        ks = String(k)
        if !(ks in _FIELDS)
            @warn "Unknown parameter '$ks' ignored"
            continue
        end
        d[ks] = v
    end
    return add_asset(strategy, name, _config_from_mapping(d))
end

"Entfernt ein Asset und gibt eine neue Strategie zurück."
function remove_asset(strategy, name::AbstractString)
    strategy isa Strategy || throw(ArgumentError("First argument must be a strategy object"))
    i = findfirst(==(String(name)), strategy.names)
    i === nothing && throw(ArgumentError("Asset '$name' not found in strategy"))
    names = deleteat!(copy(strategy.names), i)
    cfgs = deleteat!(copy(strategy.assets), i)
    isempty(names) && @warn "Strategy is now empty"
    return Strategy(names, cfgs)
end

"Wandelt Strategien mit veralteten Assetklassen in das aktuelle Format um."
function migrate_strategy(old_strategy; verbose::Bool = true)
    names = String[]; cfgs = AssetConfig[]
    for (name, asset) in _pairs(old_strategy)
        d = Dict{String,Any}(String(string(k)) => v for (k, v) in _pairs(asset))
        cls = get(d, "asset_class", nothing)
        if cls == "etn_deliverable"
            verbose && @info "Migrating $name: etn_deliverable -> etn + deliverable=TRUE"
            d["asset_class"] = "etn"; d["deliverable"] = true
        elseif cls == "etn_standard"
            verbose && @info "Migrating $name: etn_standard -> etn + deliverable=FALSE"
            d["asset_class"] = "etn"; d["deliverable"] = false
        end
        push!(names, String(string(name))); push!(cfgs, _config_from_mapping(d))
    end
    return Strategy(names, cfgs)
end

"Entfernt die Klassen-Hülle: Strategie → `Dict{String,Dict{String,Any}}` (Reihenfolge in `keys` beachten)."
as_list(s::Strategy) = [n => as_dict(a) for (n, a) in s]
as_list(a::AssetConfig) = as_dict(a)
as_list(x) = collect(x)

function Base.show(io::IO, ::MIME"text/plain", s::Strategy)
    print(io, rsprintf("Investment Strategy (%d assets)\n", length(s)))
    print(io, "================================\n")
    for (name, a) in s
        print(io, rsprintf("\n%s:\n", name))
        print(io, rsprintf("  Class: %s | Share: %.0f%% | Tax: %s", a.asset_class, a.asset_share * 100, a.tax_regime))
    end
end
Base.show(io::IO, s::Strategy) = print(io, "Strategy(", join(s.names, ", "), ")")

"Kompakte Übersicht einer Strategie (wie R's `summary.strategy`)."
function Base.summary(s::Strategy; io::IO = stdout)
    print(io, rsprintf("Strategy Summary: %d assets\n\n", length(s)))
    total_share = r_sum([a.asset_share for a in s.assets])
    print(io, rsprintf("Total allocation: %.1f%%\n", total_share * 100))
    abs(total_share - 1) > 0.001 && print(io, "  (Note: Does not sum to 100%)\n")
    print(io, "\nBy Tax Regime:\n")
    regimes = [a.tax_regime for a in s.assets]
    for r in unique(regimes)
        print(io, rsprintf("  %s: %d asset(s)\n", r, count(==(r), regimes)))
    end
    return s
end

"Kompakte Übersicht einer Asset-Konfiguration (wie R's `summary.asset_config`)."
function Base.summary(a::AssetConfig; io::IO = stdout)
    show(io, MIME"text/plain"(), a); println(io)
    return a
end
