# ─────────────────────────────────────────────────────────────────────────────
# R-kompatible Numerik
#
# Die Funktionen bilden die Akkumulationsreihenfolge und -genauigkeit von R
# exakt nach (long double über F80). NA wird wie in R als NaN mit der
# Nutzlast 1954 dargestellt, sodass NA und NaN unterscheidbar bleiben.
# ─────────────────────────────────────────────────────────────────────────────

"R's `NA_real_`: NaN mit Nutzlast 1954 (signalisierend gespeichert, wie in R)."
const NA = reinterpret(Float64, 0x7FF00000000007A2)

"`is.na()` für einen Skalar: TRUE für NA und NaN."
r_isnan(x::Real) = isnan(x)

"TRUE nur für R's NA (nicht für NaN) – entspricht `R_IsNA`."
isna_strict(x::Float64) = isnan(x) && (reinterpret(UInt64, x) & 0x00000000FFFFFFFF) == 0x00000000000007A2

const _LD0 = F80(0.0)
const _LD1 = F80(1.0)

"`sum(x)` / `sum(x, na.rm = TRUE)` wie in R."
function r_sum(x; na_rm::Bool = false)
    s = _LD0
    @inbounds for v in x
        fv = Float64(v)
        if !na_rm || !isnan(fv)
            s = s + F80(fv)
        end
    end
    _gt_dblmax(s) && return Inf
    _lt_negdblmax(s) && return -Inf
    return Float64(s)
end

"`cumsum(x)` wie in R."
function r_cumsum(x)
    out = Vector{Float64}(undef, length(x))
    s = _LD0
    @inbounds for (i, v) in enumerate(x)
        s = s + _ldq(Float64(v))
        out[i] = Float64(s)
    end
    return out
end

"`prod(x)` wie in R."
function r_prod(x; na_rm::Bool = false)
    s = _LD1
    @inbounds for v in x
        fv = Float64(v)
        if !na_rm || !isnan(fv)
            s = s * F80(fv)
        end
    end
    _gt_dblmax(s) && return Inf
    _lt_negdblmax(s) && return -Inf
    return Float64(s)
end

_dropnan(x) = Float64[v for v in x if !isnan(Float64(v))]

"`mean(x)` für Doubles wie R's `real_mean` (Summe/n plus Korrekturdurchlauf)."
function r_mean(x; na_rm::Bool = false)
    a = na_rm ? _dropnan(x) : collect(Float64, x)
    n = length(a)
    n == 0 && return NaN
    ln = F80(n)
    s = _LD0
    @inbounds for v in a
        s = s + F80(v)
    end
    if isfinite(Float64(s))
        s = s / ln
    else
        t = _LD0
        @inbounds for v in a
            t = t + F80(v) / ln
        end
        s = t
    end
    if isfinite(Float64(s))
        t = _LD0
        @inbounds for v in a
            t = t + (F80(v) - s)
        end
        s = s + t / ln
    end
    return Float64(s)
end

"`mean(x)` für Integer-Vektoren wie in R."
function r_mean_int(x)
    n = length(x)
    n == 0 && return NaN
    s = _LD0
    for v in x
        s = s + F80(Int(v))
    end
    return Float64(s / F80(n))
end

"`var(x)` wie R's `cov_complete1` (long double, Mittelwert als double gespeichert)."
function r_var(x; na_rm::Bool = false)
    a = collect(Float64, x)
    if na_rm
        a = _dropnan(a)
    elseif any(isnan, a)
        return NA
    end
    n = length(a)
    n <= 1 && return NA
    ln = F80(n)
    s = _LD0
    @inbounds for v in a
        s = s + F80(v)
    end
    tmp = s / ln
    if isfinite(Float64(tmp))
        s = _LD0
        @inbounds for v in a
            s = s + (F80(v) - tmp)
        end
        tmp = tmp + s / ln
    end
    xm = F80(Float64(tmp))
    s = _LD0
    @inbounds for v in a
        d = F80(v) - xm
        s = s + d * d
    end
    return Float64(s / F80(n - 1))
end

"`sd(x)` wie in R: `sqrt(var(x))`."
r_sd(x; na_rm::Bool = false) = r_sqrt(r_var(x; na_rm = na_rm))

"`sqrt` mit R-Semantik (negativ → NaN statt Fehler)."
r_sqrt(x::Float64) = x < 0 ? NaN : sqrt(x)

"`rowSums(m, na.rm)` für eine Liste gleich langer Spalten (long double je Zeile)."
function r_rowsums(cols::AbstractVector; na_rm::Bool = false)
    n = isempty(cols) ? 0 : length(cols[1])
    acc = fill(_LD0, n)
    for c in cols
        @inbounds for i in 1:n
            v = Float64(c[i])
            if na_rm && isnan(v)
                v = 0.0
            end
            acc[i] = acc[i] + F80(v)
        end
    end
    return Float64.(acc)
end

# ── Potenz wie R (R_POW / R_pow) ────────────────────────────────────────────
const _LIBM = Sys.islinux() ? "libm.so.6" :
              Sys.isapple() ? "/usr/lib/libSystem.B.dylib" :
              Sys.iswindows() ? "msvcrt.dll" : "libm"

@inline _libm_pow(x::Float64, y::Float64) = ccall((:pow, _LIBM), Float64, (Float64, Float64), x, y)

"Skalares `x ^ y` wie in R (`x^2` als `x*x`, sonst `pow()` der C-Bibliothek)."
function r_pow(x::Real, y::Real)
    x = Float64(x); y = Float64(y)
    y == 2.0 && return x * x
    (x == 1.0 || y == 0.0) && return 1.0
    if x == 0.0
        y > 0.0 && return 0.0
        y < 0.0 && return Inf
        return y
    end
    if isfinite(x) && isfinite(y)
        return _libm_pow(x, y)
    end
    (isnan(x) || isnan(y)) && return x + y
    if !isfinite(x)
        if x > 0
            return y < 0.0 ? 0.0 : Inf
        else
            if isfinite(y) && y == floor(y)
                return y < 0.0 ? 0.0 : (_isodd_float(y) ? x : -x)
            end
        end
    end
    if !isfinite(y)
        if x >= 0
            if y > 0
                return x >= 1 ? Inf : 0.0
            else
                return x < 1 ? Inf : 0.0
            end
        end
    end
    return NaN
end

_isodd_float(y::Float64) = abs(y) < 2.0^53 && isodd(Int64(y))

"Elementweises `x ^ y` mit R-Semantik."
r_pow_vec(x, y::Real) = Float64[r_pow(v, y) for v in x]

"`x %% 1` für Doubles wie R's `myfmod(x, 1)`."
function r_mod1(x::Float64)
    q = x / 1.0
    tmp = _ldq(x) - F80(floor(q)) * _LD1
    return Float64(tmp - floor(tmp / _LD1) * _LD1)
end

@inline function _r_nan2(a::Float64, b::Float64)
    isnan(a) && isna_strict(a) && return a      # NA schlägt NaN
    isnan(b) && return b
    return a
end
"R's `min(a, b)` für zwei Skalare (NA/NaN-Regeln wie R's `rmin`)."
@inline r_min2(a::Float64, b::Float64) = (isnan(a) || isnan(b)) ? _r_nan2(a, b) : (b < a ? b : a)
"R's `max(a, b)` für zwei Skalare."
@inline r_max2(a::Float64, b::Float64) = (isnan(a) || isnan(b)) ? _r_nan2(a, b) : (b > a ? b : a)

"`std::min(a, b)` aus C++ (`b < a ? b : a`)."
@inline cpp_min(a::Float64, b::Float64) = b < a ? b : a
"`std::max(a, b)` aus C++ (`a < b ? b : a`)."
@inline cpp_max(a::Float64, b::Float64) = a < b ? b : a
