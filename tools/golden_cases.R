# Erzeugt Golden-Master-Faelle: Daten + Argumente + exakte R-Ergebnisse (hex).
# Aufruf: Rscript golden_cases.R <outdir> <n_random> <seed>
suppressMessages({library(SimLev); library(jsonlite)})
args <- commandArgs(TRUE)
outdir <- args[1]; n_random <- as.integer(args[2]); seed0 <- as.integer(args[3])
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

hx <- function(x) { x <- as.numeric(x); out <- sprintf("%a", x); out[is.na(x)] <- "NA"; out[is.nan(x)] <- "NaN"; out }

enc_data <- function(df) {
  cols <- list()
  for (nm in names(df)) {
    v <- df[[nm]]
    if (inherits(v, "Date")) cols[[nm]] <- list(type = "date", values = as.integer(v))
    else if (is.logical(v)) cols[[nm]] <- list(type = "logical", values = v)
    else cols[[nm]] <- list(type = "numeric", values = hx(v))
  }
  list(order = names(df), cols = cols)
}

enc_strategy <- function(s) {
  lapply(s, function(a) {
    a <- unclass(a)
    if (!is.null(a$asset_start)) a$asset_start <- format(as.Date(a$asset_start))
    for (k in c("asset_share", "asset_spread", "asset_bonus")) if (!is.null(a[[k]])) a[[k]] <- list(hex = hx(a[[k]]))
    a
  })
}

enc_result <- function(r) {
  st <- r$statistics
  list(
    worth = hx(r$worth), drawdowns = hx(r$drawdowns), filled = r$filled,
    cagr = hx(r$cagr), ttwror = hx(r$ttwror),
    statistics = lapply(st, hx),
    buys = lapply(as.list(r$buys), hx), sells = lapply(as.list(r$sells), hx),
    tax_report = lapply(r$tax_report, hx),
    report = lapply(r$report, function(a) lapply(a, hx)),
    print = paste(capture.output(print(r)), collapse = "\n")
  )
}

run_case <- function(id, data, strategy, sargs) {
  stdout_txt <- NULL
  res <- tryCatch(suppressWarnings(suppressMessages({
                    stdout_txt <- capture.output(r <- do.call(simulation,
                      c(list(data = data, strategy = strategy), sargs))); r })),
                  error = function(e) e)
  out <- list(id = id, data = enc_data(data), strategy = enc_strategy(strategy),
              args = lapply(sargs, function(v) if (inherits(v, "Date")) format(v) else v))
  if (inherits(res, "error")) out$error <- conditionMessage(res) else out$result <- enc_result(res)
  if (isTRUE(sargs$details)) out$stdout <- paste(stdout_txt, collapse = "\n")
  writeLines(toJSON(out, digits = NA, auto_unbox = TRUE, null = "null", na = "null"),
             file.path(outdir, sprintf("%s.json", id)))
  invisible(res)
}

# ── Datengeneratoren ─────────────────────────────────────────────────────────
mk_dates <- function(start, n) seq.Date(as.Date(start), by = "day", length.out = n)
gbm <- function(n, s0, mu, sig, lev = 1) s0 * cumprod(1 + lev * rnorm(n, mu, sig))
sma <- function(x, k) { f <- stats::filter(x, rep(1/k, k), sides = 1); as.numeric(f) }

ac <- function(...) asset_config(...)

# ── Feste Szenarien ──────────────────────────────────────────────────────────
set.seed(1)
n <- 365 * 6
d1 <- data.frame(date = mk_dates("2015-01-01", n), WORLD = gbm(n, 100, 4e-4, 0.010), BONDS = gbm(n, 50, 1e-4, 0.003))
s2 <- create_strategy(WORLD = ac("etf", "bnh", 0.7, 0.1, 30), BONDS = ac("etf", "bnh", 0.3, 0.1, 0))
s1 <- create_strategy(WORLD = ac("etf", "bnh", 1, 0.1, 30))

run_case("f01_bnh_none", d1, s1, list(start_value = 10000))
run_case("f02_rebal_tax", d1, s2, list(start_value = 10000, balance_mode = TRUE, balance_span = 1,
         balance_unit = "year", tax_mode = "person", tax_rate = 26.375, liquidate = TRUE, risk_free = 2))
run_case("f03_dca_vp", d1, s2, list(start_value = 10000, dca_mode = TRUE, dca_value = 250, dca_span = 1,
         dca_unit = "month", balance_mode = TRUE, balance_span = 1, balance_unit = "year", balance_dca = TRUE,
         tax_mode = "person", liquidate = TRUE, base_rate = 2.55))
d1b <- d1; d1b$br <- rep(c(-0.45, -0.05, 2.55, 2.29, 1.0, 0.5), each = 365)
run_case("f04_vp_flex", d1b, s2, list(start_value = 50000, tax_mode = "person", base_rate_flex = TRUE,
         base_rate_data = "br", sparer_pauschbetrag = 2000))
d1c <- d1; d1c$s50 <- sma(d1c$WORLD, 50); d1c$s200 <- sma(d1c$WORLD, 200)
d1c$buy <- !is.na(d1c$s200) & d1c$s50 > d1c$s200; d1c$sell <- !is.na(d1c$s200) & d1c$s50 < d1c$s200
d1c$s50 <- NULL; d1c$s200 <- NULL
s_sig <- create_strategy(WORLD = ac("certificate", "signal", 0.6, 0.2, 0, signal_buy = "buy", signal_sell = "sell"),
                         BONDS = ac("etf", "bnh", 0.4, 0.1, 0))
run_case("f05_signal_cg", d1c, s_sig, list(tax_mode = "person", balance_mode = TRUE, balance_unit = "quarter",
         balance_span = 1, liquidate = TRUE))
set.seed(5)
n5 <- 900
d5 <- data.frame(date = mk_dates("2019-03-10", n5), GOLD = gbm(n5, 60, 2e-4, 0.012), ETF = gbm(n5, 80, 3e-4, 0.011))
d5$b <- rep(c(TRUE, FALSE), length.out = n5) & (seq_len(n5) %% 37 < 10)
d5$s <- (seq_len(n5) %% 37 >= 20)
s5 <- create_strategy(GOLD = ac("etc", "signal", 0.5, 0.3, 0, deliverable = TRUE, signal_buy = "b", signal_sell = "s"),
                      ETF = ac("etf", "bnh", 0.5, 0.1, 30))
run_case("f06_private_sale", d5, s5, list(tax_mode = "person", marginal_tax_rate = 42, start_value = 200000,
         balance_mode = TRUE, balance_unit = "month", balance_span = 2))
run_case("f07_funds_liq", d1[1:1500, ], s2, list(tax_mode = "funds", liquidate = TRUE, balance_mode = TRUE))
run_case("f08_funds_1231", d1[1:(365*2+1), ], s2, list(tax_mode = "funds", liquidate = TRUE, funds_fee = 1.2, bonus_fee = 10))
wd <- d1[!(as.integer(format(d1$date, "%u")) %in% c(6, 7)), ]
run_case("f09_gaps", wd, s2, list(tax_mode = "person", dca_mode = TRUE, dca_value = 300, dca_span = 1, dca_unit = "month",
         dca_days = 1, balance_mode = TRUE, balance_unit = "quarter", balance_span = 1, balance_days = 1,
         liquidate = TRUE, base_rate = 2.29, risk_free = 3))
set.seed(9)
n9 <- 1500
d9 <- data.frame(date = mk_dates("2016-06-15", n9), LETF = gbm(n9, 100, 8e-4, 0.03), SAFE = gbm(n9, 20, 1e-4, 0.002))
s9 <- create_strategy(LETF = ac("etf", "bnh", 0.5, 0.2, 30), SAFE = ac("etf", "bnh", 0.5, 0.05, 0))
run_case("f10_splits_frac", d9, s9, list(split_mode = TRUE, split_thresh = c(20, 400), tax_mode = "person",
         balance_mode = TRUE, balance_unit = "year"))
run_case("f11_splits_int", d9, s9, list(split_mode = TRUE, split_thresh = c(20, 400), fractions = FALSE,
         tax_mode = "person", start_value = 100000, balance_mode = TRUE, balance_unit = "month", balance_span = 3))
d10 <- d9; d10$target_leverage <- 2 + 0.5 * sin(seq(0, 12 * pi, length.out = n9))
d10$sigma_ewma <- 0.01 + 0.005 * abs(sin(seq(0, 40, length.out = n9)))
d10 <- compute_rebal_trigger(d10, "combined", triggers = list(list(type = "abs_leverage", threshold = 15),
                                                             list(type = "vol_band", threshold = 25)))
d10$w1 <- d10$target_leverage / 3; d10$w2 <- 1 - d10$w1
run_case("f12_event_add", d10, s9, list(event_col = "rebal_trigger", balance_mode = TRUE, tax_mode = "person"))
run_case("f13_event_repl_w", d10, s9, list(event_col = "rebal_trigger", event_mode = "replace",
         event_weight = list(LETF = "w1", SAFE = "w2"), tax_mode = "person", liquidate = TRUE))
s14 <- create_strategy(WORLD = ac("etf", "bnh", 0.5, 0.1, 30), BONDS = ac("etf", "bnh", 0.3, 0.1, 0, asset_start = "2016-07-15"),
                       GOLD = ac("etc", "bnh", 0.2, 0.2, 0, asset_start = "2017-02-01"))
d14 <- d1; d14$GOLD <- gbm(n, 30, 2e-4, 0.009)
run_case("f14_staggered", d14, s14, list(balance_mode = TRUE, balance_unit = "year", tax_mode = "person", dca_mode = TRUE,
         dca_value = 500, dca_span = 1, dca_unit = "quarter", liquidate = TRUE))
run_case("f15_thresh", d1, s2, list(balance_mode = TRUE, balance_unit = "month", balance_thresh = 3, tax_mode = "person"))
run_case("f16_guenstiger", d1, s2, list(tax_mode = "person", use_guenstigerpruefung = TRUE, marginal_tax_rate = 18,
         include_soli_on_income_tax = TRUE, balance_mode = TRUE, liquidate = TRUE))
run_case("f17_dca_days_end", d1, s2, list(dca_mode = TRUE, dca_value = 100, dca_span = 2, dca_unit = "month",
         dca_days = c(5, 20), dca_anchor = "end", dca_start = as.Date("2015-03-17"), dca_skip = TRUE, tax_mode = "person"))
run_case("f18_one_day", d1[1, ], s1, list())
run_case("f19_two_days", d1[1:2, ], s2, list(tax_mode = "person", liquidate = TRUE))
set.seed(19)
d19 <- data.frame(date = mk_dates("2018-01-01", 1200), A = gbm(1200, 100, -6e-4, 0.02), B = gbm(1200, 100, 5e-4, 0.015))
run_case("f20_losses", d19, create_strategy(A = ac("certificate", "bnh", 0.5, 0.1), B = ac("etf", "bnh", 0.5, 0.1, 30)),
         list(tax_mode = "person", balance_mode = TRUE, balance_unit = "month", base_rate = 1.5, liquidate = TRUE))
d1r <- d1; d1r$sofr <- 2 + sin(seq_len(n) / 50)
run_case("f21_rf_col", d1r, s2, list(risk_free = "sofr", balance_mode = TRUE, dca_mode = TRUE, dca_value = 50, dca_span = 1))
run_case("f22_no_spb", d1, s2, list(tax_mode = "person", use_sparer_pauschbetrag = FALSE, base_rate = 3, liquidate = TRUE))
legacy <- list(ETF = list(asset_class = "etf", action_type = "bnh", asset_share = 1, asset_spread = 0.1, asset_bonus = 0))
run_case("f23_legacy_list", d1[, c("date", "WORLD")], list(WORLD = legacy$ETF), list(tax_mode = "person", liquidate = TRUE))

# ── Zufallsszenarien ─────────────────────────────────────────────────────────
pick <- function(x) x[[sample.int(length(x), 1)]]
for (k in seq_len(n_random)) {
  set.seed(seed0 + k)
  n <- pick(c(40, 200, 400, 800, 1100, 1700))
  start <- as.Date("2012-01-01") + sample(0:2000, 1)
  na <- pick(1:3)
  nms <- c("A", "B", "C")[1:na]
  df <- data.frame(date = mk_dates(start, n))
  for (nm in nms) df[[nm]] <- gbm(n, runif(1, 10, 300), rnorm(1, 3e-4, 4e-4), runif(1, 0.003, 0.03),
                                  lev = pick(c(1, 1, 2, 3)))
  sh <- if (na == 1) 1 else { w <- round(runif(na), 2) + 0.05; w <- w / sum(w); w[na] <- 1 - sum(w[-na]); w }
  use_sig <- runif(1) < 0.35
  if (use_sig) { df$sb <- runif(n) < 0.3; df$ss <- runif(n) < 0.3 }
  cls <- c("etf", "etf", "certificate", "etc", "etn")
  st <- list()
  for (i in seq_along(nms)) {
    cl <- pick(cls)
    sig <- use_sig && i == 1
    st[[nms[i]]] <- ac(cl, if (sig) "signal" else "bnh", sh[i], pick(c(0, 0.05, 0.1, 0.3)),
                       if (cl == "etf") pick(c(0, 15, 30)) else 0,
                       deliverable = (cl %in% c("etc", "etn")) && runif(1) < 0.5,
                       asset_start = if (i > 1 && runif(1) < 0.25) format(start + sample(1:max(2, n %/% 2), 1)) else NULL,
                       signal_buy = if (sig) "sb" else NULL, signal_sell = if (sig) "ss" else NULL)
  }
  st <- create_strategy(assets = st)
  if (runif(1) < 0.3) df <- df[sort(c(1, n, sample(2:(n - 1), floor((n - 2) * 0.7)))), ]
  a <- list(start_value = pick(c(1000, 10000, 123456.78)))
  tm <- pick(c("none", "person", "person", "funds"))
  a$tax_mode <- tm
  if (runif(1) < 0.5) a$liquidate <- TRUE
  if (runif(1) < 0.5) { a$dca_mode <- TRUE; a$dca_value <- pick(c(50, 250, 1000)); a$dca_span <- pick(1:3)
    a$dca_unit <- pick(c("month", "quarter", "year")); if (runif(1) < 0.4) a$dca_days <- pick(list(1, 15, c(1, 28), 31))
    if (runif(1) < 0.3) a$dca_anchor <- "end"; if (runif(1) < 0.3) a$balance_dca <- TRUE; if (runif(1) < 0.2) a$dca_skip <- TRUE }
  if (runif(1) < 0.6) { a$balance_mode <- TRUE; a$balance_unit <- pick(c("month", "quarter", "year")); a$balance_span <- pick(1:2)
    if (runif(1) < 0.4) a$balance_thresh <- pick(c(1, 5, 10)); if (runif(1) < 0.3) a$balance_days <- pick(list(1, 10, 31))
    if (runif(1) < 0.2) a$balance_anchor <- "end"; if (runif(1) < 0.2) a$balance_skip <- TRUE }
  if (tm == "person") { if (runif(1) < 0.5) a$base_rate <- pick(c(-0.5, 1, 2.55, 4))
    if (runif(1) < 0.5) a$marginal_tax_rate <- pick(c(14, 24, 42)); if (runif(1) < 0.2) a$use_guenstigerpruefung <- TRUE
    if (runif(1) < 0.2) a$include_soli_on_income_tax <- TRUE; if (runif(1) < 0.2) a$sparer_pauschbetrag <- pick(c(0, 801, 2000))
    if (runif(1) < 0.1) a$use_sparer_pauschbetrag <- FALSE; if (runif(1) < 0.2) a$private_sale_threshold <- pick(c(0, 600)) }
  if (tm == "funds" && runif(1) < 0.5) { a$funds_fee <- pick(c(0, 0.5, 2)); a$bonus_fee <- pick(c(0, 10, 20)) }
  if (runif(1) < 0.3) a$fractions <- FALSE
  if (runif(1) < 0.4) a$risk_free <- pick(c(0, 1.5, 4))
  if (runif(1) < 0.25) { a$split_mode <- TRUE; a$split_thresh <- pick(list(c(20, 400), c(5, 250), c(40, 150))) }
  if (runif(1) < 0.25) { df$tl <- 2 + sin(seq_len(nrow(df)) / pick(c(10, 30))); df$ev <- runif(nrow(df)) < 0.05
    a$event_col <- "ev"; a$event_mode <- pick(c("additional", "replace")); a$balance_mode <- isTRUE(a$balance_mode) }
  run_case(sprintf("r%03d", k), df, st, a)
}

# ── Zusatzfaelle (Randpfade + Detailausgabe) ─────────────────────────────────
set.seed(24)
d24 <- data.frame(date = seq.Date(as.Date("2018-02-01"), as.Date("2021-12-31"), by = "day"))
d24$WORLD <- gbm(nrow(d24), 100, 6e-4, 0.01); d24$BONDS <- gbm(nrow(d24), 50, 1e-4, 0.003)
run_case("f24_vp_lastday", d24, s2, list(details = TRUE, tax_mode = "person", base_rate = 2.55, balance_mode = TRUE, start_value = 400000))
run_case("f25_vp_partialcash", d24, s2, list(details = TRUE, tax_mode = "person", base_rate = 4, fractions = FALSE,
         start_value = 600000, use_sparer_pauschbetrag = FALSE))
run_case("f26_details_full", d1[1:900, ], s2, list(details = TRUE, tax_mode = "person", base_rate = 2.55, balance_mode = TRUE, start_value = 250000,
         balance_unit = "quarter", balance_thresh = 2, dca_mode = TRUE, dca_value = 200, dca_span = 1, liquidate = TRUE))
run_case("f27_details_sig_ps", d5, s5, list(details = TRUE, tax_mode = "person", marginal_tax_rate = 30, start_value = 50000,
         balance_mode = TRUE, balance_unit = "month", balance_span = 3, include_soli_on_income_tax = TRUE))
run_case("f28_details_split_funds", d9[1:800, ], s9, list(details = TRUE, split_mode = TRUE, split_thresh = c(20, 400),
         tax_mode = "funds", liquidate = TRUE, fractions = FALSE, start_value = 50000))
run_case("f29_details_guenst", d1[1:800, ], s2, list(details = TRUE, tax_mode = "person", use_guenstigerpruefung = TRUE,
         marginal_tax_rate = 20, liquidate = TRUE))
run_case("f30_details_guenst_no", d1[1:400, ], s2, list(details = TRUE, tax_mode = "person", use_guenstigerpruefung = TRUE,
         marginal_tax_rate = 35))
run_case("f31_three_days", d1[1:3, ], s2, list(tax_mode = "person"))
wd2 <- d14[!(as.integer(format(d14$date, "%u")) %in% c(6, 7)), ]
s31 <- create_strategy(WORLD = ac("etf", "bnh", 0.5, 0.1, 30), BONDS = ac("etf", "bnh", 0.3, 0.1, 0, asset_start = "2016-07-16"),
                       GOLD = ac("etc", "bnh", 0.2, 0.2, 0, asset_start = "2017-04-30"))
run_case("f32_start_on_gap", wd2, s31, list(details = TRUE, balance_mode = TRUE, tax_mode = "person", liquidate = TRUE))
run_case("f33_event_w_missing", d10, s9, list(event_col = "rebal_trigger", event_weight = list(LETF = "w1"),
         balance_mode = TRUE))
run_case("f34_details_event", d10[1:700, ], s9, list(details = TRUE, event_col = "rebal_trigger", event_mode = "replace",
         event_weight = list(LETF = "w1", SAFE = "w2"), tax_mode = "person", base_rate = 1))

run_case("f35_details_losses", d19, create_strategy(A = ac("certificate", "bnh", 0.5, 0.1), B = ac("etf", "bnh", 0.5, 0.1, 30)),
         list(details = TRUE, tax_mode = "person", balance_mode = TRUE, balance_unit = "month", base_rate = 1.5, liquidate = TRUE))
set.seed(36)
d36 <- data.frame(date = mk_dates("2019-06-01", 1100)); d36$GOLD <- gbm(1100, 50, 3e-4, 0.012); d36$ETF <- gbm(1100, 70, 2e-4, 0.01)
s36 <- create_strategy(GOLD = ac("etc", "bnh", 0.4, 0.2, 0, deliverable = TRUE), ETF = ac("etf", "bnh", 0.6, 0.1, 30))
run_case("f36_details_ps_long", d36, s36, list(details = TRUE, tax_mode = "person", marginal_tax_rate = 35, dca_mode = TRUE,
         dca_value = 400, dca_span = 1, dca_days = 29, balance_mode = TRUE, balance_unit = "month", start_value = 30000,
         private_sale_threshold = 600, liquidate = TRUE))
run_case("f37_leapday_lots", d36, s36, list(tax_mode = "person", marginal_tax_rate = 42, dca_mode = TRUE, dca_value = 1000,
         dca_span = 1, dca_days = 29, balance_mode = TRUE, balance_unit = "month", start_value = 100000))
d38 <- d1c; d38$buy <- as.numeric(d38$buy); d38$sell <- as.numeric(d38$sell)
run_case("f38_numeric_signals", d38, s_sig, list(tax_mode = "person", balance_mode = TRUE, balance_unit = "quarter",
         balance_span = 1, liquidate = TRUE))
cat("fertig\n")
