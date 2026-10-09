# Eigene Stressfaelle ausserhalb des Parameterraums von golden_cases.R.
# Aufruf: Rscript stress_cases.R <outdir> <n_random> <seed>
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
enc_strategy <- function(s) lapply(s, function(a) {
  a <- unclass(a)
  if (!is.null(a$asset_start)) a$asset_start <- format(as.Date(a$asset_start))
  for (k in c("asset_share", "asset_spread", "asset_bonus")) if (!is.null(a[[k]])) a[[k]] <- list(hex = hx(a[[k]]))
  a
})
enc_result <- function(r) list(
  worth = hx(r$worth), drawdowns = hx(r$drawdowns), filled = r$filled,
  cagr = hx(r$cagr), ttwror = hx(r$ttwror), statistics = lapply(r$statistics, hx),
  buys = lapply(as.list(r$buys), hx), sells = lapply(as.list(r$sells), hx),
  tax_report = lapply(r$tax_report, hx), report = lapply(r$report, function(a) lapply(a, hx)),
  print = paste(capture.output(print(r)), collapse = "\n"))
run_case <- function(id, data, strategy, sargs) {
  stdout_txt <- NULL
  res <- tryCatch(suppressWarnings(suppressMessages({
    stdout_txt <- capture.output(r <- do.call(simulation, c(list(data = data, strategy = strategy), sargs))); r })),
    error = function(e) e)
  out <- list(id = id, data = enc_data(data), strategy = enc_strategy(strategy),
              args = lapply(sargs, function(v) if (inherits(v, "Date")) format(v) else v))
  if (inherits(res, "error")) out$error <- conditionMessage(res) else out$result <- enc_result(res)
  if (isTRUE(sargs$details)) out$stdout <- paste(stdout_txt, collapse = "\n")
  writeLines(toJSON(out, digits = NA, auto_unbox = TRUE, null = "null", na = "null"), file.path(outdir, sprintf("%s.json", id)))
}
mk_dates <- function(start, n) seq.Date(as.Date(start), by = "day", length.out = n)
gbm <- function(n, s0, mu, sig, lev = 1) s0 * cumprod(pmax(1e-4, 1 + lev * rnorm(n, mu, sig)))
pick <- function(x) x[[sample.int(length(x), 1)]]
ac <- function(...) asset_config(...)

# ── Gezielte Randfaelle ──────────────────────────────────────────────────────
set.seed(4242)
n30 <- 365 * 30
d30 <- data.frame(date = mk_dates("1995-01-01", n30), W = gbm(n30, 100, 3e-4, 0.011), B = gbm(n30, 50, 1e-4, 0.003),
                  L = gbm(n30, 100, 3e-4, 0.011, lev = 3))
s30 <- create_strategy(W = ac("etf", "bnh", 0.5, 0.1, 30), B = ac("etf", "bnh", 0.3, 0.05, 0), L = ac("etn", "bnh", 0.2, 0.3, 0))
run_case("x01_30y_dca_rebal_tax", d30, s30, list(start_value = 25000, dca_mode = TRUE, dca_value = 500, dca_span = 1,
         dca_unit = "month", balance_mode = TRUE, balance_unit = "year", tax_mode = "person", base_rate = 2.55, liquidate = TRUE))
run_case("x02_30y_funds_split_int", d30, s30, list(start_value = 1e6, tax_mode = "funds", split_mode = TRUE,
         split_thresh = c(10, 500), fractions = FALSE, balance_mode = TRUE, balance_unit = "quarter", balance_thresh = 2))
run_case("x03_30y_details", d30[1:(365*8), ], s30, list(details = TRUE, start_value = 80000, tax_mode = "person",
         marginal_tax_rate = 45, use_guenstigerpruefung = TRUE, balance_mode = TRUE, balance_unit = "month", base_rate = 1.2))
# Totalverlust-nahe Hebelreihe (Kurs faellt auf ~1e-4 * Start)
dc <- data.frame(date = mk_dates("2020-02-29", 1500))
dc$L <- 100 * cumprod(c(rep(0.985, 600), rep(1.004, 900))); dc$S <- gbm(1500, 20, 1e-4, 0.002)
sc <- create_strategy(L = ac("etf", "bnh", 0.7, 0.5, 30), S = ac("etf", "bnh", 0.3, 0.05, 0))
run_case("x04_crash_reverse_splits", dc, sc, list(split_mode = TRUE, split_thresh = c(5, 250), tax_mode = "person",
         balance_mode = TRUE, balance_unit = "month", liquidate = TRUE))
run_case("x05_crash_int_shares", dc, sc, list(fractions = FALSE, start_value = 500, tax_mode = "person", dca_mode = TRUE,
         dca_value = 37.5, dca_span = 1, balance_mode = TRUE, balance_dca = TRUE))
# Konstante Preise (Volatilitaet 0)
dk <- data.frame(date = mk_dates("2021-01-01", 800), K = rep(42, 800), M = rep(7.5, 800))
run_case("x06_const_prices", dk, create_strategy(K = ac("etf", "bnh", 0.5, 0, 30), M = ac("certificate", "bnh", 0.5, 0)),
         list(tax_mode = "person", balance_mode = TRUE, risk_free = 3, liquidate = TRUE))
run_case("x07_const_no_spread_rf0", dk, create_strategy(K = ac("etf", "bnh", 1, 0, 0)), list())
# Signal nie aktiv / immer aktiv, mehrere Signal-Assets
set.seed(77)
ds <- data.frame(date = mk_dates("2016-12-31", 1300), A = gbm(1300, 30, 3e-4, 0.02), B = gbm(1300, 60, 2e-4, 0.015), C = gbm(1300, 10, 1e-4, 0.01))
ds$f <- FALSE; ds$t <- TRUE; ds$b1 <- runif(1300) < 0.1; ds$s1 <- runif(1300) < 0.1; ds$b2 <- runif(1300) < 0.5; ds$s2 <- runif(1300) < 0.05
run_case("x08_signal_never", ds, create_strategy(A = ac("etf", "signal", 1, 0.1, 30, signal_buy = "f", signal_sell = "f")),
         list(tax_mode = "person"))
run_case("x09_signal_both_true", ds, create_strategy(A = ac("etf", "signal", 1, 0.1, 30, signal_buy = "t", signal_sell = "t")),
         list(tax_mode = "person", liquidate = TRUE))
s_multi <- create_strategy(A = ac("etc", "signal", 0.4, 0.2, 0, deliverable = TRUE, signal_buy = "b1", signal_sell = "s1"),
                           B = ac("etn", "signal", 0.4, 0.3, 0, signal_buy = "b2", signal_sell = "s2"),
                           C = ac("etf", "bnh", 0.2, 0.1, 15))
run_case("x10_multi_signal", ds, s_multi, list(tax_mode = "person", marginal_tax_rate = 42, balance_mode = TRUE,
         balance_unit = "month", dca_mode = TRUE, dca_value = 300, dca_span = 1, liquidate = TRUE))
run_case("x11_multi_signal_details", ds, s_multi, list(details = TRUE, tax_mode = "person", marginal_tax_rate = 14,
         use_guenstigerpruefung = TRUE, include_soli_on_income_tax = TRUE, private_sale_threshold = 0, start_value = 77777.77))
# Extremwerte bei Parametern
run_case("x12_huge_start", d30[1:3000, ], s30, list(start_value = 1e10, tax_mode = "person", balance_mode = TRUE, liquidate = TRUE))
run_case("x13_tiny_start", d30[1:3000, ], s30, list(start_value = 0.01, tax_mode = "person", balance_mode = TRUE, liquidate = TRUE))
run_case("x14_tax0_bonus60", d30[1:3000, ], create_strategy(W = ac("etf", "bnh", 1, 2.5, 60)),
         list(tax_rate = 0, tax_mode = "person", base_rate = 6))
run_case("x15_taxrate_odd", d30[1:3000, ], s30, list(tax_rate = 27.99, tax_mode = "person", sparer_pauschbetrag = 1,
         base_rate = 0.01, dca_mode = TRUE, dca_value = 0.01, dca_span = 1))
run_case("x16_funds_fee_high", d30[1:2000, ], s30, list(tax_mode = "funds", funds_fee = 9.99, bonus_fee = 99, liquidate = TRUE))
# Kalender-Randfaelle
dl <- data.frame(date = seq.Date(as.Date("2015-12-31"), as.Date("2024-03-01"), by = "day"))
set.seed(5); dl$X <- gbm(nrow(dl), 80, 3e-4, 0.01); dl$Y <- gbm(nrow(dl), 40, 1e-4, 0.004)
sl <- create_strategy(X = ac("etf", "bnh", 0.6, 0.1, 30), Y = ac("etc", "bnh", 0.4, 0.1, 0, deliverable = TRUE, asset_start = "2016-02-29"))
for (dd in list(29, 30, 31, c(1, 15, 31))) for (anc in c("start", "end"))
  run_case(sprintf("x17_cal_%s_%s", paste(dd, collapse = "-"), anc), dl, sl,
           list(dca_mode = TRUE, dca_value = 250, dca_span = 1, dca_unit = "month", dca_days = dd, dca_anchor = anc,
                balance_mode = TRUE, balance_unit = "quarter", balance_days = dd, balance_anchor = anc, tax_mode = "person",
                marginal_tax_rate = 30, liquidate = TRUE))
run_case("x18_year_span3", dl, sl, list(dca_mode = TRUE, dca_value = 5000, dca_span = 3, dca_unit = "year", balance_mode = TRUE,
         balance_unit = "year", balance_span = 2, balance_skip = TRUE, dca_skip = TRUE, tax_mode = "person"))
run_case("x19_balance_start", dl, sl, list(balance_mode = TRUE, balance_start = as.Date("2019-02-28"), balance_unit = "month",
         dca_mode = TRUE, dca_start = as.Date("2020-02-29"), dca_value = 100, dca_span = 1, tax_mode = "person"))
# Basiszins-Spalte mit vielen Wechseln, risk_free-Spalte negativ
dbr <- d30[1:(365*12), ]; dbr$br <- rep(c(-0.5, 0, 0.87, 1.0, 2.55, 3.2, -0.05, 0.1, 4, 2.29, 1.5, 0.3), each = 365)
dbr$rf <- -0.5 + seq_len(nrow(dbr)) / 2000
run_case("x20_brflex_rfcol", dbr, s30, list(tax_mode = "person", base_rate_flex = TRUE, base_rate_data = "br", risk_free = "rf",
         balance_mode = TRUE, balance_unit = "year", dca_mode = TRUE, dca_value = 100, dca_span = 1, liquidate = TRUE))
# Fehlerpfade: beide Seiten sollen gleich reagieren
run_case("x21_err_missing_col", dk, create_strategy(Z = ac("etf", "bnh", 1, 0, 0)), list())
dna <- dk; dna$K[100:110] <- NA
run_case("x22_na_prices", dna, create_strategy(K = ac("etf", "bnh", 1, 0.1, 30)), list(tax_mode = "person"))
run_case("x23_unsorted", dk[c(2, 1, 3:800), ], create_strategy(K = ac("etf", "bnh", 1, 0.1, 30)), list())
run_case("x24_dup_dates", dk[c(1, 1, 2:800), ], create_strategy(K = ac("etf", "bnh", 1, 0.1, 30)), list())

# ── Breitere Zufallsfaelle ───────────────────────────────────────────────────
for (k in seq_len(n_random)) {
  set.seed(seed0 + k)
  n <- pick(c(2, 5, 31, 366, 1000, 2500, 4000, 7300))
  start <- as.Date("2000-01-01") + sample(0:9000, 1)
  na <- pick(1:4); nms <- c("A", "B", "C", "D")[1:na]
  df <- data.frame(date = mk_dates(start, n))
  for (nm in nms) df[[nm]] <- gbm(n, exp(runif(1, log(0.5), log(5000))), rnorm(1, 2e-4, 8e-4), runif(1, 0.001, 0.05),
                                  lev = pick(c(1, 2, 3, -1)))
  sh <- if (na == 1) 1 else { w <- runif(na) + 0.01; w <- w / sum(w); w[na] <- 1 - sum(w[-na]); w }
  st <- list()
  for (i in seq_along(nms)) {
    cl <- pick(c("etf", "certificate", "etc", "etn"))
    sig <- runif(1) < 0.3
    if (sig) { df[[paste0("b", i)]] <- runif(n) < runif(1, 0.01, 0.6); df[[paste0("s", i)]] <- runif(n) < runif(1, 0.01, 0.6) }
    st[[nms[i]]] <- ac(cl, if (sig) "signal" else "bnh", sh[i], pick(c(0, 0.01, 0.2, 1, 3)),
                       if (cl == "etf") pick(c(0, 15, 30, 60, 80)) else 0,
                       deliverable = (cl %in% c("etc", "etn")) && runif(1) < 0.5,
                       asset_start = if (i > 1 && n > 10 && runif(1) < 0.3) format(start + sample(1:(n - 2), 1)) else NULL,
                       signal_buy = if (sig) paste0("b", i) else NULL, signal_sell = if (sig) paste0("s", i) else NULL)
  }
  st <- create_strategy(assets = st)
  if (n > 10 && runif(1) < 0.3) df <- df[sort(c(1, n, sample(2:(n - 1), floor((n - 2) * runif(1, 0.3, 0.9))))), ]
  a <- list(start_value = pick(c(1, 999.99, 10000, 2.5e5, 3e7)))
  tm <- pick(c("none", "person", "person", "funds")); a$tax_mode <- tm
  if (runif(1) < 0.3) a$tax_rate <- pick(c(0, 25, 26.375, 28))
  if (runif(1) < 0.5) a$liquidate <- TRUE
  if (runif(1) < 0.5) { a$dca_mode <- TRUE; a$dca_value <- pick(c(0.5, 75, 1500, 20000)); a$dca_span <- pick(1:4)
    a$dca_unit <- pick(c("month", "quarter", "year")); if (runif(1) < 0.5) a$dca_days <- pick(list(1, 28, 29, 30, 31, c(10, 20), c(1, 31)))
    if (runif(1) < 0.4) a$dca_anchor <- "end"; if (runif(1) < 0.3) a$balance_dca <- TRUE; if (runif(1) < 0.3) a$dca_skip <- TRUE
    if (runif(1) < 0.2) a$dca_start <- start + sample(0:max(1, n), 1) }
  if (runif(1) < 0.6) { a$balance_mode <- TRUE; a$balance_unit <- pick(c("month", "quarter", "year")); a$balance_span <- pick(1:4)
    if (runif(1) < 0.4) a$balance_thresh <- pick(c(0.5, 2, 7, 20)); if (runif(1) < 0.4) a$balance_days <- pick(list(1, 15, 29, 31, c(5, 25)))
    if (runif(1) < 0.3) a$balance_anchor <- "end"; if (runif(1) < 0.3) a$balance_skip <- TRUE
    if (runif(1) < 0.2) a$balance_start <- start + sample(0:max(1, n), 1) }
  if (tm == "person") { if (runif(1) < 0.6) a$base_rate <- pick(c(-0.75, 0, 0.5, 2.29, 2.55, 5))
    if (runif(1) < 0.6) a$marginal_tax_rate <- pick(c(0, 10, 14, 24, 35, 42, 45, 50)); if (runif(1) < 0.3) a$use_guenstigerpruefung <- TRUE
    if (runif(1) < 0.3) a$include_soli_on_income_tax <- TRUE; if (runif(1) < 0.2) a$soli_rate_income_tax <- pick(c(0, 3, 5.5))
    if (runif(1) < 0.3) a$sparer_pauschbetrag <- pick(c(0, 1, 801, 1000, 5000))
    if (runif(1) < 0.15) a$use_sparer_pauschbetrag <- FALSE; if (runif(1) < 0.3) a$private_sale_threshold <- pick(c(0, 1, 600, 1000, 1e6))
    if (runif(1) < 0.2 && nrow(df) > 0) { df$brc <- round(runif(1, -1, 4), 2) + floor(seq_len(nrow(df)) / 365) * 0.25
      a$base_rate_flex <- TRUE; a$base_rate_data <- "brc" } }
  if (tm == "funds" && runif(1) < 0.6) { a$funds_fee <- pick(c(0, 0.07, 1.5, 4)); a$bonus_fee <- pick(c(0, 5, 25, 50)) }
  if (runif(1) < 0.35) a$fractions <- FALSE
  if (runif(1) < 0.4) a$risk_free <- pick(c(0, -0.5, 2, 8))
  if (runif(1) < 0.3) { a$split_mode <- TRUE; a$split_thresh <- pick(list(c(20, 400), c(1, 1000), c(50, 120), c(0.5, 60))) }
  if (runif(1) < 0.3 && nrow(df) > 3) { df$ev <- runif(nrow(df)) < pick(c(0.01, 0.1, 0.5)); a$event_col <- "ev"
    a$event_mode <- pick(c("additional", "replace")); if (runif(1) < 0.5) a$balance_mode <- TRUE
    if (runif(1) < 0.4) { for (i in seq_along(nms)) df[[paste0("w", i)]] <- runif(nrow(df)); a$event_weight <- setNames(as.list(paste0("w", seq_along(nms))), nms) } }
  if (runif(1) < 0.1) a$details <- TRUE
  run_case(sprintf("y%04d", k), df, st, a)
}
cat("fertig\n")
