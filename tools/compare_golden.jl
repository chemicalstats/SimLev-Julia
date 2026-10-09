# Vergleicht die Julia-Engine bitgenau mit Golden-Master-Ergebnissen aus R.
#
# Aufruf:  julia --project=. tools/compare_golden.jl <golden_dir> [case_id ...]
#          julia --project=. tools/compare_golden.jl --lax <golden_dir>   (NA und NaN gleich behandeln)

using SimLev
include(joinpath(@__DIR__, "..", "test", "golden_tools.jl"))

function main(args)
    strict = !("--lax" in args)
    args = filter(!=("--lax"), args)
    gdir = args[1]
    ids = args[2:end]
    files = sort(filter(f -> endswith(f, ".json") || endswith(f, ".json.gz"), readdir(gdir)))
    if !isempty(ids)
        files = [f for f in files if replace(f, r"\.json(\.gz)?$" => "") in ids]
    end
    n_ok = 0
    failed = String[]
    t0 = time()
    for f in files
        errs = run_case(joinpath(gdir, f); strict_na = strict, verbose = !isempty(ids))
        if isempty(errs)
            n_ok += 1
        else
            push!(failed, f)
            println("FAIL ", f)
            for e in errs[1:min(end, 8)]
                println("    ", e)
            end
        end
    end
    println("\n$n_ok/$(length(files)) Fälle bitgleich", strict ? " (strikt: NA ≠ NaN)" : "",
            "  [", round(time() - t0; digits = 1), " s]")
    return isempty(failed) ? 0 : 1
end

exit(main(ARGS))
