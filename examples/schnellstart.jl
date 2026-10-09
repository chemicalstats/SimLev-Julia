# Schnellstart: zehn Jahre einer 70/30-Mischung aus Aktien- und Anleihe-ETF
#
#   julia --project=. examples/schnellstart.jl

using SimLev, Dates, Random

# 1. Preisdaten: eine Datumsspalte plus eine Preisspalte je Asset
#    (synthetisch, damit das Beispiel ohne externe Daten läuft)
rng = MersenneTwister(42)
n = 365 * 10
data = (date  = collect(Date(2015, 1, 1):Day(1):Date(2015, 1, 1) + Day(n - 1)),
        WORLD = 100 .* cumprod(1 .+ 4e-4 .+ 0.010 .* randn(rng, n)),
        BONDS =  50 .* cumprod(1 .+ 1e-4 .+ 0.003 .* randn(rng, n)))

# 2. Strategie: Gewichte, Kosten und Teilfreistellung
#    (30 % für Aktien-ETFs, 0 % für Renten-ETFs)
strategy = create_strategy(
    WORLD = asset_config("etf", "bnh"; asset_share = 0.7, asset_spread = 0.1, asset_bonus = 30),
    BONDS = asset_config("etf", "bnh"; asset_share = 0.3, asset_spread = 0.1, asset_bonus = 0),
)

# 3. Simulation: 10.000 EUR Einmalanlage, jährliches Rebalancing,
#    deutsche Privatbesteuerung, Verkauf aller Positionen am Ende
result = simulation(data, strategy;
    start_value = 10000,
    balance_mode = true, balance_span = 1, balance_unit = "year",
    tax_mode = "person", tax_rate = 26.375,
    liquidate = true,
    risk_free = 2)

display(result)
println()

# 4. Dashboards
plot_dashboard(result; file = "schnellstart_dashboard.svg", currency = "€")
plot_interactive(result; file = "schnellstart_dashboard.html", open = false)
println("Dashboards geschrieben: schnellstart_dashboard.svg, schnellstart_dashboard.html")
