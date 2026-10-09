"""
    SimLev

Backtesting für ETF-, Hebel- und Multi-Asset-Strategien mit deutscher
Investmentbesteuerung. Julia-Portierung des gleichnamigen R-Pakets; die
Engine rechnet bitgleich zur R-Version (Linux x86-64).
"""
module SimLev

using Dates
using Printf

export simulation, SimLevResult, format_result,
       asset_config, AssetConfig, create_strategy, Strategy, validate_strategy,
       add_asset, update_asset, remove_asset, migrate_strategy, as_list,
       compute_rebal_trigger, plot_interactive, plot_dashboard, export_dashboard,
       export_html_dashboard, SimLevDashboard, NA, isna_strict

include("ld80.jl")
include("rnum.jl")
include("rformat.jl")
include("dates.jl")
include("config.jl")
include("trigger.jl")
include("data.jl")
include("core.jl")
include("result.jl")
include("engine.jl")
include("interactive.jl")
include("dashboard.jl")
include("precompile.jl")

end # module
