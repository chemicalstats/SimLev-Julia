# ─────────────────────────────────────────────────────────────────────────────
# Backtest-Engine (Port von simulation() aus simulation.R)
#
# Die Struktur folgt bewusst eng dem R-Original, damit beide Implementierungen
# Zeile für Zeile vergleichbar bleiben und bitgleich rechnen.
# ─────────────────────────────────────────────────────────────────────────────

# ── Flag-Hilfsfunktionen ────────────────────────────────────────────────────

function _calculate_dates_flags(mode::Bool, span, unit, days, dates::Vector{Int}, value, anchor,
                                start_date, skip_start::Bool, liquidate::Bool)
    n = length(dates)
    if !mode || unit === nothing || (value !== nothing && value <= 0)
        return falses(n)
    end
    span === nothing && (span = 1)
    unit = match_arg(unit, ("month", "quarter", "year"), "unit")
    anchor = match_arg(anchor, ("start", "end"), "anchor")
    dmin, dmax = minimum(dates), maximum(dates)
    start = start_date === nothing ? dmin : to_days(start_date)
    day_list = days === nothing ? nothing : (days isa Union{AbstractVector,Tuple} ? collect(days) : [days])
    schedule = Float64[]
    _wrong_sign() = throw(ArgumentError("wrong sign in 'by' argument"))

    if unit == "month" || unit == "quarter"
        step = Int(span) * (unit == "quarter" ? 3 : 1)
        f = first_of_month(start)
        f > dmax && _wrong_sign()
        base_seq = Int[]
        k = 0
        while true
            z = add_months_first(f, k * step)
            z > dmax && break
            push!(base_seq, z)
            k += 1
        end
        if day_list === nothing
            append!(schedule, Float64.(base_seq))
        else
            for z in base_seq
                yr, mon, _ = ymd(z)
                for dd in day_list
                    if anchor == "start"
                        r = r_strptime_ymd(yr, mon, dd)
                        push!(schedule, r === nothing ? NA : Float64(r))
                    else
                        if unit == "month"
                            e = mon == 12 ? days_from_civil(yr + 1, 1, 1) - 1 : days_from_civil(yr, mon + 1, 1) - 1
                        else
                            em, ey = mon + 3, yr
                            if em > 12
                                em -= 12; ey = yr + 1
                            end
                            e = days_from_civil(ey, em, 1) - 1
                        end
                        push!(schedule, Float64(e) - (Float64(dd) - 1))
                    end
                end
            end
        end
    else
        y0 = year_of(start)
        days_from_civil(y0, 1, 1) > dmax && _wrong_sign()
        base_years = Int[]
        y = y0
        while days_from_civil(y, 1, 1) <= dmax
            push!(base_years, y)
            y += Int(span)
        end
        if day_list === nothing
            append!(schedule, Float64[days_from_civil(y, 1, 1) for y in base_years])
        else
            for y in base_years, dd in day_list
                if anchor == "start"
                    r = r_strptime_ymd(y, 1, dd)
                    push!(schedule, r === nothing ? NA : Float64(r))
                else
                    push!(schedule, Float64(days_from_civil(y, 12, 31)) - (Float64(dd) - 1))
                end
            end
        end
    end
    date_set = Set(dates)
    sched = [s for s in schedule if !isnan(s) && s == trunc(s) && Int(s) in date_set]
    skip_start && filter!(s -> s != dmin, sched)
    liquidate && filter!(s -> s != dmax, sched)
    sset = Set(Int(s) for s in sched)
    return BitVector([z in sset for z in dates])
end

function _calculate_split_flags(sim::Sim, base::Float64, mode::Bool, n::Int, split_thresh)
    (!mode || split_thresh === nothing) && return falses(n)
    lo, hi = Float64(split_thresh[1]), Float64(split_thresh[2])
    flag = falses(n)
    for a in eachindex(sim.names)
        prices = copy(sim.market[a].asset_price)
        for i in 1:n
            cp = prices[i]
            if cp > hi
                flag[i] = true
                ratio = cp / base
                for k in i:n
                    prices[k] = prices[k] / ratio
                end
            elseif cp < lo
                flag[i] = true
                ratio = base / cp
                for k in i:n
                    prices[k] = prices[k] * ratio
                end
            end
        end
    end
    return flag
end

function _shift_off_filled(flags::BitVector, filled::BitVector, mon::Vector{Int})
    hit = findall(flags .& filled)
    isempty(hit) && return flags
    flags = copy(flags)
    n = length(flags)
    for i in hit
        j = i + 1
        while j <= n && filled[j]
            j += 1
        end
        if j > n || mon[j] != mon[i]
            j = i - 1
            while j >= 1 && filled[j]
                j -= 1
            end
        end
        flags[i] = false
        (1 <= j <= n) && (flags[j] = true)
    end
    return flags
end

# ── Handels- und Steuerfunktionen ───────────────────────────────────────────

@inline _apply_spread(price::Float64, spread::Float64, buy::Bool) =
    buy ? price * (1 + spread / 2) : price * (1 - spread / 2)

function _calculate_buy_signal(sim::Sim, a::Int, index::Int)
    info = sim.assets[a]; st = sim.status[a]
    sig = false
    if info.style == "signal" && sig_truthy(sim.market[a].signal_buy, index) && st.money > 0 && st.count == 0
        sig = true
    end
    if info.style == "bnh" && st.money > 0
        sig = true
    end
    return sig
end

function _calculate_sell_signal(sim::Sim, a::Int, index::Int)
    info = sim.assets[a]
    sig = false
    if info.style == "signal" && sig_truthy(sim.market[a].signal_sell, index) && sim.status[a].count > 0
        sig = true
    end
    info.style == "bnh" && (sig = false)
    return sig
end

"Laufzeitparameter, die viele Hilfsfunktionen brauchen."
struct Ctx
    tax_mode::String
    tax_rate::Float64
    effective_tax_rate::Float64
    marginal_tax_rate::Union{Nothing,Float64}
    private_sale_threshold::Float64
    use_spb::Bool
    fractions::Bool
    details::Bool
    io::IO
end

function _perform_trade_buy!(sim::Sim, a::Int, index::Int, reason::String, ctx::Ctx; count = nothing)
    mk = sim.market[a]
    market_price = mk.asset_price[index]
    if isnan(market_price) || market_price <= 0
        @warn rsprintf("Invalid market price (%.4f) for %s on %s - skipping trade",
                       market_price, sim.names[a], fmt_date(mk.asset_day[index]))
        return nothing
    end
    trade_price = _apply_spread(market_price, mk.spread_rate, true)
    if count === nothing
        money = sim.status[a].money
        trade_count = ctx.fractions ? money / trade_price : floor(money / trade_price)
    else
        trade_count = Float64(count)
    end
    trade_count <= 0 && return nothing
    perform_trade_buy_cpp!(sim, a, index, trade_count, trade_price, market_price)
    if ctx.details
        print(ctx.io, rsprintf("%s\tBuying %.2fx %s at %.2f EUR per share on %s\n",
                               reason, trade_count, sim.names[a], trade_price, fmt_date(mk.asset_day[index])))
    end
    return nothing
end

function _perform_trade_sell!(sim::Sim, a::Int, index::Int, tax_mode::String, tax_regime::Union{Nothing,String},
                              reason::String, ctx::Ctx; count = nothing, price = nothing)
    effective_tax_rate = ctx.effective_tax_rate
    mk = sim.market[a]
    io = ctx.io
    market_price = mk.asset_price[index]
    trade_price = _apply_spread(market_price, mk.spread_rate, false)
    current_date = mk.asset_day[index]
    available = sim.status[a].count
    if count === nothing
        trade_count = available
    else
        if count > available
            @warn rsprintf("Requested sell count (%.4f) exceeds available (%.4f) for %s. Selling all.",
                           count, available, sim.names[a])
        end
        trade_count = r_min2(Float64(count), available)
    end
    trade_count <= 0 && return nothing

    tr = sim.trades[a]
    totals = sim.totals
    fifo_price = (price === nothing && tax_mode == "person") ?
                 calculate_fifo_price(tr.buys, trade_count, tr.fifo_front) :
                 (price === nothing ? 0.0 : Float64(price))
    trade_gain = (trade_price - fifo_price) * trade_count
    capital_gains_tax = 0.0
    regime = tax_regime === nothing ? "none" : tax_regime
    lot = nothing

    if tax_mode == "person"
        regime == "none" && (regime = sim.assets[a].tax_regime)
        if regime == "investment_fund"
            bonus = sim.assets[a].bonus
            vp_paid = calculate_fifo_vorabpauschale(tr.buys, trade_count, tr.fifo_front)
            adjusted = trade_gain - vp_paid
            res = p20_tax!(adjusted, bonus, totals, effective_tax_rate, ctx.use_spb)
            capital_gains_tax = res.tax
            if ctx.details
                vp_paid > 0 && print(io, rsprintf("\t\t=> Vorabpauschale-Anrechnung (§ 19 InvStG): %.2f EUR\n", vp_paid))
                res.spb_used > 0 && print(io, rsprintf("\t\t=> Sparerpauschbetrag: %.2f EUR (verbleibend: %.2f EUR)\n",
                                                       res.spb_used, totals.sparer_pauschbetrag_remaining))
            end
        elseif regime == "capital_gains"
            res = p20_tax!(trade_gain, 0.0, totals, effective_tax_rate, ctx.use_spb)
            capital_gains_tax = res.tax
        elseif regime == "private_sale"
            lot = calculate_private_sale_tax(tr.buys, tr.fifo_front, trade_count, trade_price, current_date)
            if ctx.details
                lot.exempt_gain > 0 && print(io, rsprintf("\t\t=> Tax-exempt gain (held > 1 year): %.2f EUR\n", lot.exempt_gain))
                lot.exempt_loss > 0 && print(io, rsprintf("\t\t=> Non-deductible loss (held > 1 year): %.2f EUR\n", lot.exempt_loss))
            end
            if lot.taxable_gain > 0
                totals.private_sale_gains_ytd = totals.private_sale_gains_ytd + lot.taxable_gain
                ctx.details && print(io, rsprintf("\t\t=> Taxable gain (held < 1 year): %.2f EUR (YTD total: %.2f EUR)\n",
                                                  lot.taxable_gain, totals.private_sale_gains_ytd))
            end
            if lot.taxable_loss > 0
                totals.private_sale_losses_ytd = totals.private_sale_losses_ytd + lot.taxable_loss
                ctx.details && print(io, rsprintf("\t\t=> Deductible loss (held < 1 year): %.2f EUR (YTD total: %.2f EUR)\n",
                                                  lot.taxable_loss, totals.private_sale_losses_ytd))
            end
            capital_gains_tax = 0.0
        end
    end

    calculate_sell_report!(sim, a, index, trade_count, trade_price, market_price, capital_gains_tax)
    tax_mode == "person" && fifo_consume!(sim, a, trade_count)

    if ctx.details
        print(io, rsprintf("%s\tSelling %.2fx %s at %.2f EUR per share on %s\n",
                           reason, trade_count, sim.names[a], trade_price, fmt_date(current_date)))
        if tax_mode == "person" && !(regime in ("none", "private_sale"))
            print(io, rsprintf("\t\t=> Trade %s: %.2f EUR; Tax: %.2f EUR\n",
                               trade_gain < 0 ? "loss" : "gain", trade_gain, capital_gains_tax))
        end
    end
    person = tax_mode == "person"
    push!(tr.sells, SellEntry(current_date, trade_count, trade_price,
                              person ? trade_gain : NA, person ? capital_gains_tax : NA,
                              person ? regime : nothing, person && regime == "private_sale",
                              (person && regime == "private_sale" && lot !== nothing) ? lot.exempt_gain : NA))
    return nothing
end

function _calculate_sell_count(sim::Sim, a::Int, target::Float64, index::Int, tax_mode::String,
                               tax_rate::Float64, tax_regime::Union{Nothing,String}, fractions::Bool)
    mk = sim.market[a]
    trade_price = _apply_spread(mk.asset_price[index], mk.spread_rate, false)
    total_shares = sim.status[a].count
    total_shares <= 0 && return (sell_count = 0.0, fifo_price = 0.0)
    target <= 0 && return (sell_count = 0.0, fifo_price = 0.0)
    tr = sim.trades[a]
    regime = tax_regime === nothing ? sim.assets[a].tax_regime : tax_regime
    regime = tax_mode == "person" ? regime : "none"
    bonus = regime == "investment_fund" ? sim.assets[a].bonus : 0.0
    return sell_count(tr.buys, tr.fifo_front, target, trade_price, total_shares, fractions,
                      get(REGIME_CODE, regime, 0), bonus, sim.totals.loss_capital_gains, tax_rate)
end

function _calculate_flat_rate(sim::Sim, a::Int, index::Int, dates::Vector{Int}, tax_regime)
    regime = tax_regime === nothing ? sim.assets[a].tax_regime : tax_regime
    empty = (total_vp = 0.0, lot_indices = Int[], lot_vps = Float64[])
    regime != "investment_fund" && return empty
    di = dates[index]
    yr = year_of(di)
    soy = days_from_civil(yr, 1, 1)
    eoy = days_from_civil(yr, 12, 31)
    raw = sim.market[a].base_rates[index] / 100
    base_rate = r_max2(0.0, raw)
    base_rate <= 0 && return empty
    prices = sim.market[a].asset_price
    market_price = prices[index]
    ysi = max(1, (soy - dates[1]) + 1)
    year_start_price = prices[ysi]
    tr = sim.trades[a]
    return flat_rate(tr.buys, tr.fifo_front, base_rate, year_start_price, market_price, soy, eoy)
end

function _calculate_fund_fees(sim::Sim, index::Int, dates::Vector{Int}, funds_fee::Float64,
                              bonus_fee::Float64, details::Bool, io::IO)
    event_date = days_from_civil(year_of(dates[index]), 1, 1)
    cur = dates[index]
    idx = findall(z -> event_date <= z <= cur, dates)
    isempty(idx) && return (total_fees = 0.0, total_value = sim.totals.total_value)
    daily_rate = r_pow(funds_fee / 100 + 1, 1 / length(idx)) - 1
    flat = Float64[]
    for a in eachindex(sim.names)
        tot = sim.report[a].total
        for i in idx
            push!(flat, tot[i] * daily_rate)
        end
    end
    basic_value = r_sum(flat; na_rm = true)
    total_value = sim.totals.total_value
    market_value = r_sum([st.total for st in sim.status]; na_rm = true)
    if market_value > total_value
        bonus_value = (market_value - total_value) * (bonus_fee / 100)
        total_value = market_value
    else
        bonus_value = 0.0
    end
    total_fees = basic_value + bonus_value
    if details
        print(io, rsprintf("Funds Event:\tPaying funds fees of %.2f EUR on %s\n\t\t=> Basis fee: %.2f EUR; Bonus fee: %.2f EUR\n",
                           total_fees, fmt_date(cur), basic_value, bonus_value))
    end
    return (total_fees = total_fees, total_value = total_value)
end

function _split!(sim::Sim, a::Int, ratio::Float64, index::Int, fractions::Bool, forward::Bool)
    st = sim.status[a]
    current_count = st.count
    current_price = st.price
    current_worth = st.worth
    if forward
        split_count = current_count * ratio
        split_price = current_price / ratio
    else
        split_count = current_count / ratio
        split_price = current_price * ratio
    end
    split_worth = current_worth
    if !fractions && r_mod1(split_count) != 0
        split_fract = r_mod1(split_count)
        split_count = floor(split_count)
        st.money = st.money + split_fract * split_price
    end
    tr = sim.trades[a]
    for b in tr.buys
        b.remaining <= 0 && continue
        if forward
            new_count = b.count * ratio
            new_price = b.price / ratio
            new_remaining = b.remaining * ratio
            new_original = b.original * ratio
        else
            new_count = b.count / ratio
            new_price = b.price * ratio
            new_remaining = b.remaining / ratio
            new_original = b.original / ratio
        end
        if !fractions && r_mod1(new_count) != 0
            fract = r_mod1(new_count)
            new_count = floor(new_count)
            new_remaining = floor(new_remaining)
            new_original = floor(new_original)
            st.money = st.money + fract * new_price
        end
        b.count = new_count
        b.price = new_price
        b.remaining = new_remaining
        b.original = new_original
    end
    tr.fifo_front = update_fifo_front(tr.buys, 1)
    st.count = split_count
    st.price = split_price
    st.worth = split_worth
    prices = sim.market[a].asset_price
    if index <= length(prices)
        if forward
            for k in index:length(prices)
                prices[k] = prices[k] / ratio
            end
        else
            for k in index:length(prices)
                prices[k] = prices[k] * ratio
            end
        end
    end
    return nothing
end

function _perform_asset_split!(sim::Sim, a::Int, ratio::Float64, index::Int, forward::Bool,
                               fractions::Bool, details::Bool, current_date, io::IO)
    ratio <= 0 && throw(ArgumentError("'ratio' must be positive"))
    _split!(sim, a, ratio, index, fractions, forward)
    if details
        rs = r_format_digits(ratio, 5)
        desc = forward ? "1 : " * rs : rs * " : 1"
        action = forward ? "Splitting" : "Reverse splitting"
        ds = current_date === nothing ? "(date not provided)" : fmt_date(current_date)
        print(io, rsprintf("Split Event:\t%s %s via %s on %s\n", action, sim.names[a], desc, ds))
    end
    return nothing
end

const _RULE = "══════════════════════════════════════════════════════════════"

function _handle_year_change!(sim::Sim, current_date::Int, marginal_tax_rate, private_sale_threshold::Float64,
                              sparer_pauschbetrag::Float64, use_spb::Bool, soli_factor_income::Float64,
                              effective_tax_rate::Float64, details::Bool, io::IO)
    t = sim.totals
    current_year = year_of(current_date)
    stored_year = t.current_year
    current_year == stored_year && return nothing
    if details
        print(io, "\n" * _RULE * "\n")
        print(io, rsprintf("  JAHRESWECHSEL: %d -> %d\n", stored_year, current_year))
        print(io, _RULE * "\n")
    end
    ytd_gains = t.private_sale_gains_ytd
    ytd_losses = t.private_sale_losses_ytd
    internal_offset = r_min2(ytd_gains, ytd_losses)
    net_ytd_gains = ytd_gains - internal_offset
    net_ytd_losses = ytd_losses - internal_offset
    carry = 0.0
    if net_ytd_gains > 0 && t.loss_private_sales > 0
        carry = r_min2(net_ytd_gains, t.loss_private_sales)
        t.loss_private_sales = t.loss_private_sales - carry
        net_ytd_gains = net_ytd_gains - carry
        if details && carry > 0
            print(io, rsprintf("  § 23 EStG: Verlustvortrag verwendet: %.2f EUR\n", carry))
            print(io, rsprintf("             Verbleibender Vortrag: %.2f EUR\n", t.loss_private_sales))
        end
    end
    net_gain = net_ytd_gains
    if details
        print(io, rsprintf("  § 23 EStG Jahresübersicht %d:\n", stored_year))
        print(io, rsprintf("    Bruttogewinne (< 1 Jahr):    %10.2f EUR\n", ytd_gains))
        print(io, rsprintf("    Bruttoverluste (< 1 Jahr):   %10.2f EUR\n", ytd_losses))
        print(io, rsprintf("    Interne Verrechnung:         %10.2f EUR\n", internal_offset))
        print(io, rsprintf("    Verlustvortrag-Verrechnung:  %10.2f EUR\n", carry))
        print(io, "    ─────────────────────────────────────────\n")
        print(io, rsprintf("    Netto-Ergebnis:              %10.2f EUR\n", net_gain - net_ytd_losses))
    end
    if net_gain > private_sale_threshold
        mtr = marginal_tax_rate
        if mtr === nothing
            @warn "§ 23 EStG: Gewinne ($(r_num_str(r_round(net_gain, 2))) EUR) über Freigrenze " *
                  "($(r_num_str(private_sale_threshold)) EUR), aber 'marginal_tax_rate' nicht gesetzt.\n" *
                  "Verwende 42% (Spitzensteuersatz)."
            mtr = 0.42
        end
        tax_due = net_gain * mtr * soli_factor_income
        t.total_taxes = t.total_taxes + tax_due
        if details
            print(io, "\n  ⚠ FREIGRENZE ÜBERSCHRITTEN!\n")
            print(io, rsprintf("    Netto-Gewinn %.2f EUR > Freigrenze %.2f EUR\n", net_gain, private_sale_threshold))
            print(io, "    → GESAMTER Gewinn steuerpflichtig (Freigrenze, kein Freibetrag!)\n")
            soli = soli_factor_income > 1 ? rsprintf(" + %.1f%%%% Soli", (soli_factor_income - 1) * 100) : ""
            print(io, rsprintf("    → Steuersatz: %.1f%%%s\n", mtr * 100, soli))
            print(io, rsprintf("    → Steuerlast: %.2f EUR\n", tax_due))
        end
    elseif net_ytd_losses > 0
        t.loss_private_sales = t.loss_private_sales + net_ytd_losses
        if details
            print(io, rsprintf("\n  Nettoverlust %.2f EUR → Vortrag ins nächste Jahr\n", net_ytd_losses))
            print(io, rsprintf("  Gesamter Verlustvortrag: %.2f EUR\n", t.loss_private_sales))
        end
    elseif net_gain > 0
        details && print(io, rsprintf("\n  ✓ Netto-Gewinn %.2f EUR ≤ Freigrenze %.2f EUR → STEUERFREI\n",
                                      net_gain, private_sale_threshold))
    else
        details && print(io, rsprintf("\n  Keine steuerpflichtigen § 23 Vorgänge in %d\n", stored_year))
    end

    if details && use_spb
        spb_annual = t.sparer_pauschbetrag_annual
        spb_remaining = t.sparer_pauschbetrag_remaining
        print(io, rsprintf("\n  Sparerpauschbetrag %d:\n", stored_year))
        print(io, rsprintf("    Jahresbetrag:    %10.2f EUR\n", spb_annual))
        print(io, rsprintf("    Verwendet:       %10.2f EUR\n", spb_annual - spb_remaining))
        print(io, rsprintf("    Verfallen:       %10.2f EUR\n", spb_remaining))
    end

    unused_loss = r_max2(0.0, t.cgt_loss_added_ytd - t.cgt_loss_used_ytd)
    unused_loss = r_min2(unused_loss, t.loss_capital_gains)
    refund_base = r_min2(unused_loss, t.cgt_base_taxed_ytd)
    if refund_base > 0 && effective_tax_rate > 0
        refund = refund_base * effective_tax_rate
        w = [st.actual for st in sim.status]
        sw = r_sum(w)
        if sw > 0
            sw2 = r_sum(w)
            w = w ./ sw2
        else
            w = fill(1 / length(w), length(w))
        end
        for (k, st) in enumerate(sim.status)
            st.money = st.money + refund * w[k]
        end
        t.total_taxes = t.total_taxes - refund
        t.loss_capital_gains = t.loss_capital_gains - refund_base
        details && print(io, rsprintf("  § 20 EStG: Unterjaehrige Verlustverrechnung -> Erstattung %.2f EUR in den Geldbestand\n", refund))
    end
    t.private_sale_gains_ytd = 0.0
    t.private_sale_losses_ytd = 0.0
    t.cgt_base_taxed_ytd = 0.0
    t.cgt_loss_added_ytd = 0.0
    t.cgt_loss_used_ytd = 0.0
    use_spb && (t.sparer_pauschbetrag_remaining = sparer_pauschbetrag)
    t.current_year = current_year
    if details
        print(io, rsprintf("\n  Tracker zurückgesetzt für Jahr %d\n", current_year))
        print(io, _RULE * "\n\n")
    end
    return nothing
end

# ── Kennzahlen ──────────────────────────────────────────────────────────────

function _calculate_skewness(x::Vector{Float64})
    x = filter(!isnan, x)
    n = length(x)
    n < 3 && return NA
    mean_x = r_mean(x)
    sd_x = r_sd(x)
    sd_x == 0 && return NA
    nf = Float64(n)
    return (nf / ((nf - 1) * (nf - 2))) * r_sum(r_pow_vec(x .- mean_x, 3.0)) / r_pow(sd_x, 3.0)
end

function _calculate_kurtosis(x::Vector{Float64}; excess::Bool = true)
    x = filter(!isnan, x)
    n = length(x)
    n < 4 && return NA
    mean_x = r_mean(x)
    sd_x = r_sd(x)
    sd_x == 0 && return NA
    nf = Float64(n)
    kurt = (nf * (nf + 1)) / ((nf - 1) * (nf - 2) * (nf - 3)) * r_sum(r_pow_vec(x .- mean_x, 4.0)) / r_pow(sd_x, 4.0)
    if excess
        kurt = kurt - (3 * r_pow(nf - 1, 2.0)) / ((nf - 2) * (nf - 3))
    end
    return kurt
end

# R: pmax(0, x) – NA/NaN bleiben erhalten
_pmax0(x::Float64) = isnan(x) ? x : (x > 0.0 ? x : 0.0)

_calculate_partials(r::Vector{Float64}, lower::Bool) =
    r_mean(lower ? [_pmax0(-v) for v in r] : [_pmax0(v) for v in r]; na_rm = true)

"R's `cummax()` (NA/NaN pflanzen sich fort)."
function r_cummax(x::Vector{Float64})
    out = similar(x)
    m = -Inf
    @inbounds for i in eachindex(x)
        v = x[i]
        m = (isnan(v) || isnan(m)) ? m + v : (m > v ? m : v)
        out[i] = m
    end
    return out
end

# ── Hilfsfunktionen für Argumente ───────────────────────────────────────────

_isnull_num(x) = x === nothing || x === missing || (x isa AbstractFloat && isnan(x))

function _strategy_items(strategy)
    if strategy isa Strategy
        return [(n, as_dict(a)) for (n, a) in strategy]
    end
    items = Tuple{String,Dict{String,Any}}[]
    for (k, v) in _pairs(strategy)
        d = v isa AssetConfig ? as_dict(v) :
            Dict{String,Any}(String(string(kk)) => vv for (kk, vv) in _pairs(v))
        push!(items, (String(string(k)), d))
    end
    return items
end

_dget(d::Dict{String,Any}, k::String, default = nothing) = (v = get(d, k, nothing); v === nothing ? default : v)

function _event_weight_map(ew)
    ew === nothing && return nothing
    return Dict{String,Union{Nothing,String}}(String(string(k)) => (v === nothing ? nothing : String(string(v)))
                                              for (k, v) in _pairs(ew))
end

# ═══════════════════════════════════════════════════════════════════════════
# Hauptfunktion
# ═══════════════════════════════════════════════════════════════════════════

const _SIM_DEFAULTS = (
    start_value = 10000, spread = nothing, details = false, liquidate = false,
    dca_mode = false, dca_value = nothing, dca_span = nothing, dca_days = nothing,
    dca_unit = ("month", "quarter", "year"), dca_anchor = ("start", "end"), dca_start = nothing, dca_skip = false,
    balance_mode = false, balance_span = nothing, balance_days = nothing,
    balance_unit = ("month", "quarter", "year"), balance_anchor = ("start", "end"), balance_start = nothing,
    balance_skip = false, balance_dca = false, balance_thresh = nothing,
    tax_mode = ("none", "person", "funds"), tax_rate = 26.375, marginal_tax_rate = nothing,
    use_guenstigerpruefung = false, private_sale_threshold = 1000, sparer_pauschbetrag = 1000,
    use_sparer_pauschbetrag = true, include_soli_on_income_tax = false, soli_rate_income_tax = 5.5,
    base_rate = nothing, base_rate_flex = false, base_rate_data = nothing,
    funds_fee = 0.95, bonus_fee = 5, fractions = true, risk_free = 0, split_mode = false, split_thresh = nothing,
    event_col = nothing, event_mode = ("additional", "replace"), event_weight = nothing, io = stdout)

"""
    simulation(data, strategy; start_value = 10000, details = false, liquidate = false,
               dca_mode = false, dca_value = nothing, dca_span = nothing, dca_days = nothing,
               dca_unit = "month", dca_anchor = "start", dca_start = nothing, dca_skip = false,
               balance_mode = false, balance_span = nothing, balance_days = nothing,
               balance_unit = "month", balance_anchor = "start", balance_start = nothing,
               balance_skip = false, balance_dca = false, balance_thresh = nothing,
               tax_mode = "none", tax_rate = 26.375, marginal_tax_rate = nothing,
               use_guenstigerpruefung = false, private_sale_threshold = 1000,
               sparer_pauschbetrag = 1000, use_sparer_pauschbetrag = true,
               include_soli_on_income_tax = false, soli_rate_income_tax = 5.5,
               base_rate = nothing, base_rate_flex = false, base_rate_data = nothing,
               funds_fee = 0.95, bonus_fee = 5, fractions = true, risk_free = 0,
               split_mode = false, split_thresh = nothing, event_col = nothing,
               event_mode = "additional", event_weight = nothing, io = stdout)

Backtestet eine Strategie auf täglichen Preisreihen und gibt ein
[`SimLevResult`](@ref) zurück.

`data` ist eine Tabelle mit einer Spalte `date` (Date, DateTime, ISO-String
oder Tage seit 1970-01-01) und je einer Preisspalte pro Asset; akzeptiert
werden NamedTuples von Vektoren, Dicts und Tabellen wie ein DataFrame.
`strategy` ist eine [`Strategy`](@ref) aus [`create_strategy`](@ref).

Alle Raten und Schwellen werden **in Prozent** angegeben (`tax_rate = 26.375`,
`balance_thresh = 5`, `risk_free = 2` …). Die Argumente entsprechen 1:1 denen
von `simulation()` im R-Paket; `nothing` steht für `NULL`. Mit
`details = true` wird ein Ereignisprotokoll nach `io` geschrieben.
"""
function simulation(data, strategy; kwargs...)
    o = Dict{Symbol,Any}(pairs(_SIM_DEFAULTS))
    for (k, v) in kwargs
        haskey(o, k) || throw(ArgumentError("simulation: unbekanntes Argument '$k'"))
        o[k] = v
    end
    o[:tax_mode] = match_arg(o[:tax_mode], ("none", "person", "funds"), "tax_mode")
    d = SimData(data)
    (strategy === nothing || length(strategy) == 0) && throw(ArgumentError("'strategy' must be a non-empty list"))
    return _simulate(d, _strategy_items(strategy), o)
end

_is_private(a::Dict{String,Any}) = _dget(a, "tax_regime") == "private_sale" || _dget(a, "asset_class") == "etn_deliverable" ||
                                   (_dget(a, "asset_class") in ("etn", "etc") && _dget(a, "deliverable") === true)

_optf(x) = x === nothing ? nothing : Float64(x)
_numvec(x) = x === nothing ? nothing : (x isa Union{AbstractVector,Tuple} ? Any[v for v in x] : Any[x])

"Zustand eines Simulationslaufs, den die Handels- und Steuerschritte brauchen."
struct Run
    sim::Sim
    ctx::Ctx
    tax_regimes::Vector{String}
    flag_date::Vector{Int}
end

_buy!(R::Run, a::Int, time::Int, reason::String) = _perform_trade_buy!(R.sim, a, time, reason, R.ctx)

function _sell!(R::Run, a::Int, time::Int, reason::String; count = nothing, price = nothing,
                tmode::String = R.ctx.tax_mode)
    _perform_trade_sell!(R.sim, a, time, tmode, R.tax_regimes[a], reason, R.ctx; count = count, price = price)
end

function _pay_vp!(R::Run, a::Int, tax_debt::Float64, time::Int, flat_rate_::Float64, bonus::Float64,
                  spb_used::Float64, assessment_date::Int)
    sim = R.sim; ctx = R.ctx; io = ctx.io; details = ctx.details
    totals = sim.totals
    regime = R.tax_regimes[a]
    st = sim.status[a]
    if st.money >= tax_debt
        st.money = st.money - tax_debt
        totals.total_taxes = totals.total_taxes + tax_debt
        details && print(io, rsprintf("Tax Event:\tPaying Vorabpauschale of %.2f EUR for %s from cash on %s\n",
                                      tax_debt, sim.names[a], fmt_date(R.flag_date[time])))
    else
        remaining_tax = tax_debt
        if st.money > 0
            cash_used = st.money
            remaining_tax = tax_debt - cash_used
            st.money = 0.0
            details && print(io, rsprintf("Tax Event:\tUsing %.2f EUR cash for partial Vorabpauschale payment on %s\n",
                                          cash_used, fmt_date(R.flag_date[time])))
        end
        if remaining_tax > 0
            sr = _calculate_sell_count(sim, a, remaining_tax, time, ctx.tax_mode, ctx.tax_rate, regime, ctx.fractions)
            _perform_trade_sell!(sim, a, time, ctx.tax_mode, regime, "Tax Event:", ctx;
                                 count = sr.sell_count, price = sr.fifo_price)
            st.money = st.money - remaining_tax
            details && print(io, rsprintf("\t\t=> Sold shares to pay remaining %.2f EUR Vorabpauschale\n", remaining_tax))
        end
        totals.total_taxes = totals.total_taxes + tax_debt
        st.money < 0 && (st.money = 0.0)
    end
    push!(sim.trades[a].taxes, TaxEntry(R.flag_date[time], assessment_date, flat_rate_, bonus,
                                        flat_rate_ * (1 - bonus), spb_used, tax_debt))
    return nothing
end

function _simulate(d::SimData, items::Vector{Tuple{String,Dict{String,Any}}}, o::Dict{Symbol,Any})
    tax_mode::String = o[:tax_mode]
    details::Bool = o[:details]
    liquidate::Bool = o[:liquidate]
    fractions::Bool = o[:fractions]
    io::IO = o[:io]
    dca_mode::Bool = o[:dca_mode]
    balance_mode::Bool = o[:balance_mode]
    balance_dca::Bool = o[:balance_dca]
    use_spb::Bool = o[:use_sparer_pauschbetrag]
    split_mode::Bool = o[:split_mode]
    base_rate_flex::Bool = o[:base_rate_flex]

    sv_raw = o[:start_value]
    if _isnull_num(sv_raw)
        sv_raw = 10000
        @info "Note: Using default start_value = 10000"
    end
    (sv_raw isa Real && !(sv_raw isa Bool) && sv_raw > 0) || throw(ArgumentError("'start_value' must be a positive number"))
    start_value::Float64 = Float64(sv_raw)

    tr_pct = o[:tax_rate]
    (tr_pct isa Real && 0 <= tr_pct <= 100) ||
        throw(ArgumentError("'tax_rate' must be between 0 and 100 percent (e.g., 26.375 for 26.375%)"))

    mtr_pct = o[:marginal_tax_rate]
    if any(_is_private(a) for (_, a) in items) && mtr_pct === nothing
        @warn "'marginal_tax_rate' not set but private_sale assets present. § 23 EStG gains may not be taxed correctly."
    end
    if mtr_pct !== nothing && (mtr_pct < 0 || mtr_pct > 50)
        throw(ArgumentError("'marginal_tax_rate' must be between 0 and 50 percent (e.g., 42 for 42%)"))
    end

    tax_rate::Float64 = Float64(tr_pct) / 100
    mtr::Union{Nothing,Float64} = mtr_pct === nothing ? nothing : Float64(mtr_pct) / 100
    soli_rate::Float64 = Float64(o[:soli_rate_income_tax]) / 100
    bthresh::Union{Nothing,Float64} = o[:balance_thresh] === nothing ? nothing : Float64(o[:balance_thresh]) / 100
    private_sale_threshold::Float64 = Float64(o[:private_sale_threshold])
    sparer_pauschbetrag::Float64 = Float64(o[:sparer_pauschbetrag])
    funds_fee::Float64 = Float64(o[:funds_fee])
    bonus_fee::Float64 = Float64(o[:bonus_fee])
    split_thresh::Union{Nothing,Vector{Float64}} = o[:split_thresh] === nothing ? nothing : Float64[x for x in o[:split_thresh]]

    dv_raw = o[:dca_value]
    if dca_mode
        (dv_raw === nothing || dv_raw <= 0) && throw(ArgumentError("'dca_value' must be positive when dca_mode = TRUE"))
        (o[:dca_span] === nothing || o[:dca_span] < 1) && throw(ArgumentError("'dca_span' must be >= 1 when dca_mode = TRUE"))
    end
    dca_value::Float64 = dv_raw === nothing ? 0.0 : Float64(dv_raw)

    shares = [_dget(a, "asset_share") for (_, a) in items]
    total_weight = r_sum([s === nothing ? NA : Float64(s) for s in shares]; na_rm = true)
    if abs(total_weight - 1.0) > 1e-6
        throw(ArgumentError(rsprintf("Asset-Gewichte (asset_share) summieren sich auf %.4f, müssen aber exakt 1.0 ergeben.\n", total_weight) *
                            "  Aktuelle Gewichte: " *
                            join([rsprintf("%s=%.3f", n, Float64(_dget(a, "asset_share", NA))) for (n, a) in items], ", ")))
    end

    effective_tax_rate::Float64 = tax_rate
    if o[:use_guenstigerpruefung] === true
        if mtr === nothing
            @warn "Günstigerprüfung aktiviert, aber 'marginal_tax_rate' nicht gesetzt.\n" *
                  "Verwende Standard-Abgeltungsteuer ($(r_num_str(r_round(tax_rate * 100, 2)))%).\n" *
                  "Setze 'marginal_tax_rate' für korrekte Günstigerprüfung."
        elseif mtr < 0.25
            soli_factor = o[:include_soli_on_income_tax] === true ? (1 + soli_rate) : 1.0
            effective_tax_rate = mtr * soli_factor
            details && print(io, rsprintf("═══ Günstigerprüfung aktiv ═══\n  Persönlicher Steuersatz: %.2f%%\n  Effektiver Steuersatz: %.2f%% (statt %.2f%% Abgeltungsteuer)\n  Ersparnis: %.2f Prozentpunkte\n\n",
                                          mtr * 100, effective_tax_rate * 100, tax_rate * 100, (tax_rate - effective_tax_rate) * 100))
        else
            details && print(io, rsprintf("═══ Günstigerprüfung geprüft ═══\n  Persönlicher Steuersatz: %.2f%%\n  Abgeltungsteuer: %.2f%% → bleibt günstiger\n\n",
                                          mtr * 100, tax_rate * 100))
        end
    end
    soli_factor_income::Float64 = o[:include_soli_on_income_tax] === true ? (1 + soli_rate) : 1.0

    # ── Datenvorbereitung ──────────────────────────────────────────────────
    d.nrow < 1 && throw(ArgumentError("'data' must contain at least one row"))
    start_date::Int = d.days[1]
    stopp_date::Int = d.days[end]
    expected_days = (stopp_date - start_date) + 1
    if d.nrow != expected_days
        @info rsprintf("Hinweis: %d Zeilen, erwartet %d Kalendertage. Fehlende Tage werden aufgefuellt (LOCF; Signale = FALSE).",
                       d.nrow, expected_days)
        _fill_calendar!(d)
    end
    n_rows::Int = d.nrow
    for i in 2:n_rows
        d.days[i] > d.days[i-1] ||
            throw(ArgumentError("'data\$date' muss aufsteigend sortiert sein und darf keine doppelten Werte enthalten"))
    end

    # ── Speicherobjekte ────────────────────────────────────────────────────
    totals = Totals(start_value, 0.0, 0.0, 0.0, 0.0, 0.0, sparer_pauschbetrag,
                    use_spb ? sparer_pauschbetrag : 0.0, 0.0, year_of(start_date),
                    0.0, 0.0, 0.0, VPPending[])
    asset_day = collect(start_date:stopp_date)
    names = String[]; infos = AssetInfo[]; stats = Status[]; markets = Market[]; trades = Trades[]; reports = Report[]
    share_of = Float64[]
    base_rate_raw = o[:base_rate]
    brd = o[:base_rate_data]

    for (name, a) in items
        ac = _dget(a, "asset_class")
        deliverable = _dget(a, "deliverable") === true
        regime = _dget(a, "tax_regime")
        if regime === nothing
            regime = ac == "etf" ? "investment_fund" :
                     ac in ("etn", "etc") ? (deliverable ? "private_sale" : "capital_gains") :
                     ac == "etn_deliverable" ? "private_sale" : "capital_gains"
        end
        start_raw = _dget(a, "asset_start")
        style = String(_dget(a, "action_type", ""))
        push!(names, name)
        push!(infos, AssetInfo(ac === nothing ? "" : String(ac), style,
                               start_raw === nothing ? start_date : to_days(start_raw), String(regime),
                               Float64(_dget(a, "asset_bonus", 0)) / 100, deliverable))
        if style == "signal"
            sb, ss = _dget(a, "signal_buy"), _dget(a, "signal_sell")
            (sb === nothing || !haskey(d.cols, String(sb))) &&
                throw(ArgumentError("simulation: signal_buy-Spalte '$(sb === nothing ? "NULL" : sb)' fehlt im Datensatz (Asset '$name')."))
            (ss === nothing || !haskey(d.cols, String(ss))) &&
                throw(ArgumentError("simulation: signal_sell-Spalte '$(ss === nothing ? "NULL" : ss)' fehlt im Datensatz (Asset '$name')."))
        end
        share = Float64(_dget(a, "asset_share"))
        push!(share_of, share)
        st0 = Status(0.0, 0.0, 0.0, share * start_value, share * start_value, share, share, 0.0)
        push!(stats, st0)
        local br::Vector{Float64}
        if base_rate_flex
            (brd === nothing || !haskey(d.cols, String(brd))) &&
                throw(ArgumentError("base_rate_data column '$(brd === nothing ? "NULL" : brd)' not found in data"))
            br = copy(d.cols[String(brd)].num)
            br[isnan.(br)] .= 0.0
        else
            br = fill(base_rate_raw === nothing ? 0.0 : Float64(base_rate_raw), n_rows)
        end
        haskey(d.cols, name) || throw(ArgumentError("Preisspalte '$name' fehlt in 'data'"))
        pc = d.cols[name]
        pc.kind in (:numeric, :logical) || throw(ArgumentError("Preisspalte '$name' ist nicht numerisch"))
        sigs = Signal[]
        for key in ("signal_buy", "signal_sell")
            cn = _dget(a, key)
            if cn === nothing
                push!(sigs, Signal(:logical, zeros(n_rows)))
            else
                c = d.cols[String(cn)]
                c.kind == :other && throw(ArgumentError("Signalspalte '$cn' muss logisch oder numerisch sein"))
                push!(sigs, Signal(c.kind, copy(c.num)))
            end
        end
        push!(markets, Market(asset_day, br, copy(pc.num), sigs[1], sigs[2], Float64(_dget(a, "asset_spread", 0)) / 100))
        push!(trades, Trades(Lot[], SellEntry[], TaxEntry[], FeeEntry[], 1))
        w0 = zeros(n_rows); m0 = zeros(n_rows); t0 = zeros(n_rows)
        w0[1] = st0.worth; m0[1] = st0.money; t0[1] = st0.total
        push!(reports, Report(w0, m0, zeros(n_rows), t0, zeros(n_rows)))
    end
    sim = Sim(names, infos, stats, markets, trades, reports, totals)
    na = length(names)

    # ── Flags ──────────────────────────────────────────────────────────────
    flag_date = asset_day
    n = length(flag_date)
    flag_filled = d.filled === nothing ? falses(n) : BitVector(d.filled)
    flag_liquidate = BitVector((flag_date .== stopp_date) .& liquidate)
    flag_rebalance = _calculate_dates_flags(balance_mode, o[:balance_span], o[:balance_unit], _numvec(o[:balance_days]),
                                            flag_date, nothing, o[:balance_anchor], o[:balance_start],
                                            o[:balance_skip] === true, liquidate)
    flag_dca = _calculate_dates_flags(dca_mode, o[:dca_span], o[:dca_unit], _numvec(o[:dca_days]), flag_date,
                                      dv_raw, o[:dca_anchor], o[:dca_start], o[:dca_skip] === true, liquidate)
    md = [ymd(z) for z in flag_date]
    flag_taxes = BitVector([x[2] == 12 && x[3] == 31 for x in md])
    event_mode = match_arg(o[:event_mode], ("additional", "replace"), "event_mode")
    event_col = o[:event_col]
    flag_event = falses(n)
    if event_col !== nothing
        haskey(d.cols, String(event_col)) ||
            throw(ArgumentError("simulation: event_col '$(event_col)' nicht im Datensatz gefunden."))
        guard = (flag_date .!= flag_date[1]) .& ((!liquidate) .| (flag_date .!= stopp_date))
        flag_event = BitVector(_as_logical(d.cols[String(event_col)])) .& guard
        flag_rebalance = event_mode == "additional" ? (flag_rebalance .| flag_event) : copy(flag_event)
    end
    flag_trade = .!flag_rebalance .& (flag_date .!= stopp_date) .& .!flag_filled
    flag_split = _calculate_split_flags(sim, 100.0, split_mode, n, split_thresh)

    mon = [x[1] * 12 + x[2] for x in md]
    if any(flag_filled)
        flag_rebalance = _shift_off_filled(flag_rebalance, flag_filled, mon)
        flag_dca = _shift_off_filled(flag_dca, flag_filled, mon)
        flag_split = _shift_off_filled(flag_split, flag_filled, mon)
        flag_liquidate = _shift_off_filled(flag_liquidate, flag_filled, mon)
        flag_trade = .!flag_rebalance .& (flag_date .!= stopp_date) .& .!flag_filled
    end

    initial = [a for a in 1:na if infos[a].start <= flag_date[1]]
    isempty(initial) && throw(ArgumentError("invalid 'type' (list) of argument"))
    initial_weights_sum = r_sum([stats[a].actual for a in initial])
    for a in 1:na
        st = stats[a]
        if a in initial
            w = st.actual / initial_weights_sum
            st.actual = w
            st.money = start_value * w
            st.total = start_value * w
        else
            st.differ = 0.0
            st.money = 0.0
            st.total = 0.0
        end
    end

    asset_starts = _shift_starts([infos[a].start for a in 1:na], flag_date, flag_filled, mon)
    start_set = Set(asset_starts)
    flag_active = BitVector([z in start_set for z in flag_date])
    pos_all = Dict(z => i for (i, z) in enumerate(flag_date))
    asset_start_indices = [get(pos_all, z, 1) for z in asset_starts]

    flag_definite = flag_active .| flag_split .| flag_dca .| flag_rebalance .| flag_taxes .| flag_liquidate
    has_bnh = any(infos[a].style == "bnh" for a in 1:na)
    has_signal = any(infos[a].style == "signal" for a in 1:na)
    tax_regimes = [infos[a].tax_regime for a in 1:na]
    ctx = Ctx(tax_mode, tax_rate, effective_tax_rate, mtr, private_sale_threshold, use_spb, fractions, details, io)
    R = Run(sim, ctx, tax_regimes, flag_date)

    flag_signal = falses(n)
    if has_signal
        for a in 1:na
            infos[a].style == "signal" || continue
            mk = markets[a]
            for i in 1:n
                (sig_truthy(mk.signal_buy, i) || sig_truthy(mk.signal_sell, i)) && (flag_signal[i] = true)
            end
        end
    end
    flag_bnh_potential = falses(n)
    has_bnh && n > 0 && (flag_bnh_potential[1] = true)

    flag_year_change = falses(n)
    flag_vp_settle = falses(n)
    if tax_mode == "person"
        for i in 2:n
            md[i][1] > md[i-1][1] && (flag_year_change[i] = true)
        end
        for ys in findall(flag_year_change)
            j = ys
            while j <= n && flag_filled[j]
                j += 1
            end
            j <= n && (flag_vp_settle[j] = true)
        end
    end
    flag_slow_path = flag_definite .| flag_signal .| flag_bnh_potential .| flag_vp_settle
    individual_days = findall(flag_slow_path .| flag_year_change)
    ew = _event_weight_map(o[:event_weight])

    P = LoopParams(individual_days, flag_slow_path, flag_year_change, flag_active, flag_rebalance, flag_split,
                   flag_dca, flag_trade, flag_event, flag_vp_settle, flag_taxes, flag_liquidate, md,
                   asset_starts, asset_start_indices, share_of, ew, balance_mode, balance_dca, dca_value, bthresh,
                   split_thresh, liquidate, start_value, mtr, private_sale_threshold, sparer_pauschbetrag,
                   soli_factor_income, funds_fee, bonus_fee, n_rows)
    _main_loop!(R, d, P)

    return _build_result(sim, d, flag_date, flag_filled, start_date, stopp_date, start_value,
                         effective_tax_rate, o[:risk_free])
end

function _shift_starts(asset_starts::Vector{Int}, flag_date::Vector{Int}, flag_filled::BitVector, mon::Vector{Int})
    any(flag_filled) || return asset_starts
    n = length(flag_date)
    pos = Dict(z => i for (i, z) in enumerate(flag_date))
    shifted = Int[]
    for dz in asset_starts
        i = get(pos, dz, nothing)
        if i === nothing || !flag_filled[i]
            push!(shifted, dz)
            continue
        end
        j = i + 1
        while j <= n && flag_filled[j]
            j += 1
        end
        if j > n || mon[j] != mon[i]
            j = i - 1
            while j >= 1 && flag_filled[j]
                j -= 1
            end
        end
        j = max(min(j, n), 1)
        push!(shifted, flag_date[j])
    end
    return shifted
end

"Unveränderliche Eingaben der Hauptschleife (feste Feldtypen → nur eine Kompilierung)."
struct LoopParams
    individual_days::Vector{Int}
    flag_slow_path::BitVector
    flag_year_change::BitVector
    flag_active::BitVector
    flag_rebalance::BitVector
    flag_split::BitVector
    flag_dca::BitVector
    flag_trade::BitVector
    flag_event::BitVector
    flag_vp_settle::BitVector
    flag_taxes::BitVector
    flag_liquidate::BitVector
    md::Vector{Tuple{Int,Int,Int}}
    asset_starts::Vector{Int}
    asset_start_indices::Vector{Int}
    share_of::Vector{Float64}
    ew::Union{Nothing,Dict{String,Union{Nothing,String}}}
    balance_mode::Bool
    balance_dca::Bool
    dca_value::Float64
    bthresh::Union{Nothing,Float64}
    split_thresh::Union{Nothing,Vector{Float64}}
    liquidate::Bool
    start_value::Float64
    mtr::Union{Nothing,Float64}
    private_sale_threshold::Float64
    sparer_pauschbetrag::Float64
    soli_factor_income::Float64
    funds_fee::Float64
    bonus_fee::Float64
    n_rows::Int
end

function _main_loop!(R::Run, d::SimData, P::LoopParams)
    individual_days = P.individual_days; flag_slow_path = P.flag_slow_path; flag_year_change = P.flag_year_change
    flag_active = P.flag_active; flag_rebalance = P.flag_rebalance; flag_split = P.flag_split; flag_dca = P.flag_dca
    flag_trade = P.flag_trade; flag_event = P.flag_event; flag_vp_settle = P.flag_vp_settle
    flag_taxes = P.flag_taxes; flag_liquidate = P.flag_liquidate; md = P.md
    asset_starts = P.asset_starts; asset_start_indices = P.asset_start_indices; share_of = P.share_of
    ew = P.ew; balance_mode = P.balance_mode; balance_dca = P.balance_dca; dca_value = P.dca_value
    bthresh = P.bthresh; split_thresh = P.split_thresh; liquidate = P.liquidate; start_value = P.start_value
    mtr = P.mtr; private_sale_threshold = P.private_sale_threshold; sparer_pauschbetrag = P.sparer_pauschbetrag
    soli_factor_income = P.soli_factor_income; funds_fee = P.funds_fee; bonus_fee = P.bonus_fee; n_rows = P.n_rows
    sim = R.sim; ctx = R.ctx; io = ctx.io; details = ctx.details
    tax_mode = ctx.tax_mode; tax_rate = ctx.tax_rate; fractions = ctx.fractions
    effective_tax_rate = ctx.effective_tax_rate; use_spb = ctx.use_spb
    names = sim.names; infos = sim.assets; stats = sim.status; markets = sim.market
    trades = sim.trades; reports = sim.report; totals = sim.totals
    flag_date = R.flag_date; tax_regimes = R.tax_regimes
    na = length(names)
    n = length(flag_date)

    prev_end = 0
    active = Int[]
    for time in individual_days
        if time > prev_end + 1
            batch_market_update!(sim, prev_end + 1, time - 1)
        end
        if flag_year_change[time]
            _handle_year_change!(sim, flag_date[time], mtr, private_sale_threshold, sparer_pauschbetrag,
                                 use_spb, soli_factor_income, effective_tax_rate, details, io)
        end
        if !flag_slow_path[time]
            perform_market_update!(sim, time)
            prev_end = time
            continue
        end
        if flag_active[time] || isempty(active)
            active = [a for a in 1:na if asset_start_indices[a] <= time]
        end
        flag_fast_report = true

        # Asset-Aktivierung
        if flag_active[time]
            for a in 1:na
                a in active && continue
                markets[a].signal_buy.v[time] = 0.0
                markets[a].signal_sell.v[time] = 0.0
            end
            if balance_mode
                cws = r_sum([stats[a].actual for a in active])
                for a in active
                    stats[a].differ = stats[a].actual / cws
                end
                if details
                    new_assets = [names[a] for a in 1:na if asset_starts[a] == flag_date[time]]
                    isempty(new_assets) || print(io, rsprintf("Market Event:\tActive trading of %s now enabled.\n",
                                                              join(new_assets, ", ")))
                end
                flag_rebalance[time] = true
            end
            calculate_total_report!(sim, time)
            flag_fast_report = false
        end

        # Splits
        if flag_split[time]
            for a in active
                if stats[a].count > 0
                    sp = markets[a].asset_price[time]
                    sp > split_thresh[2] && _perform_asset_split!(sim, a, sp / 100, time, true, fractions, details, flag_date[time], io)
                    sp < split_thresh[1] && _perform_asset_split!(sim, a, 100 / sp, time, false, fractions, details, flag_date[time], io)
                end
            end
            calculate_total_report!(sim, time)
            flag_fast_report = false
        end

        # DCA
        if flag_dca[time]
            strat_w = [share_of[a] for a in active]
            strat_w = strat_w ./ r_sum(strat_w; na_rm = true)
            if balance_dca && length(active) > 1
                totals_now = [stats[a].total for a in active]
                desired = strat_w .* (r_sum(totals_now; na_rm = true) + dca_value)
                deficit = [_pmax0(x) for x in desired .- totals_now]
                alloc = r_sum(deficit) > dca_value ? dca_value .* deficit ./ r_sum(deficit) :
                        deficit .+ (dca_value - r_sum(deficit)) .* strat_w
                for (k, a) in enumerate(active)
                    dca_flows_allocation!(sim, a, alloc[k], time)
                end
            else
                for (k, a) in enumerate(active)
                    dca_flows_allocation!(sim, a, strat_w[k] * dca_value, time)
                end
            end
            if details
                parts = join([rsprintf("%s %.2f EUR", names[a], reports[a].flows[time]) for a in active], "; ")
                print(io, rsprintf("Transferring:\tDepositing %.2f EUR to brokerage account on %s\n\t\t=> %s\n",
                                   dca_value, fmt_date(flag_date[time]), parts))
            end
            calculate_total_report!(sim, time)
            flag_fast_report = false
        end

        # Handel
        if flag_trade[time]
            trade_event = false
            for a in active
                f_buy = _calculate_buy_signal(sim, a, time)
                f_sell = _calculate_sell_signal(sim, a, time)
                if f_buy
                    _buy!(R, a, time, "Trade Event:"); trade_event = true
                end
                if f_sell
                    _sell!(R, a, time, "Trade Event:"); trade_event = true
                end
            end
            if trade_event
                calculate_total_report!(sim, time)
                flag_fast_report = false
            end
        end

        # Rebalancing
        if flag_rebalance[time]
            _rebalance!(R, d, time, active, asset_starts, ew, flag_event, bthresh)
            flag_fast_report = false
        end

        # Fälligkeit der Vorabpauschale (§ 18 Abs. 3 InvStG)
        if tax_mode == "person" && flag_vp_settle[time]
            if !isempty(totals.vp_pending)
                for p in copy(totals.vp_pending)
                    _pay_vp!(R, p.name, p.tax_debt, time, p.flat_rate, p.bonus, p.spb_used, p.assessment_date)
                end
                empty!(totals.vp_pending)
                calculate_total_report!(sim, time)
                flag_fast_report = false
            end
        end

        # Steuern und Gebühren (31.12.)
        if flag_taxes[time]
            if tax_mode == "person" && !(liquidate && flag_liquidate[time])
                for a in 1:na
                    regime = tax_regimes[a]
                    (regime == "investment_fund" && stats[a].count > 0) || continue
                    vr = _calculate_flat_rate(sim, a, time, flag_date, regime)
                    fr = vr.total_vp
                    buys_l = trades[a].buys
                    for (vi, lv) in zip(vr.lot_indices, vr.lot_vps)
                        buys_l[vi].vp = buys_l[vi].vp + lv
                    end
                    fr > 0 || continue
                    prior = 0.0
                    if !isempty(trades[a].taxes)
                        cy = md[time][1]
                        prior = r_sum(Float64[year_of(x.assessment_date) == cy ? x.taxes_paid : 0.0 for x in trades[a].taxes]; na_rm = true)
                    end
                    bonus = infos[a].bonus
                    res = vp_tax!(fr, bonus, totals, effective_tax_rate, use_spb)
                    tax_debt = r_max2(res.tax - prior, 0.0)
                    if details && res.spb_used > 0
                        print(io, rsprintf("Tax Event:\tVorabpauschale %s: %.2f EUR (nach TFS: %.2f EUR, SPB: %.2f EUR)\n",
                                           names[a], fr, fr * (1 - bonus), res.spb_used))
                    end
                    tax_debt > 0 || continue
                    has_future = time < n && any(@view flag_vp_settle[time+1:end])
                    if has_future
                        push!(totals.vp_pending, VPPending(a, tax_debt, fr, bonus, res.spb_used, flag_date[time]))
                        details && print(io, rsprintf("Tax Event:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (faellig am ersten Handelstag des Folgejahres)\n",
                                                      names[a], tax_debt, fmt_date(flag_date[time])))
                    else
                        details && print(io, rsprintf("Tax Event:\tVorabpauschale %s: %.2f EUR festgesetzt am %s (sofort faellig: kein weiterer Handelstag)\n",
                                                      names[a], tax_debt, fmt_date(flag_date[time])))
                        _pay_vp!(R, a, tax_debt, time, fr, bonus, res.spb_used, flag_date[time])
                    end
                end
            end
            if tax_mode == "funds"
                rf_ = _calculate_fund_fees(sim, time, flag_date, funds_fee, bonus_fee, details, io)
                totals.total_value = rf_.total_value
                annual_fees = rf_.total_fees
                asset_share = [annual_fees * st.actual for st in stats]
                asset_money = [st.money for st in stats]
                for a in 1:na
                    if asset_money[a] > asset_share[a]
                        stats[a].money < asset_share[a] && (asset_share[a] = r_max2(0.0, stats[a].money))
                        stats[a].money = stats[a].money - asset_share[a]
                        details && print(io, rsprintf("\t\t=> Deducting %.2f EUR from %s's cash reserve for fees\n",
                                                      asset_share[a], names[a]))
                    end
                end
            end
            calculate_total_report!(sim, time)
            flag_fast_report = false
        end

        # Liquidation
        if flag_liquidate[time]
            for a in 1:na
                stats[a].count > 0 && _sell!(R, a, time, "Liquidating:"; tmode = tax_mode == "person" ? "person" : "none")
            end
            if !(md[time][2] == 12 && md[time][3] == 31) && tax_mode == "funds"
                rf_ = _calculate_fund_fees(sim, time, flag_date, funds_fee, bonus_fee, details, io)
                totals.total_value = rf_.total_value
                annual_fees = rf_.total_fees
                asset_share = [annual_fees * st.differ for st in stats]
                for a in 1:na
                    _sell!(R, a, time, "")
                    stats[a].money < asset_share[a] && (asset_share[a] = r_max2(0.0, stats[a].money))
                    stats[a].money = stats[a].money - asset_share[a]
                end
                tax_weights = [st.differ for st in stats]
                final_value = r_sum([st.total for st in stats]; na_rm = true)
                total_gains = final_value - start_value
                if total_gains > 0
                    total_taxes = total_gains * tax_rate
                    for a in 1:na
                        tpa = total_taxes * tax_weights[a]
                        stats[a].money < tpa && (tpa = r_max2(0.0, stats[a].money))
                        stats[a].money = stats[a].money - tpa
                    end
                    details && print(io, rsprintf("Liquidating:\tPaying taxes of %.2f EUR on %.2f EUR total gain on %s\n",
                                                  total_taxes, total_gains, fmt_date(flag_date[time])))
                end
                for a in 1:na
                    push!(trades[a].fees, FeeEntry(flag_date[time], annual_fees))
                end
            end
            calculate_total_report!(sim, time)
            flag_fast_report = false
        end

        flag_fast_report && perform_market_update!(sim, time)
        prev_end = time
    end

    prev_end < n_rows && batch_market_update!(sim, prev_end + 1, n_rows)

    if tax_mode == "person"
        _handle_year_change!(sim, days_from_civil(year_of(flag_date[end]) + 1, 1, 1), mtr, private_sale_threshold,
                             sparer_pauschbetrag, use_spb, soli_factor_income, effective_tax_rate, details, io)
    end
    return nothing
end

function _rebalance!(R::Run, d::SimData, time::Int, active::Vector{Int}, asset_starts::Vector{Int},
                     ew::Union{Nothing,Dict{String,Union{Nothing,String}}}, flag_event::BitVector,
                     bthresh::Union{Nothing,Float64})
    sim = R.sim; ctx = R.ctx; io = ctx.io; details = ctx.details
    stats = sim.status; names = sim.names; infos = sim.assets; markets = sim.market
    flag_date = R.flag_date
    na = length(names)

    at = [stats[a].actual for a in active]
    at = at ./ r_sum(at; na_rm = true)
    targets = Dict(zip(active, at))
    if ew !== nothing && flag_event[time]
        ow = Float64[]
        for a in active
            col = get(ew, names[a], nothing)
            push!(ow, (col === nothing || !haskey(d.cols, col)) ? NA : d.cols[col].num[time])
        end
        if all(isfinite, ow) && r_sum(ow) > 0
            ow = ow ./ r_sum(ow)
            targets = Dict(zip(active, ow))
        end
    end

    signal_cash_only = Int[]
    for a in active
        infos[a].style == "signal" || continue
        has_pos = stats[a].count > 0
        sb = sig_is_true(markets[a].signal_buy, time)
        ss = sig_is_true(markets[a].signal_sell, time)
        if has_pos && ss
            _sell!(R, a, time, "Rebalancing/Signal-Exit:")
            push!(signal_cash_only, a)
        elseif !has_pos && sb
            _buy!(R, a, time, "Rebalancing/Signal-Entry:")
        elseif !has_pos && !sb
            push!(signal_cash_only, a)
        end
    end

    actual_w = Dict(a => stats[a].differ for a in active)
    force_rebalance = any(sd == flag_date[time] for sd in asset_starts)
    if force_rebalance && details
        new_assets = [names[a] for a in 1:na if asset_starts[a] == flag_date[time]]
        print(io, rsprintf("Rebalancing:\tForcing rebalance on %s due to new asset activation: %s\n",
                           fmt_date(flag_date[time]), join(new_assets, ", ")))
    end
    local event_rebalance::Bool
    if force_rebalance || bthresh === nothing
        event_rebalance = true
    else
        deviations = [abs(targets[a] - actual_w[a]) for a in active]
        devs_ok = filter(!isnan, deviations)
        max_dev = isempty(devs_ok) ? -Inf : maximum(devs_ok)
        event_rebalance = max_dev > bthresh
        if details
            if event_rebalance
                print(io, rsprintf("Rebalancing:\tExecuting rebalancing on %s (max deviation: %.2f%% > threshold: %.2f%%)\n",
                                   fmt_date(flag_date[time]), max_dev * 100, bthresh * 100))
                for (k, a) in enumerate(active)
                    dev = deviations[k]
                    dev > bthresh && print(io, rsprintf("\t\t=> %s: target=%.1f%%, actual=%.1f%%, deviation=%.2f%%\n",
                                                        names[a], targets[a] * 100, actual_w[a] * 100, dev * 100))
                end
            else
                print(io, rsprintf("Rebalancing:\tSkipping rebalancing on %s (max deviation: %.2f%% < threshold: %.2f%%)\n",
                                   fmt_date(flag_date[time]), max_dev * 100, bthresh * 100))
            end
        end
    end

    if event_rebalance
        differ_w = Dict(a => targets[a] - actual_w[a] for a in active)
        total_strategy = r_sum([stats[a].total for a in active]; na_rm = true)
        transfer_pool = 0.0
        transfer_value = Dict(a => abs(differ_w[a] * total_strategy) for a in active)
        for a in active
            differ_w[a] < 0 || continue
            if stats[a].count > 0
                sr = _calculate_sell_count(sim, a, transfer_value[a], time, ctx.tax_mode, ctx.tax_rate,
                                           R.tax_regimes[a], ctx.fractions)
                _sell!(R, a, time, "Rebalancing:"; count = sr.sell_count, price = sr.fifo_price)
            end
            available_cash = r_min2(stats[a].money, transfer_value[a])
            transfer_pool = transfer_pool + available_cash
            stats[a].money = stats[a].money - available_cash
            details && print(io, rsprintf("\t\tDepositing %.2f EUR from %s to rebalancing pool\n", available_cash, names[a]))
        end
        for a in active
            differ_w[a] > 0 || continue
            allocation = r_min2(transfer_value[a], transfer_pool)
            allocation > 0 || continue
            stats[a].money = stats[a].money + allocation
            transfer_pool = transfer_pool - allocation
            details && print(io, rsprintf("Rebalancing:\tWithdrawing %.2f EUR from pool to %s\n", allocation, names[a]))
            if a in signal_cash_only
                details && print(io, rsprintf("\t\t=> %s haelt %.2f EUR als Cash-Reserve (Signal inaktiv)\n",
                                              names[a], stats[a].money))
            else
                _buy!(R, a, time, "Rebalancing:")
            end
        end
        if transfer_pool > 0.01
            details && print(io, rsprintf("\t\tRedistributing remaining %.2f EUR from rebalancing pool\n", transfer_pool))
            for a in active
                redistribution = targets[a] * transfer_pool
                stats[a].money = stats[a].money + redistribution
                details && print(io, rsprintf("\t\t=> Transferring %.2f EUR to %s\n", redistribution, names[a]))
            end
        end
    end
    for a in active
        st = stats[a]
        if !(a in signal_cash_only) && st.money > 0.005 && (infos[a].style != "signal" || st.count > 0)
            _buy!(R, a, time, "Rebalancing:")
        end
    end
    calculate_total_report!(sim, time)
    return nothing
end

# ── Ergebnis-Berechnung ─────────────────────────────────────────────────────

function _build_result(sim::Sim, d::SimData, flag_date::Vector{Int}, flag_filled::BitVector,
                       start_date::Int, stopp_date::Int, start_value::Float64,
                       effective_tax_rate::Float64, @nospecialize(risk_free))
    na = length(sim.names)
    n = length(flag_date)
    total_worth = r_rowsums([sim.report[a].total for a in 1:na]; na_rm = true)
    total_flows = r_rowsums([sim.report[a].flows for a in 1:na]; na_rm = true)
    start_worth = total_worth[1]
    stopp_worth = total_worth[n]
    nd = length(total_worth)

    ann_factor = Float64(stopp_date - start_date) / 365.25
    cagr = (start_worth > 0 && ann_factor > 0) ? r_pow(stopp_worth / start_worth, 1 / ann_factor) - 1 : NA

    running_max = r_cummax(total_worth)
    drawdowns = [isnan(running_max[i]) ? NA :
                 (running_max[i] > 0 ? (running_max[i] - total_worth[i]) / running_max[i] : 0.0) for i in 1:nd]
    dd_ok = filter(!isnan, drawdowns)
    max_drawdown = isempty(dd_ok) ? -Inf : maximum(dd_ok)
    isfinite(max_drawdown) || (max_drawdown = 0.0)

    if nd >= 2
        period_return = Vector{Float64}(undef, nd)
        period_return[1] = NA
        for i in 2:nd
            pc = total_worth[i] - total_worth[i-1] - total_flows[i]
            pt = total_worth[i-1]
            period_return[i] = (!isnan(pt) && pt > 0) ? pc / pt : 0.0
        end
        period_return[1] = NA
    else
        period_return = [NA]
    end
    ttwror = ann_factor > 0 ? r_pow(r_prod(1 .+ period_return; na_rm = true), 1 / ann_factor) - 1 : NA

    portfolio_returns = Float64[(total_worth[i+1] - total_worth[i]) / total_worth[i] for i in 1:nd-1]
    portfolio_returns[.!isfinite.(portfolio_returns)] .= 0.0
    ttwror_returns = period_return[2:end]
    ttwror_returns[.!isfinite.(ttwror_returns)] .= 0.0
    has_flows = any(x -> !isnan(x) && x != 0, total_flows)
    risk_returns = has_flows ? ttwror_returns : portfolio_returns

    mask = length(flag_filled) == length(risk_returns) + 1 ? flag_filled[2:end] : falses(length(risk_returns))
    if length(mask) == length(risk_returns) && any(mask)
        risk_returns = risk_returns[.!mask]
    end
    ann_periods = (ann_factor > 0 && !isempty(risk_returns)) ? length(risk_returns) / ann_factor : 365.25

    daily_mean = r_mean(risk_returns; na_rm = true)
    daily_sd = r_sd(risk_returns; na_rm = true)
    isfinite(daily_mean) || (daily_mean = 0.0)
    isfinite(daily_sd) || (daily_sd = 0.0)
    daily_cv = daily_mean != 0 ? abs(daily_sd / daily_mean) : NA

    days_per_year = ann_periods
    rf = risk_free === nothing ? 0 : risk_free
    if rf isa AbstractString || rf isa Symbol
        haskey(d.cols, String(rf)) || throw(ArgumentError("risk_free: Spalte '$(rf)' fehlt im Datensatz."))
        rf_full = copy(d.cols[String(rf)].num)
    else
        rf_full = fill(Float64(rf), nd)
    end
    rf_full[.!isfinite.(rf_full)] .= 0.0
    rf_full = rf_full ./ 100
    rf_returns = length(rf_full) >= 2 ? rf_full[2:end] : Float64[]
    if length(mask) == length(rf_returns) && any(mask)
        rf_returns = rf_returns[.!mask]
    end
    if length(rf_returns) != length(risk_returns)
        rf_returns = fill(isempty(rf_returns) ? 0.0 : r_mean(rf_returns), length(risk_returns))
    end
    rf_daily = r_pow_vec(1 .+ rf_returns, 1 / days_per_year) .- 1
    excess = risk_returns .- rf_daily
    rf_effective = isempty(rf_returns) ? 0.0 : r_mean(rf_returns) * 100

    mean_excess = r_mean(excess; na_rm = true)
    sd_excess = r_sd(excess; na_rm = true)
    isfinite(mean_excess) || (mean_excess = 0.0)
    isfinite(sd_excess) || (sd_excess = 0.0)
    down_ex = excess[excess .< 0]
    downside_sd_excess = isempty(down_ex) ? 0.0 : r_sqrt(r_mean(r_pow_vec(down_ex, 2.0); na_rm = true))

    sqrt_dpy = r_sqrt(days_per_year)
    sharpe = sd_excess > 0 ? (mean_excess * days_per_year) / (sd_excess * sqrt_dpy) : NA
    sortino = downside_sd_excess > 0 ? (mean_excess * days_per_year) / (downside_sd_excess * sqrt_dpy) : NA
    calmar = (max_drawdown > 0 && !isnan(cagr)) ? cagr / max_drawdown : NA
    ulcer_index = r_sqrt(r_mean(r_pow_vec(drawdowns, 2.0); na_rm = true))
    isfinite(ulcer_index) || (ulcer_index = 0.0)
    martin_ratio = (ulcer_index > 0 && !isnan(cagr)) ? cagr / ulcer_index : NA
    serenity = (ulcer_index > 0 && max_drawdown > 0 && !isnan(cagr)) ? cagr / (ulcer_index * max_drawdown) : NA
    gains = r_sum(risk_returns[risk_returns .> 0]; na_rm = true)
    losses = abs(r_sum(risk_returns[risk_returns .< 0]; na_rm = true))
    omega = losses > 0 ? gains / losses : NA
    gain_to_pain = losses > 0 ? r_sum(risk_returns; na_rm = true) / losses : NA
    dd_active = drawdowns[drawdowns .> 0]
    average_drawdown = isempty(dd_active) ? 0.0 : r_mean(dd_active)

    longest_dd = 0
    current_dd = 0
    recovery_times = Int[]
    in_dd = false
    dd_start = 0
    for i in 1:nd
        below = total_worth[i] < running_max[i]
        if below
            current_dd += 1
            current_dd > longest_dd && (longest_dd = current_dd)
        else
            current_dd = 0
        end
        if below
            if !in_dd
                dd_start = i; in_dd = true
            end
        else
            if in_dd
                push!(recovery_times, i - dd_start); in_dd = false
            end
        end
    end
    avg_recovery_time = isempty(recovery_times) ? NA : r_mean_int(recovery_times)

    statistics = (mean = daily_mean, sd = daily_sd, cv = daily_cv, risk_free = rf_effective,
                  skewness = _calculate_skewness(risk_returns), kurtosis = _calculate_kurtosis(risk_returns),
                  lpm = _calculate_partials(risk_returns, true), hpm = _calculate_partials(risk_returns, false),
                  sharpe = sharpe, sortino = sortino, calmar = calmar, omega = omega,
                  gain_to_pain = gain_to_pain, serenity = serenity, martin_ratio = martin_ratio,
                  max_drawdown = max_drawdown, average_drawdown = average_drawdown, ulcer_index = ulcer_index,
                  longest_drawdown = longest_dd, avg_recovery_time = avg_recovery_time)

    buys = [length(sim.trades[a].buys) / ann_factor for a in 1:na]
    sells = [length(sim.trades[a].sells) / ann_factor for a in 1:na]
    t = sim.totals
    tax_report = (total_taxes_paid = t.total_taxes, loss_carryforward_capital = t.loss_capital_gains,
                  loss_carryforward_private = t.loss_private_sales,
                  sparer_pauschbetrag_annual = t.sparer_pauschbetrag_annual,
                  sparer_pauschbetrag_used = t.sparer_pauschbetrag_used_total,
                  sparer_pauschbetrag_tax_saved = t.sparer_pauschbetrag_used_total * effective_tax_rate)
    report = [sim.names[a] => (worth = sim.report[a].worth, money = sim.report[a].money,
                               flows = sim.report[a].flows, total = sim.report[a].total,
                               share = sim.report[a].share) for a in 1:na]
    trades = [sim.names[a] => (buys = sim.trades[a].buys, sells = sim.trades[a].sells,
                               taxes = sim.trades[a].taxes, fees = sim.trades[a].fees) for a in 1:na]
    return SimLevResult([from_days(z) for z in flag_date], Vector{Bool}(flag_filled), total_worth, cagr, ttwror,
                        drawdowns, statistics, NamedVec(sim.names, buys), NamedVec(sim.names, sells),
                        OrderedReport(report), tax_report, OrderedReport(trades))
end
