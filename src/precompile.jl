# Kleine Arbeitslast beim Vorkompilieren: Damit liegt der Maschinencode der
# Engine im Paket-Cache, und der erste Aufruf von simulation() ist sofort schnell.
if ccall(:jl_generating_output, Cint, ()) == 1
    let
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            n = 800
            dates = collect(Date(2019, 1, 1):Day(1):Date(2019, 1, 1) + Day(n - 1))
            px(a, b) = [100 * (1 + a * i / n + 0.05 * sin(b * i)) for i in 1:n]
            sb = [i % 37 < 5 for i in 1:n]; ss = [i % 37 > 25 for i in 1:n]
            data = (date = dates, A = px(0.5, 0.05), B = px(0.1, 0.11), C = px(3.0, 0.07),
                    b = sb, s = ss, ev = [i % 50 == 0 for i in 1:n], br = fill(2.55, n), w1 = fill(0.6, n))
            s2 = create_strategy(A = asset_config("etf", "bnh", 0.6, 0.1, 30), B = asset_config("etf", "bnh", 0.4, 0.1, 0))
            s3 = create_strategy(A = asset_config("certificate", "signal", 0.4, 0.2, 0; signal_buy = "b", signal_sell = "s"),
                                 B = asset_config("etc", "bnh", 0.3, 0.1, 0; deliverable = true),
                                 C = asset_config("etf", "bnh", 0.3, 0.1, 30; asset_start = dates[100]))
            io = devnull
            for det in (false, true)
                r = simulation(data, s2; tax_mode = "person", balance_mode = true, dca_mode = true, dca_value = 100,
                               dca_span = 1, liquidate = true, base_rate = 2.55, details = det, io = io)
                format_result(r)
                summary(r; io = io)
                simulation(data, s3; tax_mode = "person", marginal_tax_rate = 42, balance_mode = true,
                           balance_unit = "quarter", balance_thresh = 2, split_mode = true, split_thresh = [50, 200],
                           fractions = false, event_col = "ev", event_weight = (A = "w1",), risk_free = 2,
                           use_guenstigerpruefung = true, details = det, io = io)
                simulation(data, s2; tax_mode = "funds", liquidate = true, base_rate_flex = true, base_rate_data = "br",
                           dca_mode = true, dca_value = 50.0, dca_span = 1, dca_days = [1, 15], dca_unit = "month",
                           balance_mode = true, balance_days = 31, balance_anchor = "end", risk_free = "br", details = det, io = io)
            end
            gaps = (date = dates[1:2:end], A = px(0.5, 0.05)[1:2:end])
            simulation(gaps, create_strategy(A = asset_config("etf", "bnh", 1.0, 0.1, 30)); io = io)
            compute_rebal_trigger((date = dates, target_leverage = px(0.1, 0.2) ./ 50), "abs_leverage")
        end
    end
end
