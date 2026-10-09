# ─────────────────────────────────────────────────────────────────────────────
# Textausgabe wie R: sprintf() mit NA/NaN/Inf-Regeln, as.character(),
# format(x, digits = ...) und round(x, digits).
# ─────────────────────────────────────────────────────────────────────────────

const _FMT_CACHE = Dict{String,Printf.Format}()
_pf(spec::String) = get!(() -> Printf.Format(spec), _FMT_CACHE, spec)

# Nicht-endliche Zahl wie R's sprintf (Breite gilt, Genauigkeit nicht).
function _nonfinite(x::Float64, flags::String, width::Int)
    s = isnan(x) ? (isna_strict(x) ? "NA" : "NaN") :
        x > 0 ? (occursin('+', flags) ? "+Inf" : (occursin(' ', flags) ? " Inf" : "Inf")) : "-Inf"
    length(s) >= width && return s
    return occursin('-', flags) ? rpad(s, width) : lpad(s, width)
end

_as_float(x::Real) = Float64(x)
_as_float(::Missing) = NA
_as_float(::Nothing) = NA

"Formatiert genau eine Konvertierung (`%…f`, `%…d`, `%…s` …) wie R."
function _rspec(flags::String, width::Int, prec::String, conv::Char, @nospecialize(x))
    spec = "%" * flags * (width > 0 ? string(width) : "") * prec * conv
    if conv == 's'
        s = x isa AbstractString ? String(x) : x isa Bool ? (x ? "TRUE" : "FALSE") :
            (x isa Real || x === missing || x === nothing) ? r_num_str(x) : string(x)
        return Printf.format(_pf(spec), s)
    end
    if conv in ('d', 'i')
        x isa Bool && return Printf.format(_pf(spec), Int(x))
        x isa Integer && return Printf.format(_pf(spec), x)
        v = _as_float(x)
        isfinite(v) || return _nonfinite(v, flags, width)
        v == round(v) || error("invalid format '$(spec)'; use format %f, %e, %g or %a for numeric objects")
        return Printf.format(_pf(spec), Int64(v))
    end
    v = _as_float(x)
    isfinite(v) || return _nonfinite(v, flags, width)
    return Printf.format(_pf(spec), v)
end

"R's `sprintf(fmt, ...)` für skalare Argumente."
function rsprintf(fmt::AbstractString, @nospecialize(args...))
    out = IOBuffer()
    i = firstindex(fmt)
    k = 0
    n = lastindex(fmt)
    while i <= n
        c = fmt[i]
        if c != '%'
            write(out, c)
            i = nextind(fmt, i)
            continue
        end
        j = nextind(fmt, i)
        if fmt[j] == '%'
            write(out, '%')
            i = nextind(fmt, j)
            continue
        end
        fl = IOBuffer()
        while fmt[j] in ('-', '+', ' ', '0', '#')
            write(fl, fmt[j]); j = nextind(fmt, j)
        end
        w = 0
        while isdigit(fmt[j])
            w = 10w + (fmt[j] - '0'); j = nextind(fmt, j)
        end
        pr = ""
        if fmt[j] == '.'
            p0 = j; j = nextind(fmt, j)
            while isdigit(fmt[j]); j = nextind(fmt, j); end
            pr = String(fmt[p0:prevind(fmt, j)])
        end
        conv = fmt[j]
        k += 1
        write(out, _rspec(String(take!(fl)), w, pr, conv, args[k]))
        i = nextind(fmt, j)
    end
    return String(take!(out))
end

"`as.character(x)` für Zahlen wie R (15 signifikante Stellen)."
function r_num_str(x)
    x === missing && return "NA"
    x === nothing && return "NULL"
    x isa Bool && return x ? "TRUE" : "FALSE"
    x isa Integer && return string(x)
    xf = Float64(x)
    isnan(xf) && return isna_strict(xf) ? "NA" : "NaN"
    isinf(xf) && return xf > 0 ? "Inf" : "-Inf"
    if xf == trunc(xf) && abs(xf) < 1e15
        return string(Int64(xf))
    end
    s = Printf.format(_pf("%.15g"), xf)
    if occursin('e', s)
        mant, ex = split(s, 'e')
        ei = parse(Int, ex)
        s = string(mant, "e", ei < 0 ? "-" : "+", lpad(string(abs(ei)), 2, '0'))
    end
    return s
end

"`format(x, digits = d)` für einen Skalar wie R's `formatReal` (scipen = 0)."
function r_format_digits(x::Real, digits::Int = 7)
    v = Float64(x)
    isnan(v) && return isna_strict(v) ? "NA" : "NaN"
    isinf(v) && return v > 0 ? "Inf" : "-Inf"
    v == 0 && return "0"
    neg = v < 0
    s = Printf.format(_pf("%." * string(digits - 1) * "e"), abs(v))
    mant, ex = split(s, 'e')
    kp = parse(Int, ex)
    md = replace(mant, "." => "")
    nsig = length(rstrip(md, '0'))
    nsig = max(nsig, 1)
    # Breite in Fixnotation
    left = kp >= 0 ? kp + 1 : 1
    rgt = max(0, nsig - kp - 1)
    wf = neg + left + (rgt > 0 ? rgt + 1 : 0)
    # Breite in wissenschaftlicher Notation
    ws = neg + (nsig > 1 ? nsig + 1 : 1) + (abs(kp) >= 100 ? 5 : 4)
    if wf <= ws
        return Printf.format(_pf("%." * string(rgt) * "f"), v)
    end
    es = Printf.format(_pf("%." * string(nsig - 1) * "e"), v)
    return es
end

"R's `round(x, digits)` (Algorithmus seit R 4.0.0)."
function r_round(x::Float64, digits::Real = 0)
    (isnan(x) || isnan(digits)) && return x + Float64(digits)
    (!isfinite(x) || digits > 323 || x == 0.0) && return x
    digits < -308 && return 0.0
    digits == 0 && return round(x, RoundNearest)
    dig = Int(floor(digits + 0.5))
    sgn = 1.0
    if x < 0.0
        sgn = -1.0; x = -x
    end
    l10x = 0.301029995663981195213738894724 * (0.5 + exponent(x))   # wie R: M_LOG10_2 * (0.5 + logb(x))
    l10x + dig > 15 && return sgn * x
    if dig <= 308
        pow10 = _pow_di(10.0, dig)
        x10 = x * pow10
        i10 = floor(x10)
        xd = i10 / pow10
        xu = ceil(x10) / pow10
    else
        p10 = _pow_di(10.0, dig - 308)
        pow10 = _pow_di(10.0, 308)
        x10 = (x * pow10) * p10
        i10 = floor(x10)
        xd = i10 / pow10 / p10
        xu = ceil(x10) / pow10 / p10
    end
    du = xu - x
    dd = x - xd
    return sgn * ((du < dd || (du == dd && rem(i10, 2.0) == 1)) ? xu : xd)
end

"R's `R_pow_di` (wiederholtes Quadrieren wie in R's arithmetic.c)."
function _pow_di(x::Float64, n::Int)
    xn = 1.0
    isnan(x) && return x
    if n != 0
        isfinite(x) || return r_pow(x, Float64(n))
        is_neg = n < 0
        is_neg && (n = -n)
        while true
            (n & 1) != 0 && (xn *= x)
            n >>= 1
            n != 0 || break
            x *= x
        end
        is_neg && (xn = 1.0 / xn)
    end
    return xn
end
