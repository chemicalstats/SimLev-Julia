# ─────────────────────────────────────────────────────────────────────────────
# Simulationszustand und Rechenkerne
#
# Ports von simulation_core.cpp, fifo_core_RCpp.cpp und tax_core_RCpp.cpp. Die
# Rechenreihenfolge ist 1:1 übernommen (IEEE-754-Doubles; long double nur
# dort, wo auch der C++-Code ihn nutzt).
# ─────────────────────────────────────────────────────────────────────────────

"Ein Kauf-Lot (FIFO)."
mutable struct Lot
    date::Int
    count::Float64
    price::Float64
    remaining::Float64
    original::Float64
    vp::Float64          # angerechnete Vorabpauschale (§ 19 InvStG)
end

"Ein Verkauf."
struct SellEntry
    event_date::Int
    asset_count::Float64
    asset_price::Float64
    event_gain::Float64
    event_taxes::Float64
    tax_regime::Union{Nothing,String}
    tax_deferred::Bool
    holding_exempt::Float64
end

"Eine Vorabpauschalen-Buchung."
struct TaxEntry
    event_date::Int
    assessment_date::Int
    flat_rate_gross::Float64
    bonus_applied::Float64
    flat_rate_taxable::Float64
    spb_used::Float64
    taxes_paid::Float64
end

"Eine Gebührenbuchung (Fondsmodus)."
struct FeeEntry
    event_date::Int
    fees_paid::Float64
end

mutable struct Status
    count::Float64
    price::Float64
    worth::Float64
    money::Float64
    total::Float64
    target::Float64
    actual::Float64      # historisch: normalisiertes ZIELgewicht
    differ::Float64      # historisch: aktuelles PORTFOLIOgewicht
end

mutable struct Signal
    kind::Symbol         # :logical, :numeric, :none
    v::Vector{Float64}
end

@inline sig_truthy(s::Signal, i::Int) = (x = s.v[i]; !isnan(x) && x != 0)
@inline sig_is_true(s::Signal, i::Int) = s.kind == :logical && s.v[i] == 1.0

struct Market
    asset_day::Vector{Int}
    base_rates::Vector{Float64}
    asset_price::Vector{Float64}
    signal_buy::Signal
    signal_sell::Signal
    spread_rate::Float64
end

struct Report
    worth::Vector{Float64}
    money::Vector{Float64}
    flows::Vector{Float64}
    total::Vector{Float64}
    share::Vector{Float64}
end

mutable struct Trades
    buys::Vector{Lot}
    sells::Vector{SellEntry}
    taxes::Vector{TaxEntry}
    fees::Vector{FeeEntry}
    fifo_front::Int
end

struct AssetInfo
    class::String
    style::String
    start::Int
    tax_regime::String
    bonus::Float64
    deliverable::Bool
end

struct VPPending
    name::Int
    tax_debt::Float64
    flat_rate::Float64
    bonus::Float64
    spb_used::Float64
    assessment_date::Int
end

mutable struct Totals
    total_value::Float64
    total_taxes::Float64
    loss_capital_gains::Float64
    loss_private_sales::Float64
    private_sale_gains_ytd::Float64
    private_sale_losses_ytd::Float64
    sparer_pauschbetrag_annual::Float64
    sparer_pauschbetrag_remaining::Float64
    sparer_pauschbetrag_used_total::Float64
    current_year::Int
    cgt_base_taxed_ytd::Float64
    cgt_loss_added_ytd::Float64
    cgt_loss_used_ytd::Float64
    vp_pending::Vector{VPPending}
end

struct Sim
    names::Vector{String}
    assets::Vector{AssetInfo}
    status::Vector{Status}
    market::Vector{Market}
    trades::Vector{Trades}
    report::Vector{Report}
    totals::Totals
end

# ═══════════════════════════════════════════════════════════════════════════
# simulation_core.cpp
# ═══════════════════════════════════════════════════════════════════════════

function dca_flows_allocation!(sim::Sim, a::Int, flows::Float64, index::Int)
    st = sim.status[a]; rp = sim.report[a]
    rp.flows[index] = flows
    money = st.money + flows
    st.money = money
    rp.money[index] = money
    total = money + st.worth
    st.total = total
    rp.total[index] = total
    return nothing
end

function calculate_buy_report!(sim::Sim, a::Int, index::Int, trade_count::Float64,
                               trade_price::Float64, market_price::Float64)
    st = sim.status[a]; rp = sim.report[a]
    count = st.count + trade_count
    st.count = count
    st.price = market_price
    worth = count * market_price
    st.worth = worth
    money = st.money - (trade_count * trade_price)
    st.money = money
    total = worth + money
    st.total = total
    rp.worth[index] = worth
    rp.money[index] = money
    rp.total[index] = total
    return nothing
end

function calculate_sell_report!(sim::Sim, a::Int, index::Int, trade_count::Float64,
                                trade_price::Float64, market_price::Float64, capital_gains_tax::Float64)
    st = sim.status[a]; rp = sim.report[a]
    count = st.count - trade_count
    st.count = count
    st.price = market_price
    worth = count * market_price
    st.worth = worth
    money = st.money + ((trade_count * trade_price) - capital_gains_tax)
    st.money = money
    total = worth + money
    st.total = total
    rp.worth[index] = worth
    rp.money[index] = money
    rp.total[index] = total
    return nothing
end

function calculate_total_report!(sim::Sim, index::Int)
    n = length(sim.names)
    @inbounds for a in 1:n
        st = sim.status[a]; rp = sim.report[a]
        price = sim.market[a].asset_price[index]
        st.price = price
        worth = price * st.count
        st.worth = worth
        rp.worth[index] = worth
        money = st.money
        rp.money[index] = money
        total = money + worth
        st.total = total
        rp.total[index] = total
    end
    total_worth = 0.0
    @inbounds for a in 1:n
        total_worth += sim.status[a].total
    end
    @inbounds for a in 1:n
        st = sim.status[a]
        w = total_worth > 0 ? st.total / total_worth : 0.0
        st.differ = w
        sim.report[a].share[index] = w
    end
    return nothing
end

function perform_trade_buy_cpp!(sim::Sim, a::Int, index::Int, trade_count::Float64,
                                trade_price::Float64, market_price::Float64)
    calculate_buy_report!(sim, a, index, trade_count, trade_price, market_price)
    d = sim.market[a].asset_day[index]
    push!(sim.trades[a].buys, Lot(d, trade_count, trade_price, trade_count, trade_count, 0.0))
    return nothing
end

function perform_market_update!(sim::Sim, index::Int)
    n = length(sim.names)
    total_portfolio = 0.0
    @inbounds for a in 1:n
        st = sim.status[a]; rp = sim.report[a]
        price = sim.market[a].asset_price[index]
        money = st.money
        worth = st.count * price
        total = worth + money
        total_portfolio += total
        rp.worth[index] = worth
        rp.money[index] = money
        rp.flows[index] = 0.0
        rp.total[index] = total
        st.price = price
        st.worth = worth
        st.total = total
    end
    @inbounds for a in 1:n
        w = total_portfolio > 0 ? sim.report[a].total[index] / total_portfolio : 0.0
        sim.report[a].share[index] = w
        sim.status[a].differ = w
    end
    return nothing
end

function batch_market_update!(sim::Sim, start_idx::Int, end_idx::Int)
    nd = end_idx - start_idx + 1
    nd <= 0 && return nothing
    n = length(sim.names)
    portfolio = zeros(nd)
    @inbounds for a in 1:n
        st = sim.status[a]; rp = sim.report[a]
        count = st.count; money = st.money
        prices = sim.market[a].asset_price
        for (k, i) in enumerate(start_idx:end_idx)
            worth = count * prices[i]
            total = worth + money
            rp.worth[i] = worth
            rp.money[i] = money
            rp.flows[i] = 0.0
            rp.total[i] = total
            portfolio[k] += total
        end
        st.price = prices[end_idx]
        st.worth = rp.worth[end_idx]
        st.total = rp.total[end_idx]
    end
    @inbounds for a in 1:n
        rp = sim.report[a]
        w = 0.0
        for (k, i) in enumerate(start_idx:end_idx)
            p = portfolio[k]
            w = p > 0.0 ? rp.total[i] / p : 0.0
            rp.share[i] = w
        end
        sim.status[a].differ = w
    end
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════
# fifo_core_RCpp.cpp
# ═══════════════════════════════════════════════════════════════════════════

function calculate_fifo_price(buys::Vector{Lot}, units::Float64, front::Int)
    units_trade = units
    total_price = 0.0
    i = front
    n = length(buys)
    @inbounds while units_trade > 0 && i <= n
        b = buys[i]
        rem = b.remaining
        if rem > 0
            sell = cpp_min(rem, units_trade)
            total_price += sell * b.price
            units_trade -= sell
        end
        i += 1
    end
    return units > 0 ? total_price / units : 0.0
end

function calculate_fifo_vorabpauschale(buys::Vector{Lot}, units::Float64, front::Int)
    units_trade = units
    total_vp = 0.0
    i = front
    n = length(buys)
    @inbounds while units_trade > 0 && i <= n
        b = buys[i]
        rem = b.remaining
        if rem > 0
            sell = cpp_min(rem, units_trade)
            lot_vp = b.vp
            if rem > 0 && lot_vp > 0
                total_vp += sell * (lot_vp / rem)
            end
            units_trade -= sell
        end
        i += 1
    end
    return total_vp
end

function calculate_private_sale_tax(buys::Vector{Lot}, front::Int, trade_count::Float64,
                                    sell_price::Float64, current_date::Int)
    units_remaining = trade_count
    i = front
    n = length(buys)
    eg = el = tg = tl = 0.0
    @inbounds while units_remaining > 0 && i <= n
        b = buys[i]
        avail = b.remaining
        if avail > 0
            sell = cpp_min(avail, units_remaining)
            y, m, d = ymd(b.date)
            one_year_later = (m == 2 && d == 29 && !is_leap(y + 1)) ? days_from_civil(y + 1, 3, 1) :
                             days_from_civil(y + 1, m, d)
            is_exempt = current_date > one_year_later
            lot_gain = sell * (sell_price - b.price)
            if is_exempt
                lot_gain >= 0 ? (eg += lot_gain) : (el += -lot_gain)
            else
                lot_gain >= 0 ? (tg += lot_gain) : (tl += -lot_gain)
            end
            units_remaining -= sell
        end
        i += 1
    end
    return (exempt_gain = eg, exempt_loss = el, taxable_gain = tg, taxable_loss = tl,
            total_gain = eg - el + tg - tl)
end

function fifo_consume!(sim::Sim, a::Int, trade_count::Float64)
    tr = sim.trades[a]
    buys = tr.buys
    n = length(buys)
    front = tr.fifo_front
    units_remaining = trade_count
    i = front
    @inbounds while units_remaining > 0 && i <= n
        b = buys[i]
        rem = b.remaining
        if rem > 0
            red = cpp_min(rem, units_remaining)
            vp = b.vp
            if vp > 0 && rem > 0
                b.vp = vp * (1.0 - red / rem)
            end
            b.remaining = rem - red
            units_remaining -= red
        end
        i += 1
    end
    @inbounds while front <= n
        buys[front].remaining > 0 && break
        front += 1
    end
    tr.fifo_front = front
    return nothing
end

function update_fifo_front(buys::Vector{Lot}, front::Int)
    @inbounds while front <= length(buys)
        buys[front].remaining > 0 && return front
        front += 1
    end
    return front
end

# ═══════════════════════════════════════════════════════════════════════════
# tax_core_RCpp.cpp
# ═══════════════════════════════════════════════════════════════════════════

function flat_rate(buys::Vector{Lot}, front::Int, base_rate::Float64, year_start_price::Float64,
                   market_price::Float64, soy::Int, eoy::Int)
    n = length(buys)
    idx = Int[]
    vps = Float64[]
    front > n && return (total_vp = 0.0, lot_indices = idx, lot_vps = vps)
    @inbounds for i in front:n
        b = buys[i]
        rem = b.remaining
        rem <= 0 && continue
        vp = 0.0
        if b.date <= eoy
            if b.date < soy
                months_factor = 1.0
                reference_value = rem * year_start_price
            else
                _, m, _ = ymd(b.date)
                months_factor = (12.0 - (m - 1)) / 12.0
                reference_value = rem * b.price
            end
            base_worth = reference_value * base_rate * 0.7 * months_factor
            market_worth = rem * market_price
            growth = cpp_max(0.0, market_worth - reference_value)
            vp = cpp_max(0.0, cpp_min(base_worth, growth))
        end
        push!(idx, i)
        push!(vps, vp)
    end
    total = _LD0
    for v in vps
        total = total + F80(v)
    end
    return (total_vp = Float64(total), lot_indices = idx, lot_vps = vps)
end

function p20_tax!(trade_gain::Float64, bonus::Float64, t::Totals, tax_rate::Float64, use_spb::Bool)
    adjusted_gain = trade_gain * (1.0 - bonus)
    if adjusted_gain < 0
        t.loss_capital_gains = t.loss_capital_gains - adjusted_gain
        t.cgt_loss_added_ytd = t.cgt_loss_added_ytd - adjusted_gain
        return (tax = 0.0, spb_used = 0.0)
    end
    pool = t.loss_capital_gains
    loss_offset = cpp_min(adjusted_gain, pool)
    t.loss_capital_gains = pool - loss_offset
    t.cgt_loss_used_ytd = t.cgt_loss_used_ytd + loss_offset
    gain_after_loss = adjusted_gain - loss_offset
    spb_offset = 0.0
    spb_rem = t.sparer_pauschbetrag_remaining
    if use_spb && spb_rem > 0
        spb_offset = cpp_min(gain_after_loss, spb_rem)
        t.sparer_pauschbetrag_remaining = spb_rem - spb_offset
        t.sparer_pauschbetrag_used_total = t.sparer_pauschbetrag_used_total + spb_offset
    end
    taxable_gain = gain_after_loss - spb_offset
    t.cgt_base_taxed_ytd = t.cgt_base_taxed_ytd + taxable_gain
    tax = taxable_gain * tax_rate
    t.total_taxes = t.total_taxes + tax
    return (tax = tax, spb_used = spb_offset)
end

function vp_tax!(flat_rate_value::Float64, bonus::Float64, t::Totals, tax_rate::Float64, use_spb::Bool)
    taxable_flat_rate = flat_rate_value * (1.0 - bonus)
    pool = t.loss_capital_gains
    loss_offset = cpp_min(taxable_flat_rate, pool)
    t.loss_capital_gains = pool - loss_offset
    t.cgt_loss_used_ytd = t.cgt_loss_used_ytd + loss_offset
    vp_after_loss = taxable_flat_rate - loss_offset
    spb_offset = 0.0
    spb_rem = t.sparer_pauschbetrag_remaining
    if use_spb && spb_rem > 0
        spb_offset = cpp_min(vp_after_loss, spb_rem)
        t.sparer_pauschbetrag_remaining = spb_rem - spb_offset
        t.sparer_pauschbetrag_used_total = t.sparer_pauschbetrag_used_total + spb_offset
    end
    taxable_gain = vp_after_loss - spb_offset
    t.cgt_base_taxed_ytd = t.cgt_base_taxed_ytd + cpp_max(0.0, taxable_gain)
    tax = cpp_max(0.0, taxable_gain * tax_rate)
    return (tax = tax, spb_used = spb_offset, taxable_amount = taxable_flat_rate)
end

function _fifo_fast(units::Float64, cu::Vector{Float64}, cc::Vector{Float64}, prices::Vector{Float64})
    n = length(cu)
    units <= 0 && return 0.0
    units >= cu[n] && return cc[n] / cu[n]
    lot = 0
    @inbounds while lot < n && cu[lot+1] < units
        lot += 1
    end
    lot_idx = min(lot + 1, n)
    lot_idx == 1 && return prices[1]
    prev_cost = cc[lot_idx-1]
    prev_units = cu[lot_idx-1]
    rem = units - prev_units
    return (prev_cost + rem * prices[lot_idx]) / units
end

const REGIME_CODE = Dict("none" => 0, "investment_fund" => 1, "capital_gains" => 2, "private_sale" => 3)

function sell_count(buys::Vector{Lot}, front::Int, target::Float64, trade_price::Float64,
                    total_shares::Float64, fractions::Bool, regime::Int, bonus::Float64,
                    loss_pool::Float64, tax_rate::Float64)
    zero_ = (sell_count = 0.0, fifo_price = 0.0)
    n = length(buys)
    front > n && return zero_
    units = Float64[]; prices = Float64[]
    @inbounds for i in front:n
        b = buys[i]
        if b.remaining > 0
            push!(units, b.remaining); push!(prices, b.price)
        end
    end
    isempty(units) && return zero_
    cu = similar(units); cc = similar(units)
    su = _LD0; sc = _LD0
    @inbounds for k in eachindex(units)
        su = su + F80(units[k])
        cu[k] = Float64(su)
        sc = sc + F80(units[k] * prices[k])
        cc[k] = Float64(sc)
    end
    function objective(sell::Float64)
        sell <= 0 && return -target
        sell > total_shares && (sell = total_shares)
        fp = _fifo_fast(sell, cu, cc, prices)
        gain = (trade_price - fp) * sell
        tax = 0.0
        if regime == 1
            adj = gain * (1.0 - bonus)
            tax = cpp_max(adj - loss_pool, 0.0) * tax_rate
        elseif regime == 2
            tax = cpp_max(gain - loss_pool, 0.0) * tax_rate
        end
        return sell * trade_price - tax - target
    end
    initial = target / trade_price
    lower = cpp_max(1e-6, initial * 0.1)
    upper = cpp_min(initial * 3.0, total_shares)
    f_lower = objective(lower)
    f_upper = objective(upper)
    tol = fractions ? 1e-6 : 0.5
    local sell::Float64
    if f_lower >= 0
        sell = lower
    elseif f_upper <= 0
        sell = upper
    elseif abs(f_lower) < tol
        sell = lower
    elseif abs(f_upper) < tol
        sell = upper
    else
        sell = (lower + upper) * 0.5
        for _ in 1:30
            mid = (lower + upper) * 0.5
            fm = objective(mid)
            if abs(fm) < tol || (upper - lower) < tol
                sell = mid
                break
            end
            if fm * f_lower < 0
                upper = mid; f_upper = fm
            else
                lower = mid; f_lower = fm
            end
            sell = (lower + upper) * 0.5
        end
    end
    if !fractions
        tl = floor(sell)
        tu = ceil(sell)
        tl < 1 && (tl = 1.0)
        tu > total_shares && (tu = total_shares)
        sell = abs(objective(tl)) <= abs(objective(tu)) ? tl : tu
    end
    final_fp = _fifo_fast(sell, cu, cc, prices)
    out = cpp_max(0.0, cpp_min(sell, total_shares))
    return (sell_count = out, fifo_price = final_fp)
end
