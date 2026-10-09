using SimLev
using Test
using Dates
using Random
using Logging

include("golden_tools.jl")

quiet(f) = with_logger(NullLogger()) do
    f()
end
days(start, n) = collect(Date(start):Day(1):Date(start) + Day(n - 1))
weekdays(a, b) = [d for d in Date(a):Day(1):Date(b) if dayofweek(d) <= 5]
gbm(rng, n, s0, mu, sig) = s0 .* cumprod(1 .+ mu .+ sig .* randn(rng, n))
make_data(n = 100; seed = 42) = (rng = MersenneTwister(seed); (date = days("2020-01-01", n), ETF = gbm(rng, n, 100, 0.001, 0.02)))
legacy() = ["ETF" => (asset_class = "etf", action_type = "bnh", asset_share = 1.0, asset_spread = 0.1, asset_bonus = 0)]
idx(r, d) = findfirst(==(Date(d)), r.dates)

@testset "SimLev" begin

# ─────────────────────────────────────────────────────────────────────────────
@testset "80-Bit long double (F80) gegen BigFloat" begin
    rng = MersenneTwister(1)
    gen() = (k = rand(rng, 1:4);
             k == 1 ? (rand(rng) - 0.5) * 10.0^rand(rng, -20:20) :
             k == 2 ? 1 + (rand(rng) - 0.5) * 10.0^(-rand(rng, 0:15)) :
             k == 3 ? round(100 * exp(randn(rng)); digits = rand(rng, 0:6)) : Float64(rand(rng, -50:50)))
    nbad = 0
    setprecision(BigFloat, 64) do
        for _ in 1:4000
            a = SimLev.F80(gen()); b = BigFloat(Float64(a))
            for _ in 1:12
                x = gen(); op = rand(rng, 1:4)
                fa = op == 1 ? a + SimLev.F80(x) : op == 2 ? a - SimLev.F80(x) : op == 3 ? a * SimLev.F80(x) : a / SimLev.F80(x)
                fb = op == 1 ? b + x : op == 2 ? b - x : op == 3 ? b * x : b / x
                nbad += !(Float64(fa) === Float64(fb) || (isnan(Float64(fa)) && isnan(Float64(fb))))
                a, b = fa, fb
            end
        end
    end
    @test nbad == 0
    # Zwischenergebnisse mit 64 Bit Mantisse, danach Rundung auf 53 Bit – wie die x87-FPU
    @test Float64(SimLev.F80(1.0) + SimLev.F80(2.0^-53) + SimLev.F80(2.0^-60)) == nextfloat(1.0)
    @test (1.0 + 2.0^-53) + 2.0^-60 == 1.0
    @test Float64(SimLev.F80(1.0) + SimLev.F80(2.0^-53) + SimLev.F80(2.0^-65)) == 1.0   # doppelte Rundung
end

@testset "R-Numerik" begin
    @test SimLev.r_sum([0.1, 0.2, 0.3]) == 0.6000000000000001 || SimLev.r_sum([0.1, 0.2, 0.3]) == 0.6
    @test isna_strict(SimLev.r_sum([1.0, NA]))
    @test isnan(SimLev.r_sum([NaN, NA])) && !isna_strict(SimLev.r_sum([NaN, NA]))   # wie R: sum(c(NaN, NA)) = NaN
    @test isna_strict(SimLev.r_sum([NA, NaN]))                                       # sum(c(NA, NaN)) = NA
    @test isna_strict(SimLev.r_var([1.0]))
    @test isnan(SimLev.r_mean(Float64[]))
    @test SimLev.r_pow(2.0, 2.0) == 4.0
    @test SimLev.rsprintf("%+.2f%%", NA) == "NA%"
    @test SimLev.rsprintf("%+.2f%%", NaN) == "NaN%"
    @test SimLev.rsprintf("%+.2f", Inf) == "+Inf"
    @test SimLev.rsprintf("%10.2f", NA) == "        NA"
    @test SimLev.r_format_digits(128217.0, 5) == "128217"
    @test SimLev.r_format_digits(99999.5, 5) == "1e+05"
    @test SimLev.r_format_digits(0.000123456, 5) == "0.00012346"
    @test SimLev.r_round(8.938114141025938e12, 2) == 8.938114141025938e12
    @test SimLev.r_round(2.675, 2) == 2.67
end

# ─────────────────────────────────────────────────────────────────────────────
@testset "asset_config und Strategien" begin
    cfg = asset_config("etf"; asset_share = 0.7, asset_bonus = 30)
    @test cfg isa AssetConfig
    @test cfg.asset_class == "etf" && cfg.asset_share == 0.7 && cfg.asset_bonus == 30
    @test cfg.tax_regime == "investment_fund" && cfg.deliverable == false
    for (cls, deliv, regime) in [("etf", false, "investment_fund"), ("etn", true, "private_sale"), ("etn", false, "capital_gains"),
                                 ("etc", true, "private_sale"), ("etc", false, "capital_gains"), ("certificate", false, "capital_gains")]
        @test asset_config(cls; deliverable = deliv).tax_regime == regime
    end
    @test asset_config("etf"; tax_regime = "capital_gains").tax_regime == "capital_gains"
    for (old, deliv, regime) in [("etn_deliverable", true, "private_sale"), ("etn_standard", false, "capital_gains")]
        c = @test_logs (:warn, r"deprecated") asset_config(old)
        @test c.asset_class == "etn" && c.deliverable == deliv && c.tax_regime == regime
    end
    for sh in (0, 1.5, -0.1)
        @test_throws ArgumentError asset_config(; asset_share = sh)
    end
    @test_throws ArgumentError asset_config(; action_type = "signal")
    c = asset_config(; action_type = "signal", signal_buy = "buy_col", signal_sell = "sell_col")
    @test c.signal_buy == "buy_col" && c.signal_sell == "sell_col"
    @test_throws ArgumentError asset_config(; tax_regime = "invalid")
    @test asset_config("cert").asset_class == "certificate"                        # Präfix wie match.arg
    @test asset_config(; action_type = "sig", signal_buy = "a", signal_sell = "b").action_type == "signal"
    @test occursin("Asset Configuration", sprint(show, MIME"text/plain"(), asset_config("etf"; asset_bonus = 30)))

    s = create_strategy(SPY = asset_config("etf", "bnh", 0.6, 0.1, 30), BND = asset_config("etf", "bnh", 0.4, 0.05, 0))
    @test s isa Strategy && collect(keys(s)) == ["SPY", "BND"]
    s1 = create_strategy(assets = ["A" => (asset_class = "etf", asset_share = 1.0)])
    @test s1["A"] isa AssetConfig
    @test_throws ArgumentError create_strategy(assets = ["A" => asset_config()], B = asset_config())
    @test_throws ArgumentError create_strategy()
    df = (date = days("2020-01-01", 3), SPY = [1, 2, 3], BND = [1, 2, 3])
    @test validate_strategy(s, df)
    @test_throws ArgumentError validate_strategy(s, (date = df.date, SPY = df.SPY))
    s2 = add_asset(s, "GOLD", asset_config("etc"; asset_share = 0.1, deliverable = true))
    @test haskey(s2, "GOLD") && !haskey(s, "GOLD")
    s3 = update_asset(s2, "SPY"; asset_share = 0.5)
    @test s3["SPY"].asset_share == 0.5
    @test_logs (:warn, r"Unknown parameter") update_asset(s2, "SPY"; nonsense = 1)
    @test_throws ArgumentError update_asset(s2, "XXX"; asset_share = 0.5)
    @test collect(keys(remove_asset(s3, "GOLD"))) == ["SPY", "BND"]
    @test_logs (:warn, r"empty") remove_asset(create_strategy(A = asset_config()), "A")
    m = quiet(() -> migrate_strategy(["G" => (asset_class = "etn_deliverable", asset_share = 1.0)]))
    @test m["G"].asset_class == "etn" && m["G"].deliverable
    @test occursin("Investment Strategy (2 assets)", sprint(show, MIME"text/plain"(), s))
    @test occursin("Total allocation: 100.0%", sprint(io -> summary(s; io = io)))
end

# ─────────────────────────────────────────────────────────────────────────────
@testset "Engine: Grundfunktionen" begin
    r = simulation(make_data(), legacy(); start_value = 10000)
    @test length(r.worth) == 100 && length(r.dates) == 100 && length(r.filled) == 100
    @test isapprox(r.worth[1], 10000; rtol = 0.01)
    d = make_data(365)
    r0 = simulation(d, legacy(); start_value = 10000)
    r1 = simulation(d, legacy(); start_value = 10000, dca_mode = true, dca_value = 1000, dca_span = 1, dca_unit = "month", dca_days = 1)
    @test r1.worth[end] > r0.worth[end]
    @test sum(r1.report["ETF"].flows) > 0
    simulation(make_data(), legacy(); tax_mode = "none", liquidate = true)
    simulation(make_data(), legacy(); tax_mode = "person", tax_rate = 26.375, liquidate = true)
    simulation(make_data(1), legacy())
    @test_throws ArgumentError simulation(make_data(), legacy(); start_value = 0)
    @test_throws ArgumentError simulation(make_data(), legacy(); unbekannt = 1)
    dd = make_data(); s = create_strategy(A = asset_config(; asset_share = 0.5), B = asset_config(; asset_share = 0.4))
    err = try simulation((date = dd.date, A = dd.ETF, B = dd.ETF), s); catch e; e; end
    @test err isa ArgumentError && occursin("summieren sich auf 0.9000", err.msg)
    dup = (date = [Date(2020, 1, 1); days("2020-01-01", 5)], ETF = collect(1.0:6.0) .+ 100)
    @test_throws ArgumentError quiet(() -> simulation(dup, legacy()))
    t = @elapsed simulation(make_data(3650), legacy(); start_value = 10000)
    @test t < 5
end

@testset "Engine: LOCF und Risk-Free" begin
    rng = MersenneTwister(99)
    wd = weekdays("2021-01-04", "2021-12-31")
    r = quiet(() -> simulation((date = wd, ETF = gbm(rng, length(wd), 100, 4e-4, 0.011)), legacy()))
    @test count(r.filled) == count(d -> dayofweek(d) >= 6, r.dates)
    @test 0.005 < r.statistics.sd < 0.03 && isfinite(r.statistics.sharpe)

    rng = MersenneTwister(77)
    wd = weekdays("2022-01-01", "2022-12-31")
    d = (date = wd, ETF = gbm(rng, length(wd), 100, 3e-4, 0.011), sofr = collect(range(0.01, 0.04; length = length(wd))),
         rf_const = fill(3.0, length(wd)))
    rs(; kw...) = quiet(() -> simulation(d, legacy(); kw...))
    @test rs(risk_free = nothing).statistics.sharpe == rs(risk_free = 0).statistics.sharpe == rs().statistics.sharpe
    @test rs(risk_free = 3).statistics.sharpe < rs(risk_free = 0).statistics.sharpe
    @test isapprox(rs(risk_free = "rf_const").statistics.sharpe, rs(risk_free = 3).statistics.sharpe; atol = 1e-9)
    @test_throws ArgumentError rs(risk_free = "nonexistent")
    @test isapprox(rs(risk_free = 2).statistics.risk_free, 2; atol = 1e-9)
end

@testset "Engine: Terminplanung" begin
    rng = MersenneTwister(1)
    wd = weekdays("2022-01-01", "2022-12-31")
    d = (date = wd, ETF = gbm(rng, length(wd), 100, 4e-4, 0.01))
    r = quiet(() -> simulation(d, legacy(); start_value = 1000, dca_mode = true, dca_value = 1000, dca_span = 1))
    fl = findall(x -> abs(x) > 1e-9, r.report["ETF"].flows)
    @test !any(r.filled[fl])
    @test Date("2022-05-02") in r.dates[fl] && Date("2022-10-03") in r.dates[fl]
    r = quiet(() -> simulation(d, legacy(); start_value = 1000, dca_mode = true, dca_value = 1000, dca_span = 1,
                               dca_days = 1, dca_anchor = "end"))
    fl = findall(x -> abs(x) > 1e-9, r.report["ETF"].flows)
    @test Date("2022-04-29") in r.dates[fl] && Date("2022-07-29") in r.dates[fl]
    # Startdatum hinter dem Datenende: wie R ein Fehler
    @test_throws ArgumentError quiet(() -> simulation(d, legacy(); balance_mode = true, balance_start = Date(2023, 3, 1)))
end

@testset "Engine: Signale beim Rebalancing" begin
    sig = create_strategy(SIG = asset_config("etf", "signal", 1, 0, 30; signal_buy = "buy_sig", signal_sell = "sell_sig"))
    function pulse(buy_on, sell_on = nothing; n = 120, seed = 2)
        rng = MersenneTwister(seed); dd = days("2022-01-03", n)
        (date = dd, SIG = gbm(rng, n, 100, 4e-4, 0.01), buy_sig = [x in Date.(buy_on) for x in dd],
         sell_sig = [sell_on !== nothing && x == Date(sell_on) for x in dd])
    end
    r = simulation(pulse(["2022-02-01"]), sig; balance_mode = true, balance_span = 1, balance_unit = "month")
    @test r.report["SIG"].worth[idx(r, "2022-02-02")] > 0
    @test r.report["SIG"].worth[idx(r, "2022-01-15")] == 0
    @test r.report["SIG"].money[idx(r, "2022-01-15")] > 9999
    r2 = simulation(pulse(["2022-01-10"], "2022-03-01"), sig; balance_mode = true, balance_span = 1, balance_unit = "month")
    @test r2.report["SIG"].worth[idx(r2, "2022-02-28")] > 0
    @test r2.report["SIG"].worth[idx(r2, "2022-03-02")] == 0
end

@testset "Engine: Vorabpauschale und Prozent-Konvention" begin
    vps = create_strategy(ETF = asset_config("etf", "bnh", 1, 0, 30))
    function vp_data(stop; gaps = true, seed = 9)
        rng = MersenneTwister(seed)
        dd = gaps ? weekdays("2022-01-01", stop) : collect(Date(2022, 1, 1):Day(1):Date(stop))
        (date = dd, ETF = gbm(rng, length(dd), 100, 8e-4, 0.008), base_rate = fill(2.55, length(dd)))
    end
    d = vp_data("2023-01-31")
    r = quiet(() -> simulation(d, vps; tax_mode = "person", base_rate_flex = true, base_rate_data = "base_rate",
                               use_sparer_pauschbetrag = false))
    @test r.tax_report.total_taxes_paid > 0
    d2 = vp_data("2022-12-31"; gaps = false)
    @test simulation(d2, vps; tax_mode = "person", base_rate_flex = true, base_rate_data = "base_rate",
                     use_sparer_pauschbetrag = false).tax_report.total_taxes_paid > 0
    lin = (date = days("2022-01-03", 200), ETF = collect(range(100, 150; length = 200)))
    r = simulation(lin, create_strategy(ETF = asset_config("etf", "bnh", 1, 0, 0)); tax_mode = "person", tax_rate = 26.375,
                   use_sparer_pauschbetrag = false, liquidate = true)
    @test isapprox(r.tax_report.total_taxes_paid / 5000, 0.26375; rtol = 1e-6)
    r = simulation(lin, vps; tax_mode = "person", tax_rate = 25, use_sparer_pauschbetrag = false, liquidate = true)
    @test isapprox(r.tax_report.total_taxes_paid, 5000 * 0.7 * 0.25; rtol = 1e-6)
end

@testset "Engine: DCA nach Strategie-Gewichten" begin
    rng = MersenneTwister(1); n = 200
    d = (date = days("2022-01-03", n), A = gbm(rng, n, 100, 15e-4, 0.01), B = gbm(rng, n, 100, -2e-4, 0.004),
         C = gbm(rng, n, 100, 3e-4, 0.006))
    s = create_strategy(A = asset_config("etf", "bnh", 0.7, 0, 30), B = asset_config("etf", "bnh", 0.3, 0, 30))
    r = simulation((date = d.date, A = d.A, B = d.B), s; dca_mode = true, dca_value = 500, dca_span = 1)
    i = findfirst(k -> r.report["A"].flows[k] > 0 && r.dates[k] > Date(2022, 5, 1), eachindex(r.dates))
    @test isapprox(r.report["A"].flows[i], 350; atol = 1e-9) && isapprox(r.report["B"].flows[i], 150; atol = 1e-9)
    s3 = create_strategy(A = asset_config("etf", "bnh", 0.63, 0, 30), B = asset_config("etf", "bnh", 0.27, 0, 30),
                         C = asset_config("etf", "bnh", 0.10, 0, 0; asset_start = "2022-04-01"))
    r = simulation(d, s3; dca_mode = true, dca_value = 500, dca_span = 1)
    k2 = findfirst(>(0), r.report["C"].flows)
    @test isapprox([r.report[a].flows[k2] for a in ("A", "B", "C")], [315, 135, 50]; atol = 1e-9)
end

@testset "Ausgabe" begin
    r = simulation(make_data(400), legacy(); tax_mode = "person", liquidate = true)
    txt = sprint(show, MIME"text/plain"(), r)
    @test occursin("SimLev Simulation Results", txt) && txt == format_result(r)
    res = summary(r; io = devnull)
    @test res.n_days == 400
    io = IOBuffer(); simulation(make_data(400), legacy(); tax_mode = "person", details = true, io = io)
    @test occursin("Buying", String(take!(io)))
end

# ─────────────────────────────────────────────────────────────────────────────
@testset "Trigger (Referenzwerte aus R)" begin
    df = (date = days("2020-01-01", 10), target_leverage = [2.00, 2.05, 2.30, 2.28, 1.95, 1.90, 2.40, 2.42, 2.10, 2.00],
          sigma_ewma = [0.10, 0.11, 0.16, 0.15, 0.10, 0.10, 0.20, 0.22, 0.14, 0.12])
    df = compute_rebal_trigger(df, "abs_leverage"; threshold = 10, out_col = "a")
    df = compute_rebal_trigger(df, "rel_leverage"; threshold = 10, out_col = "r")
    df = compute_rebal_trigger(df, "vol_band"; threshold = 20, out_col = "v")
    df = compute_rebal_trigger(df, "combined"; triggers = [(type = "abs_leverage", threshold = 10),
                                                           (type = "vol_band", threshold = 20)], out_col = "c")
    T, F = true, false
    @test df.a == [F, F, T, F, T, F, T, F, T, T]
    @test df.r == [F, F, T, F, T, F, T, F, T, F]
    @test df.v == [F, F, T, F, T, F, T, F, T, F]
    @test df.c == [F, F, T, F, T, F, T, F, T, T]
    @test_throws ArgumentError compute_rebal_trigger(df, "nope")
    @test_throws ArgumentError compute_rebal_trigger(df, "abs_leverage"; lev_col = "xx")
    @test_throws ArgumentError compute_rebal_trigger(df, "combined")
end

@testset "Dashboards" begin
    n = 400
    d = (date = days("2022-01-03", n), A = collect(range(100, 130; length = n)), B = collect(range(100, 110; length = n)))
    r = simulation(d, create_strategy(A = asset_config("etf", "bnh", 0.6, 0, 30), B = asset_config("etf", "bnh", 0.4, 0, 0)))
    f = tempname() * ".html"
    @test plot_interactive(r; file = f, open = false) == f
    txt = read(f, String)
    @test all(t -> occursin(t, txt), ("makePanel", "Gesamt", "2022-01", "hover", "weights"))
    plot_interactive(r; file = f, panels = "drawdown", max_points = 100, open = false)
    txt = read(f, String)
    @test occursin("\"drawdown\"", txt) && !occursin("id=\"performance\"", txt)
    @test length(collect(eachmatch(r"\d{4}-\d{2}-\d{2}", txt))) <= 110
    dsh = plot_dashboard(r)
    @test dsh isa SimLevDashboard && occursin("Monthly Returns Heatmap", dsh.svg)
    @test occursin("Strategy Comparison", plot_dashboard(r; compare = r).svg)
    @test !occursin("Rolling", plot_dashboard(r; style = "compact").svg)
    g = tempname() * ".svg"
    quiet(() -> export_dashboard(r, g))
    @test filesize(g) > 1000
    h = tempname() * ".html"
    export_html_dashboard(r, h)
    @test isfile(h)
end

# ─────────────────────────────────────────────────────────────────────────────
@testset "Bitgleichheit zu R (Golden Master, strikt)" begin
    exact = true    # F80 bildet x87 unabhängig von der Plattform nach; libm-pow ist die Grenze
    for dir in ("golden", "golden_extra")
        path = joinpath(@__DIR__, dir)
        isdir(path) || continue
        for f in sort(readdir(path))
            endswith(f, ".json.gz") || continue
            if f == "x24_dup_dates.json.gz"
                # Bewusste Abweichung: R rechnet mit doppelten Datumswerten stillschweigend weiter
                @test any(e -> occursin("doppelte Datumswerte", e), run_case(joinpath(path, f)))
                continue
            end
            errs = run_case(joinpath(path, f); strict_na = Sys.islinux())
            if !isempty(errs) && !Sys.islinux()
                @test_broken isempty(errs)      # pow() anderer C-Bibliotheken kann im letzten Bit abweichen
            else
                isempty(errs) || @info "Abweichung in $f" errs
                @test isempty(errs)
            end
        end
    end
end

end
