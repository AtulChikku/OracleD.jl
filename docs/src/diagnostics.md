# Diagnostics

The package ships a **whole-port performance diagnostic suite**,
`OracleD.jl/diagnostics_new.jl`. It is an independent script (a superset of
the older `diagnostics.jl`) that scans the *entire* port for type
instabilities, inference failures, allocation hot-spots and performance
regressions, rather than only a handful of hand-picked functions.

It is self-contained: it activates the package environment, installs any
missing diagnostic dependencies, runs the requested scans and writes
colour-coded reports to `OracleD.jl/diagnostics/runs/run_<timestamp>/`.

## What it scans

The suite performs up to four whole-port scans:

1. **Struct definition scan** *(source level, Scan A)* — parses every
   `src/*.jl` file, lists every type and flags fields that are untyped
   (therefore `Any`), `::Any`, abstract (`Number`, `Real`, `Function`, ...)
   or `Union{...}`, with the exact `file:line`. This is where most
   instability hides: an untyped field may be invisible to per-function
   `@code_warntype` because it is simply never read in the analysed methods.
2. **Reflected type audit** *(runtime `fieldtype`s, Scan B)* — walks the
   whole `OracleD` module tree, reads each struct's real field types and
   counts `Any` / abstract / `Union` fields, together with padding and
   pointer-free layout information.
3. **Whole-port JET scan** *(Scan C)* — runs `JET.report_file` on
   `src/OracleD.jl` (the whole include tree), reporting method errors and
   type infringements across **all** code, not just the selective wrappers.
4. **Selective deep-dive** *(Scan D)* — `@report_call`, `@report_opt` and
   colourised `@code_warntype` on the hot-path functions
   (`Cluster.update!`, `WorkerNode.update!`, `JobScheduler.update!`, the
   `Simulation` constructor, job creation and inventory loading).

## Phases

- **Phase 0** — setup and automatic variant detection (distinguishes the
  `OracleD` port layout from older ones) and dependency management
  (`BenchmarkTools`, `JET`, `Cthulhu`, `FlameGraphs`, `FileIO`,
  `OrderedCollections`).
- **Phase 1** — whole-port type stability (Scans A–D) plus a summary.
- **Phase 2** — profiling with `Profile` and flamegraph/flat text output of
  the hottest lines.
- **Phase 3** — `BenchmarkTools` benchmarks of the simulation constructor,
  single-timestep cluster/node updates, job creation and a full short
  simulation.
- **Phase 4** — summary of the run and of the output files.

## Usage

Run everything from the `OracleD.jl/` package directory:

```sh
julia --project diagnostics_new.jl                    # all phases
julia --project diagnostics_new.jl --phase1           # type stability only
julia --project diagnostics_new.jl --structsonly      # struct scans only (fast)
julia --project diagnostics_new.jl --phase1 --phase2 --nojetscan  # skip the whole-port JET scan
julia --project diagnostics_new.jl --phase3           # benchmarking only
```

### Command-line flags

| Flag          | Effect                                              |
| :------------ | :-------------------------------------------------- |
| `--phase1`    | Run only phase 1 (type stability & struct scan).    |
| `--phase2`    | Run only phase 2 (profiling / flamegraphs).         |
| `--phase3`    | Run only phase 3 (benchmarking).                    |
| `--structsonly` | Run the two struct scans only (fast).             |
| `--nojetscan` | Skip the whole-port `JET.report_file` scan.         |

With no flags all phases run.

## Output

Each run writes into a new folder
`OracleD.jl/diagnostics/runs/run_<YYYY-mm-dd_HH-MM-SS>/`:

| File                    | Contents                                              |
| :---------------------- | :---------------------------------------------------- |
| `type_stability.log`    | Scans A–D plus the final summary (colour-coded).      |
| `struct_scan.log`       | Source-level listing of non-concretely-typed fields.  |
| `profile_tree.txt`      | `Profile` tree output (top sampled frames).           |
| `flamegraph_flat.txt`   | Flat string profile, sorted by count.                 |
| `benchmarks.txt`        | Benchmark report (min / mean / max, allocations).     |

Aggregate outputs also live in `OracleD.jl/diagnostics/runs/`
(`summary.txt`, `summary.json`, `parameters.txt`).

### Colour legend

- **red** — definite instability (`Any` / untyped / abstract field, dynamic
  dispatch, error).
- **yellow** — possible (`Union{...}`).
- **green** — no issue.
- **magenta / bold** — markers.

View the logs with `cat` or `less -R` to see the colours.

## Notes

- The suite is a developer tool, not part of the simulation itself; it is
  not run by `Pkg.test()`.
- Whole-port JET (`Scan C`) and `--phase3` benchmarks can take a minute or
  more on first run (compilation).
- Run-to-run benchmark numbers depend on the machine; compare relative
  changes rather than absolute values.
