# ─────────────────────────────────────────────────────────────────────────────
# Datumshelfer. Intern werden Daten wie in R als Tage seit 1970-01-01 geführt.
# ─────────────────────────────────────────────────────────────────────────────

const _EPOCH = Dates.value(Date(1970, 1, 1))

days_from_civil(y::Integer, m::Integer, d::Integer) = Dates.value(Date(y, m, d)) - _EPOCH
from_days(z::Integer) = Date(Dates.UTD(Int64(z) + _EPOCH))
ymd(z::Integer) = Dates.yearmonthday(from_days(z))
year_of(z::Integer) = Dates.year(from_days(z))
fmt_date(z::Integer) = Dates.format(from_days(z), dateformat"yyyy-mm-dd")
is_leap(y::Integer) = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

function valid_civil(y::Integer, m::Integer, d::Integer)
    (1 <= m <= 12) || return nothing
    (1 <= d <= Dates.daysinmonth(y, m)) || return nothing
    return days_from_civil(y, m, d)
end

"Konvertiert Date/DateTime/String/Integer in Tage seit 1970-01-01."
to_days(d::Date) = Dates.value(d) - _EPOCH
to_days(d::DateTime) = to_days(Date(d))
to_days(d::Integer) = Int(d)
to_days(d::AbstractFloat) = Int(trunc(d))
function to_days(d::AbstractString)
    s = strip(d)
    length(s) >= 10 || throw(ArgumentError("Kann \"$d\" nicht als Datum interpretieren"))
    return to_days(Date(s[1:10], dateformat"yyyy-mm-dd"))
end
to_days(d) = throw(ArgumentError("Kann $(repr(d)) nicht als Datum interpretieren"))

function first_of_month(z::Integer)
    y, m, _ = ymd(z)
    return days_from_civil(y, m, 1)
end

function add_months_first(z_first::Integer, k::Integer)
    y, m, _ = ymd(z_first)
    tot = (y * 12 + (m - 1)) + k
    return days_from_civil(fld(tot, 12), mod(tot, 12) + 1, 1)
end

function ym_key(z::Integer)
    y, m, _ = ymd(z)
    return y * 12 + m
end

"`as.Date(paste(y, m, d, sep = '-'), format = '%Y-%m-%d')` wie R (ungültig → nothing)."
function r_strptime_ymd(y, m, d)
    ys, ms, ds = r_num_str(y), r_num_str(m), r_num_str(d)
    my = match(r"^(\d{1,4})$", ys)
    my === nothing && return nothing
    mm = match(r"^(\d{1,2})$", ms)
    mm === nothing && return nothing
    md = match(r"^(\d{1,2})", ds)
    md === nothing && return nothing
    return valid_civil(parse(Int, my.captures[1]), parse(Int, mm.captures[1]), parse(Int, md.captures[1]))
end
