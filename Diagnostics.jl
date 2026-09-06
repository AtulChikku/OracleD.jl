#!/usr/bin/env julia
# diagnostics_new.jl — WHOLE-PORT Performance Diagnostics for OracleD (v2.0)
#
# A superset of diagnostics.jl: instead of only analysing a handful of
# hand-picked functions, it scans the entire port for inefficiencies:
#
#   1. STRUCT DEFINITION SCAN (source level)          — parses every src/*.jl
#      file, lists every struct and flags fields that are untyped (=> Any),
#      `::Any`, abstract (`Number`, `Real`, `Function`, ...) or `Union{...}`,
#      with the exact file:line. This is where most instabilities hide (e.g.
#      an untyped `_worker_node_inventory` field is invisible to per-function
#      @code_warntype because it is never read in the analysed methods).
#
#   2. REFLECTED TYPE AUDIT (runtime fieldtypes)      — walks the whole
#      `OracleD` module tree, reads each struct's real `fieldtype`s and counts
#      Any / abstract / Union fields, plus padding/pointer-free layout info.
#
#   3. WHOLE-PORT JET SCAN                            — JET.report_file on
#      src/OracleD.jl (the whole include tree), reporting method errors /
#      `getindex(::Nothing, ...)`-style type infringements across ALL code,
#      not just the selective `_jet_*` wrappers.
#
#   4. SELECTIVE DEEP-DIVE (as before)                — @report_call /
#      @report_opt / @code_warntype on the hot-path functions, colourised.
#
# Usage:
#   cd /path/to/project && julia --project diagnostics_new.jl            # all
#   julia --project diagnostics_new.jl --phase1                          # scan+stability
#   julia --project diagnostics_new.jl --structsonly                     # struct scan only
#   julia --project diagnostics_new.jl --phase1 --phase2 --nojetscan     # skip whole-port JET
#
# Colour legend:  red = definite instability (Any / untyped / abstract field,
#                 dynamic dispatch, error)
#                 yellow = possible (Union{...})
#                 green = no issue
#                 magenta/bold = markers
# View logs with `cat` or `less -R`.

using Printf

# ANSI colours (re-applied because redirecting stdout strips @code_warntype colour)
const AN_RESET   = "\e[0m"
const AN_RED     = "\e[31m"
const AN_GREEN   = "\e[32m"
const AN_YELLOW  = "\e[33m"
const AN_BLUE    = "\e[34m"
const AN_MAGENTA = "\e[35m"
const AN_CYAN    = "\e[36m"
const AN_BOLD    = "\e[1m"

# ---------------------------------------------------------------------------
# Phase 0 — Setup & auto-detection
# ---------------------------------------------------------------------------

function detect_variant()
    if basename(@__DIR__) == "OracleD.jl"
        return :graeme
    elseif isfile(joinpath(@__DIR__, "src", "Main.jl"))
        return :asm
    elseif isfile(joinpath(@__DIR__, "test", "runtests.jl"))
        return :graeme
    end
    cluster_path = joinpath(@__DIR__, "src", "Cluster.jl")
    cpath = isfile(cluster_path) ? cluster_path : joinpath(@__DIR__, "src", "cluster", "Cluster.jl")
    if isfile(cpath)
        for line in readlines(cpath)
            occursin("function update_cluster", line) && return :asm
            occursin("function update!", line) && return :graeme
        end
    end
    @warn "Could not detect OracleD variant; defaulting to :graeme"
    return :graeme
end

const VARIANT = detect_variant()
const PROJECT_ROOT = @__DIR__

using Dates
const TIMESTAMP = Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS")
const RUN_DIR = mkpath(joinpath(PROJECT_ROOT, "diagnostics", "runs", "run_$(TIMESTAMP)"))
mkpath(joinpath(PROJECT_ROOT, "diagnostics", "runs"))

println(join(fill("=", 72)))
println("  OracleD WHOLE-PORT Diagnostic Suite (v2.0)")
println("  Variant: $(uppercase(string(VARIANT)))")
println("  Project: $PROJECT_ROOT")
println("  Run:     $RUN_DIR")
println(join(fill("=", 72)))

# ---------------------------------------------------------------------------
# Dependency management
# ---------------------------------------------------------------------------

function ensure_deps()
    needed = ["BenchmarkTools", "JET", "Cthulhu", "FlameGraphs", "FileIO", "OrderedCollections"]
    available = keys(Pkg.project().dependencies)
    to_add = filter(dep -> !(dep in available), needed)
    if !isempty(to_add)
        println("Adding missing diagnostic dependencies: $(join(to_add, ", "))")
        Pkg.add(to_add)
    end
    for dep in needed
        try
            @eval using $(Symbol(dep))
        catch e
            println("  Warning: could not load $dep — $(typeof(e).name.name)")
        end
    end
end

using Pkg
Pkg.activate(PROJECT_ROOT)
Pkg.instantiate()
ensure_deps()

using Profile
using Serialization
using InteractiveUtils

include(joinpath(PROJECT_ROOT, "src", "OracleD.jl"))
using .OracleD

const RUN_TAG = Dates.format(Dates.now(), "HH-MM-SS")

# ---------------------------------------------------------------------------
# Config helpers (mini simulation for selective deep-dive + warntype)
# ---------------------------------------------------------------------------

function make_mini_config()
    mkpath(joinpath(PROJECT_ROOT, "diagnostics", "runs"))
    return Dict{String,Any}(
        "Simulation" => Dict{String,Any}(
            "desired_starttime" => "2024-01-16 16:00",
            "simulation_length" => 518400,
            "timestep" => 600,
            "savings_policy" => "none",
        ),
        "carbon_intensity" => Dict{String,Any}(
            "folder" => "data/carbon_intensity/",
            "filename" => "de_carbon_Intensity_2024_15min.csv",
            "high_CI_threshold" => 400,
        ),
        "cluster" => Dict{String,Any}(
            "cluster_name" => "DEFAULT",
            "inventory_csv" => "data/cluster/default-machinegroups_inventory.csv",
            "frequency_csv" => "data/cluster/default-frequency_dependence.csv",
            "strict" => false,
        ),
        "jobs" => Dict{String,Any}(
            "initial_mix" => Dict{String,Any}("GridPP" => 50000),
            "regular_incoming_mix" => Dict{String,Any}("GridPP" => 500),
            "incoming_timestep" => 3600,
        ),
        "output" => Dict{String,Any}(
            "verbosity" => "low",
            "debug" => false,
            "log_dir" => "diagnostics/runs",
            "run_dir" => "diagnostics/runs",
            "run_label" => "diag",
        ),
    )
end

function make_mini_inventory()
    inv = OracleD.load_cluster_inventory(
        "data/cluster/default-machinegroups_inventory.csv",
        "data/cluster/default-frequency_dependence.csv";
        cluster_name = "DEFAULT",
        strict = false,
    )
    return [(spec, min(qty, 5)) for (spec, qty) in inv]
end

function build_mini_simulation()
    config = make_mini_config()
    inventory = make_mini_inventory()
    if VARIANT == :graeme
        return OracleD.Simulation(config, inventory)
    else
        return OracleD.Simulation(config, inventory)
    end
end

function run_mini_simulation(sim)
    if VARIANT == :graeme
        OracleD.start!(sim)
    else
        OracleD.start_simulation(sim)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Selective deep-dive wrappers (same as diagnostics.jl)
# ---------------------------------------------------------------------------

if VARIANT == :graeme
    function _jet_cluster_update()
        c = make_mini_config(); inv = make_mini_inventory()
        sim = OracleD.Simulation(c, inv)
        OracleD.update!(sim.cluster)
    end
    function _jet_worker_update()
        c = make_mini_config(); inv = make_mini_inventory()
        sim = OracleD.Simulation(c, inv)
        OracleD.update!(sim.cluster.worker_nodes[1])
    end
    function _jet_scheduler_update()
        c = make_mini_config(); inv = make_mini_inventory()
        sim = OracleD.Simulation(c, inv)
        OracleD.update!(sim.jobScheduler)
    end
    function _jet_sim_constructor()
        OracleD.Simulation(make_mini_config(), make_mini_inventory())
    end
else
    function _jet_cluster_update()
        c = make_mini_config(); inv = make_mini_inventory()
        sim = OracleD.Simulation(c, inv)
        OracleD.update_cluster(sim._cluster)
    end
    function _jet_worker_update()
        c = make_mini_config(); inv = make_mini_inventory()
        sim = OracleD.Simulation(c, inv)
        OracleD.update_node(sim._cluster._worker_nodes[1])
    end
    function _jet_scheduler_update()
        c = make_mini_config(); inv = make_mini_inventory()
        sim = OracleD.Simulation(c, inv)
        OracleD.update_scheduler(sim._jobScheduler)
    end
    function _jet_sim_constructor()
        OracleD.Simulation(make_mini_config(), make_mini_inventory())
    end
end

if VARIANT == :graeme
    _opt_cluster_update(sim) = (OracleD.update!(sim.cluster); nothing)
    _opt_worker_update(sim) = (OracleD.update!(sim.cluster.worker_nodes[1]); nothing)
    _opt_scheduler_update(sim) = (OracleD.update!(sim.jobScheduler); nothing)
else
    _opt_cluster_update(sim) = (OracleD.update_cluster(sim._cluster); nothing)
    _opt_worker_update(sim) = (OracleD.update_node(sim._cluster._worker_nodes[1]); nothing)
    _opt_scheduler_update(sim) = (OracleD.update_scheduler(sim._jobScheduler); nothing)
end

function build_sim()
    c = make_mini_config(); inv = make_mini_inventory()
    return OracleD.Simulation(c, inv)
end

# ---------------------------------------------------------------------------
# Colouriser helpers for @code_warntype output (kept from v1.2)
# ---------------------------------------------------------------------------

function replace_scan(s::AbstractString, re::Regex, f)
    n = 0
    out = replace(s, re => (m -> (n += 1; f(m))))
    return out, n
end

function scan_warntype(text::AbstractString)
    n_any = 0; n_union = 0; n_box = 0
    lines = split(text, '\n')
    io = IOBuffer()
    for line in lines
        (line, n) = replace_scan(line, r"::Core\.Box", _ -> (n_box += 1; AN_RED * "::Core.Box" * AN_RESET))
        (line, n2) = replace_scan(line, r"::ANY\b", _ -> (n_any += 1; AN_RED * "::ANY" * AN_RESET))
        (line, n3) = replace_scan(line, r"::UNION", _ -> (n_union += 1; AN_YELLOW * "::UNION" * AN_RESET))
        line = if n2 + n3 + n > 0
            tags = (n > 0 ? "[BOX]" : "") * (n2 > 0 ? "[ANY]" : "") * (n3 > 0 ? "[UNION]" : "")
            line * "   $(AN_BOLD)$(AN_MAGENTA)<<< $tags$(AN_RESET)"
        else
            line
        end
        println(io, line)
    end
    return String(take!(io)), n_any, n_union, n_box
end

function warntype_verdict(n_any, n_union, n_box)
    definite = n_any + n_box
    if definite == 0 && n_union == 0
        return (AN_GREEN * "[STABLE]      " * AN_RESET *
                "no type instabilities in @code_warntype output")
    elseif definite > 0
        return (AN_RED * "[UNSTABLE]    " * AN_RESET *
                "$definite definite instability(ies): $n_any x Any, $n_box x Core.Box; $n_union x Union{...}")
    else
        return (AN_YELLOW * "[CHECK]       " * AN_RESET *
                "no definite instability, but $n_union Union{...} type(s) (may be benign)")
    end
end

# ---------------------------------------------------------------------------
# WHOLE-PORT SCAN 1 — STRUCT DEFINITION SCAN (source level, file:line)
# ---------------------------------------------------------------------------

# Abstract / non-isbits type names that make a field (and thus its container)
# heap-allocated and a dynamic-dispatch source.
const ABSTRACT_FIELD_TYPES = Set{String}([
    "Any", "Number", "Real", "Integer", "Signed", "Unsigned", "AbstractFloat",
    "AbstractIrrational", "AbstractString", "AbstractChar", "AbstractVector",
    "AbstractMatrix", "AbstractArray", "AbstractDict", "AbstractSet",
    "AbstractRange", "AbstractUnitRange", "Function", "DataType", "Type",
    "Symbol", "AbstractVector{T}", "AbstractArray{T}",
])

# Locate every struct definition in a source file and return
#   (struct_name, is_mutable::Bool, is_abstract::Bool, lineno, fields)
# where each field is (name, ::String or nothing, lineno, type_kind).
function struct_defs_in_file(file::AbstractString)
    txt = read(file, String)
    ex = try
        Meta.parseall(txt)
    catch
        return NamedTuple[]
    end
    defs = NamedTuple[]
    function walk!(e, cur_lineno)
        if e isa Expr
            if (e.head === :struct || e.head === :abstract) && length(e.args) >= 2
                nameexpr = e.args[2]
                body = length(e.args) >= 3 ? e.args[3] : nothing
                body === nothing && (body = Expr(:block))
                fields = Any[]
                ln = cur_lineno
                if body isa Expr && body.head === :block
                    for n in body.args
                        if n isa LineNumberNode
                            ln = n.line
                        elseif n isa Symbol
                            push!(fields, (String(n), nothing, ln))
                        elseif n isa Expr && (n.head === :field || n.head === :(::))
                            push!(fields, (string(n.args[1]), string(n.args[2]), ln))
                        end
                    end
                end
                push!(defs, (name = string(nameexpr),
                             file = file,
                             mutable = e.head === :struct ? e.args[1] : false,
                             is_abstract = e.head === :abstract,
                             lineno = cur_lineno,
                             fields = tuple(fields...)))
                return   # fields are not nested structs; do not descend
            end
            for a in e.args
                if a isa LineNumberNode
                    cur_lineno = a.line
                elseif a isa Expr
                    walk!(a, cur_lineno)
                end
            end
        end
    end
    walk!(ex, 0)
    return defs
end

function classify_type_string(ts::Union{String,Nothing})
    ts === nothing && return :untyped
    ts == "Any" && return :any
    startswith(ts, "Union{") && return :union
    ts in ABSTRACT_FIELD_TYPES && return :abstract
    return :concrete
end

const KIND_COLOUR = Dict(
    :untyped   => AN_RED,
    :any       => AN_RED,
    :abstract  => AN_MAGENTA,
    :union     => AN_YELLOW,
    :concrete  => AN_GREEN,
)
const KIND_LABEL = Dict(
    :untyped   => "UNTYPED (=> Any)",
    :any       => "Any",
    :abstract  => "abstract",
    :union     => "Union{...}",
    :concrete  => "ok",
)

# Scan all src/**/*.jl for struct definitions; returns defs with per-field kinds.
function scan_all_struct_source()
    all_defs = NamedTuple[]
    for (root, dirs, files) in walkdir(joinpath(PROJECT_ROOT, "src"))
        for f in files
            endswith(f, ".jl") || continue
            path = joinpath(root, f)
            append!(all_defs, struct_defs_in_file(path))
        end
    end
    for (i, d) in enumerate(all_defs)
        kinds = [classify_type_string(f[2]) for f in d.fields]
        all_defs[i] = merge(d,
            (nfields = length(d.fields),
             n_untyped = count(==(:untyped), kinds),
             n_any = count(==(:any), kinds),
             n_abstract = count(==(:abstract), kinds),
             n_union = count(==(:union), kinds),
             kind_colour = kinds))
    end
    return all_defs
end

# ---------------------------------------------------------------------------
# WHOLE-PORT SCAN 2 — REFLECTED TYPE AUDIT (runtime fieldtypes over OracleD)
# ---------------------------------------------------------------------------

function oracle_struct_instances()
    out = NamedTuple[]
    seen = Set{Module}()
    function walk(m::Module)
        m in seen && return
        push!(seen, m)
        for n in names(m; all = true, imported = false)
            startswith(string(n), "#") && continue
            isdefined(m, n) || continue
            v = try getfield(m, n) catch; continue end
            if v isa Module
                # only descend into OracleD's own submodules, not imported ones
                (v === OracleD || parentmodule(v) === m) && parentmodule(v) === m && walk(v)
            elseif v isa DataType && v.name.module === m
                fc = try fieldcount(v) catch; nothing end
                fc === nothing && continue
                fc == 0 && continue
                push!(out, (mod = m, name = n, T = v))
            end
        end
    end
    walk(OracleD)
    return out
end

function field_kind_runtime(t)
    t === Any && return :any
    t isa Union && return :union
    !isconcretetype(t) && return :abstract
    return :concrete
end

# ---------------------------------------------------------------------------
# WHOLE-PORT SCAN 3 — JET.report_file over the whole include tree
# ---------------------------------------------------------------------------

function run_concrete_sim_setup()
    # uses the mini config / inventory to build one concrete simulation, reused
    # by the selective JET + @code_warntype sections
    return build_sim()
end

# ===========================================================================
# PHASE 1 — WHOLE-PORT TYPE STABILITY (struct scan + full JET + deep-dive)
# ===========================================================================

function phase1_type_stability(; structonly = false, nojetscan = false)
    println("\n" * join(fill("─", 72)))
    println("  PHASE 1: Whole-port Type Stability & Struct Scan")
    println(join(fill("─", 72)))

    logpath = joinpath(RUN_DIR, "type_stability.log")
    structpath = joinpath(RUN_DIR, "struct_scan.log")
    io = open(logpath, "w")
    sio = open(structpath, "w")

    opt_issues = Pair{String,Int}[]
    warntype_verdicts = Pair{String,String}[]
    warntype_counts = Pair{String,Tuple{Int,Int,Int}}[]

    println(io, "="^72)
    println(io, "  OracleD WHOLE-PORT Type Stability Report — Variant: $VARIANT")
    println(io, "  Date: $(Dates.now())")
    println(io, "="^72)
    println(io)
    println(io, "  COLOUR LEGEND")
    println(io, "    $(AN_RED)red    $(AN_RESET)  definite instability: `::Any` / untyped / abstract field, dynamic dispatch, error")
    println(io, "    $(AN_YELLOW)yellow $(AN_RESET)  possible instability: `::Union{...}` (may be benign)")
    println(io, "    $(AN_GREEN)green  $(AN_RESET)  no issue")
    println(io, "  View with `less -R` or `cat` to see the colours.")
    println(io)

    # ------------------------------------------------------------------ SCAN A
    println(io, "="^72)
    println(io, "  SCAN A — STRUCT DEFINITION SCAN (entire src/, source level)")
    println(io, "="^72)
    println("  SCAN A: struct definitions ...")
    defs = scan_all_struct_source()
    sort!(defs, by = d -> (d.n_untyped + d.n_any + d.n_abstract + d.n_union,
                           d.mutable ? 0 : 1), rev = true)
    tot_untyped = sum(d.n_untyped for d in defs)
    tot_any = sum(d.n_any for d in defs)
    tot_abstract = sum(d.n_abstract for d in defs)
    tot_union = sum(d.n_union for d in defs)
    tot_structs = length(defs)
    tot_fields = sum(d.nfields for d in defs)

    println(io, "  $(AN_BOLD)$tot_structs structs, $tot_fields fields: " *
                "$(AN_RED)$(tot_untyped + tot_any) Any-field(s) $(AN_RESET)" *
                "| $(AN_MAGENTA)$tot_abstract abstract-field(s) $(AN_RESET)" *
                "| $(AN_YELLOW)$tot_union Union-field(s) $(AN_RESET)")
    println(io)
    println(sio, "STRUCT SCAN — file:line listing of non-concretely-typed fields")
    println(sio, join(fill("=", 72)))
    found_bad = 0
    for d in defs
        badfields = [f for f in d.fields if classify_type_string(f[2]) != :concrete]
        isempty(badfields) && continue
        found_bad += 1
        mut = d.is_abstract ? "abstract type" : (d.mutable ? "mutable struct" : "struct")
        sev = AN_RED * "!!!" * AN_RESET
        rel = replace(relpath(d.file, PROJECT_ROOT), '\\' => "/")
        println(io)
        println(io, "  $(sev) $(AN_BOLD)$(d.name)$(AN_RESET)  ($mut) — $(rel):$(d.lineno) [" *
                    "$(d.n_untyped+d.n_any) Any / $(d.n_abstract) abstract / $(d.n_union) union among $(d.nfields) fields]")
        for f in d.fields
            nm, ts, ln = f
            k = classify_type_string(ts)
            k == :concrete && continue
            ts_s = ts === nothing ? "(untyped)" : ts
            println(io, "      $(KIND_COLOUR[k])$(rpad(KIND_LABEL[k], 25))$(AN_RESET)" *
                        "$(rpad("$nm :: $ts_s", 52)) $(AN_CYAN)$(rel):$ln$(AN_RESET)")
            println(sio, "  $(KIND_LABEL[k])  $nm  :: $ts_s   ($(rel):$ln)")
        end
    end
    if found_bad == 0
        println(io, "\n  $(AN_GREEN)No struct fields with Any / abstract / Union types found.$(AN_RESET)")
    end
    println(io)

    # ------------------------------------------------------------------ SCAN B
    println(io, "="^72)
    println(io, "  SCAN B — REFLECTED TYPE AUDIT (runtime fieldtypes over OracleD)")
    println(io, "="^72)
    println("  SCAN B: reflection over OracleD module tree ...")
    insts = oracle_struct_instances()
    println(io, "  Reflected $(AN_BOLD)$(length(insts))$(AN_RESET) concrete structs defined in OracleD.")
    println(io, "  Any-inline = whether instances are stored inline (no heap box).")
    println(io)
    rows = NamedTuple[]
    for it in insts
        T = it.T
        fc = fieldcount(T)
        fc == 0 && continue
        kinds = [field_kind_runtime(fieldtype(T, i)) for i in 1:fc]
        push!(rows, (name = string(it.name),
                     n_untyped_any = count(==(:any), kinds),
                     n_abstract = count(==(:abstract), kinds),
                     n_union = count(==(:union), kinds),
                     nfields = fc,
                     inline = Base.allocatedinline(T),
                     pfree = Base.datatype_pointerfree(T)))
    end
    sort!(rows, by = r -> (r.n_untyped_any + r.n_abstract + r.n_union,
                           r.n_untyped_any), rev = true)
    println(sio, "\n\nREFLECTED AUDIT — struct, Any fields, abstract fields, union fields, inline?")
    println(sio, join(fill("=", 72)))
    r_tot_any = sum(r.n_untyped_any for r in rows)
    r_tot_abs = sum(r.n_abstract for r in rows)
    r_tot_uni = sum(r.n_union for r in rows)
    r_suspect = 0
    for r in rows
        hot = r.n_untyped_any + r.n_abstract + r.n_union
        hot == 0 && continue
        r_suspect += 1
        label = r.n_untyped_any > 0 ? AN_RED : (r.n_abstract > 0 ? AN_MAGENTA : AN_YELLOW)
        println(io, "  $(label)[$hot]$(AN_RESET) $(AN_BOLD)$(rpad(r.name, 26))$(AN_RESET)" *
                    "  Any=$(r.n_untyped_any)  abstract=$(r.n_abstract)  union=$(r.n_union)  " *
                    "fields=$(r.nfields)  inline=$(r.inline)  pointerfree=$(r.pfree)")
        println(sio, join((r.name, r.n_untyped_any, r.n_abstract, r.n_union, r.nfields, r.inline), "  "))
    end
    println(io)
    println(io, "  Totals: $(AN_RED)$r_tot_any Any$(AN_RESET) / $(AN_MAGENTA)$r_tot_abs abstract$(AN_RESET) / " *
                "$(AN_YELLOW)$r_tot_uni union$(AN_RESET) fields across $(AN_BOLD)$r_suspect / $(length(rows))$(AN_RESET) reflected structs.")
    println(io)

    structonly && (close(sio); close(io); return logpath)

    # ------------------------------------------------------------------ SCAN C
    if !nojetscan
        println(io, "="^72)
        println(io, "  SCAN C — WHOLE-PORT JET SCAN (report_file on src/OracleD.jl)")
        println(io, "="^72)
        println("  SCAN C: JET.report_file on the whole include tree (this may take a minute) ...")
        jet_n = 0
        try
            r = JET.report_file(joinpath(PROJECT_ROOT, "src", "OracleD.jl");
                                toplevel_logger = nothing,
                                target_modules = (Main,))
            reps = JET.get_reports(r)
            jet_n = length(reps)
            if jet_n == 0
                println(io, "  $(AN_GREEN)[OK]$(AN_RESET) whole-port JET scan found no problems.")
            else
                println(io, "  $(AN_RED)Found $jet_n whole-port problem(s):$(AN_RESET)")
                for p in reps
                    kind = occursin("MethodError|NoMethod", string(typeof(p))) ? AN_RED : AN_YELLOW
                    msg = sprint(show, p)
                    println(io, "  $(kind)[ISSUE]$(AN_RESET) $(msg[1:min(end, 200)])")
                end
            end
        catch e
            println(io, "  $(AN_RED)WHOLE-PORT JET ERROR: $e$(AN_RESET)")
            jet_n = -1
        end
        println(io)
        push!(opt_issues, "Whole-port JET (report_file)" => jet_n)
    end

    # ------------------------------------------------------------------ SCAN D
    println(io, "="^72)
    println(io, "  SCAN D — SELECTIVE DEEP-DIVE (hot-path functions)")
    println(io, "="^72)
    println("  SCAN D: selective JET + code_warntype ...")

    function run_jet(label, f)
        println(io, "--- JET.@report_call (errors): $label ---")
        println("  JET: @report_call $label ...")
        try
            result = JET.@report_call f()
            reports = result === nothing ? () : JET.get_reports(result)
            if isempty(reports)
                println(io, "  $(AN_GREEN)[OK]$(AN_RESET) no errors detected by JET")
            else
                for p in reports
                    println(io, "  $(AN_RED)[ERROR]$(AN_RESET) $(sprint(show, p))")
                end
            end
        catch e
            println(io, "  $(AN_RED)JET ERROR: $e$(AN_RESET)")
        end
        println(io)
        println("  done.")
    end

    function run_jet_opt(label, f)
        println(io, "--- JET.@report_opt (instabilities): $label ---")
        println("  JET: @report_opt $label ...")
        n = 0
        try
            result = JET.@report_opt ignored_modules=(Base, Core) f()
            reports = result === nothing ? () : JET.get_reports(result)
            if isempty(reports)
                println(io, "  $(AN_GREEN)[OK]$(AN_RESET) no optimization failures / dynamic dispatch detected")
            else
                for p in reports
                    n += 1
                    kind = occursin("Dispatch", string(typeof(p))) ? AN_YELLOW : AN_RED
                    println(io, "  $(kind)[INSTABILITY]$(AN_RESET) $(sprint(show, p))")
                end
            end
        catch e
            println(io, "  $(AN_RED)JET OPT ERROR: $e$(AN_RESET)")
        end
        push!(opt_issues, label => n)
        println(io)
        println("  done.")
    end

    function run_warntype(label, f, args...)
        println(io, "--- @code_warntype: $label ---")
        println("  Cthulhu: $label ...")
        try
            old_stdout = stdout
            rd, wr = redirect_stdout()
            reader = @async read(rd, String)
            try
                @code_warntype f(args...)
            finally
                close(wr)
                redirect_stdout(old_stdout)
            end
            output = fetch(reader)
            close(rd)
            colour, n_any, n_union, n_box = scan_warntype(output)
            print(io, colour)
            println(io)
            verdict = warntype_verdict(n_any, n_union, n_box)
            println(io, "  "*verdict)
            push!(warntype_verdicts, label => verdict)
            push!(warntype_counts, label => (n_any, n_union, n_box))
            println("    "*verdict)
        catch e
            println(io, "  $(AN_RED)WARNTYPE ERROR: $e$(AN_RESET)")
        end
        println(io)
        println("  done.")
    end

    sim = run_concrete_sim_setup()

    run_jet("Cluster.update!", _jet_cluster_update)
    run_jet("WorkerNode.update!", _jet_worker_update)
    run_jet("JobScheduler.update!", _jet_scheduler_update)
    run_jet("Simulation constructor", _jet_sim_constructor)

    run_jet_opt("Cluster.update!", () -> _opt_cluster_update(sim))
    run_jet_opt("WorkerNode.update!", () -> _opt_worker_update(sim))
    run_jet_opt("JobScheduler.update!", () -> _opt_scheduler_update(sim))
    run_jet_opt("Simulation constructor", _jet_sim_constructor)

    if VARIANT == :graeme
        run_jet("create_job (GridPP)",
                () -> OracleD.create_job(OracleD.GridPPJobFactory("GridPP-")))
        run_jet("create_job (LHCb)",
                () -> OracleD.create_job(OracleD.LHCbJobFactory("LHCb-Prod-")))
        run_jet("load_cluster_inventory",
                () -> OracleD.load_cluster_inventory(
                    "data/cluster/default-machinegroups_inventory.csv",
                    "data/cluster/default-frequency_dependence.csv";
                    cluster_name = "DEFAULT", strict = false))
        run_jet_opt("create_job (GridPP)",
                () -> OracleD.create_job(OracleD.GridPPJobFactory("GridPP-")))
        run_jet_opt("create_job (LHCb)",
                () -> OracleD.create_job(OracleD.LHCbJobFactory("LHCb-Prod-")))
        run_jet_opt("load_cluster_inventory",
                () -> OracleD.load_cluster_inventory(
                    "data/cluster/default-machinegroups_inventory.csv",
                    "data/cluster/default-frequency_dependence.csv";
                    cluster_name = "DEFAULT", strict = false))
        run_warntype("update!(cluster::Cluster)", OracleD.update!, sim.cluster)
        run_warntype("update!(worker_node::WorkerNode)", OracleD.update!, sim.cluster.worker_nodes[1])
    else
        run_jet("create_job (GridPP)",
                () -> OracleD.create_job(OracleD.GridPPJobFactory("GridPP-")))
        run_jet("create_job (LHCb)",
                () -> OracleD.create_job(OracleD.LHCbJobFactory("LHCb-Prod-")))
        run_jet("load_cluster_inventory",
                () -> OracleD.load_cluster_inventory(
                    "data/cluster/default-machinegroups_inventory.csv",
                    "data/cluster/default-frequency_dependence.csv";
                    cluster_name = "DEFAULT", strict = false))
        run_jet_opt("create_job (GridPP)",
                () -> OracleD.create_job(OracleD.GridPPJobFactory("GridPP-")))
        run_jet_opt("create_job (LHCb)",
                () -> OracleD.create_job(OracleD.LHCbJobFactory("LHCb-Prod-")))
        run_jet_opt("load_cluster_inventory",
                () -> OracleD.load_cluster_inventory(
                    "data/cluster/default-machinegroups_inventory.csv",
                    "data/cluster/default-frequency_dependence.csv";
                    cluster_name = "DEFAULT", strict = false))
        run_warntype("update_cluster(cluster::Cluster)", OracleD.update_cluster, sim._cluster)
        run_warntype("update_node(worker_node::WorkerNode)", OracleD.update_node, sim._cluster._worker_nodes[1])
    end

    # ------------------------------------------------------------------ SUMMARY
    println(io, "="^72)
    println(io, "  SUMMARY")
    println(io, "="^72)
    JET_KEY = "Whole-port JET (report_file)"
    jetx = opt_issues_dict(opt_issues, JET_KEY)
    tot_selective_opt = sum(n for (label, n) in opt_issues if label != JET_KEY)
    tot_opt = tot_selective_opt + jetx
    tot_definite = sum(c[1] + c[3] for (_, c) in warntype_counts)
    tot_union_w = sum(c[2] for (_, c) in warntype_counts)
    println(io)
    println(io, "  SCAN A (source structs):    $(RED(tot_untyped + tot_any)) Any-field(s), " *
                "$(MAG(tot_abstract)) abstract, $(YEL(tot_union)) union across $tot_structs structs")
    println(io, "  SCAN B (reflected structs): $(RED(r_tot_any)) Any-field(s), " *
                "$(MAG(r_tot_abs)) abstract, $(YEL(r_tot_uni)) union across $(length(rows)) structs")
    println(io, "  SCAN C (whole-port JET):    $(RED(jetx)) whole-port problem(s)")
    println(io, "  SCAN D (selective):         $(YEL(tot_selective_opt)) @report_opt issue(s); " *
                "$(RED(tot_definite)) definite / $(YEL(tot_union_w)) possible in @code_warntype")
    println(io)
    println(io, "  JET.@report_opt / whole-port (dynamic dispatch / failures):")
    for (label, n) in opt_issues
        line = n == 0 ? "$(AN_GREEN)[OK]$(AN_RESET)            $label" :
                        "$(AN_YELLOW)[ISSUES: $n]$(AN_RESET)   $label"
        println(io, "     $line")
    end
    println(io, "     $(AN_BOLD)Total (@report_opt): $tot_selective_opt + whole-port JET: $jetx = $tot_opt$(AN_RESET)")
    println(io)
    println(io, "  @code_warntype verdicts (definite = Any + Core.Box):")
    for (label, verdict) in warntype_verdicts
        println(io, "     $label")
        println(io, "        $verdict")
    end
    println(io, "     $(AN_BOLD)Total definite: $tot_definite, possible (Union{...}): $tot_union_w$(AN_RESET)")
    println(io)
    overall_bad = r_tot_any + jetx + tot_selective_opt + tot_definite
    if overall_bad == 0
        println(io, "  $(AN_GREEN)Overall verdict: no type instabilities detected.$(AN_RESET)")
    else
        println(io, "  $(AN_RED)Overall verdict: $overall_bad issue(s) across whole-port scans; " *
                    "see colour-coded output above.$(AN_RESET)")
    end
    println(io, "="^72)

    close(sio)
    close(io)
    println("\n  Report:      $logpath")
    println("  Struct scan: $structpath")
    return logpath
end

# tiny helpers so the summary lines above read cleanly
RED(s) = AN_RED * string(s) * AN_RESET
YEL(s) = AN_YELLOW * string(s) * AN_RESET
MAG(s) = AN_MAGENTA * string(s) * AN_RESET

function opt_issues_dict(v, k)
    idx = findfirst(x -> x.first == k, v)
    idx === nothing ? 0 : v[idx].second
end

# ---------------------------------------------------------------------------
# Phase 2 — Profiling / Flamegraph
# ---------------------------------------------------------------------------
Profile.init(n = 10_000_000, delay = 0.00002)
function phase2_profiling()
    println("\n" * join(fill("─", 72)))
    println("  PHASE 2: Profiling with Flamegraphs")
    println(join(fill("─", 72)))

    function profiled_run()
        sim = build_mini_simulation()
        run_mini_simulation(sim)
        return nothing
    end

    println("  Warming up...")
    profiled_run()

    println("  Profiling ...")
    Profile.clear()
    @profile profiled_run()

    treepath = joinpath(RUN_DIR, "profile_tree.txt")
    open(treepath, "w") do f
        Profile.print(f; format = :tree, C = false, maxdepth = 30)
    end

    println("\n  Top 30 most-sampled lines:")
    println("  " * join(fill("·", 60)))
    try
        Profile.print(; format = :tree, C = true, maxdepth = 30)
    catch
        println("  (frame detail unavailable)")
    end

    println("\n  Generating flamegraph (flat text output) ...")
    flatpath = joinpath(RUN_DIR, "flamegraph_flat.txt")
    open(flatpath, "w") do f
        Profile.print(f; format = :flat, C = true, sortedby = :count)
    end
    println("  Flat profile -> $flatpath")
    return flatpath
end

# ---------------------------------------------------------------------------
# Phase 3 — Benchmarking
# ---------------------------------------------------------------------------

function phase3_benchmarking()
    println("\n" * join(fill("─", 72)))
    println("  PHASE 3: Benchmarking")
    println(join(fill("─", 72)))

    logpath = joinpath(RUN_DIR, "benchmarks.txt")
    io = open(logpath, "w")

    println(io, "="^72)
    println(io, "  OracleD Benchmark Report — Variant: $VARIANT")
    println(io, "  Date: $(Dates.now())")
    println(io, "="^72, "\n")

    results_vec = Pair{String,Any}[]

    println("  1/6: Simulation constructor ...")
    b1 = @benchmark build_mini_simulation() samples = 30 seconds = 30
    push!(results_vec, "Simulation constructor" => b1)
    println(io, "1. Simulation constructor\n   $(b1)\n")

    println("  2/6: Cluster update (single timestep) ...")
    if VARIANT == :graeme
        b2 = @benchmark OracleD.update!(s.cluster) setup = (s = build_mini_simulation()) samples = 100 seconds = 30
    else
        b2 = @benchmark OracleD.update_cluster(s._cluster) setup = (s = build_mini_simulation()) samples = 100 seconds = 30
    end
    push!(results_vec, "Cluster update (1 timestep)" => b2)
    println(io, "2. Cluster update (single timestep)\n   $(b2)\n")

    println("  3/6: WorkerNode update ...")
    if VARIANT == :graeme
        b3 = @benchmark OracleD.update!(wn) setup = (s = build_mini_simulation(); wn = s.cluster.worker_nodes[1]) samples = 200 seconds = 30
    else
        b3 = @benchmark OracleD.update_node(wn) setup = (s = build_mini_simulation(); wn = s._cluster._worker_nodes[1]) samples = 200 seconds = 30
    end
    push!(results_vec, "WorkerNode update" => b3)
    println(io, "3. WorkerNode update\n   $(b3)\n")

    println("  4/6: create_job (GridPP) ...")
    b4 = @benchmark OracleD.create_job!(OracleD.GridPPJobFactory("GridPP-")) samples = 500 seconds = 30
    push!(results_vec, "create_job (GridPP)" => b4)
    println(io, "4. Job creation (GridPP)\n   $(b4)\n")

    println("  5/6: create_job (LHCb) ...")
    b5 = @benchmark OracleD.create_job!(OracleD.LHCbJobFactory("LHCb-")) samples = 500 seconds = 30
    push!(results_vec, "create_job (LHCb)" => b5)
    println(io, "5. Job creation (LHCb)\n   $(b5)\n")

    println("  6/6: Full short simulation ...")
    b6 = @benchmark begin
        s = build_mini_simulation()
        run_mini_simulation(s)
    end samples = 10 seconds = 60
    push!(results_vec, "Full short simulation" => b6)
    println(io, "6. Full short simulation\n   $(b6)\n")

    println(io, join(fill("─", 72)))
    println(io, "  Summary (min / mean / max)")
    println(io, join(fill("─", 72)))
    for (label, b) in results_vec
        @printf(io, "  %-28s  %9.3f μs / %9.3f μs / %9.3f μs   alloc: %s  (%.0f)\n",
                label,
                minimum(b.times) / 1e3,
                mean(b.times) / 1e3,
                maximum(b.times) / 1e3,
                pretty_memory(b.memory),
                b.allocs)
    end
    println(io)
    close(io)
    println("\n  Report: $logpath")

    println("\n  " * join(fill("·", 60)))
    println("  Results (min / mean / max):")
    for (label, b) in results_vec
        @printf("  %-28s  %8.1f μs / %8.1f μs / %8.1f μs  (%.0f allocs, %s)\n",
                label,
                minimum(b.times) / 1e3,
                mean(b.times) / 1e3,
                maximum(b.times) / 1e3,
                b.allocs,
                pretty_memory(b.memory))
    end

    return logpath
end

function pretty_memory(bytes)
    if bytes >= 1_024_000_000
        return @sprintf("%.1f GB", bytes / 1_024_000_000)
    elseif bytes >= 1_024_000
        return @sprintf("%.1f MB", bytes / 1_024_000)
    elseif bytes >= 1_024
        return @sprintf("%.1f KB", bytes / 1_024)
    else
        return @sprintf("%llu B", bytes)
    end
end

# ---------------------------------------------------------------------------
# Phase 4 — Summary
# ---------------------------------------------------------------------------

function phase4_summary()
    println("\n" * join(fill("=", 72)))
    println("  DIAGNOSTICS SUMMARY")
    println(join(fill("=", 72)))

    println("  Variant: $VARIANT")
    println("  Run dir: $(abspath(RUN_DIR))/")
    println()
    println("  Output files:")
    println("    type_stability.log   (Scans A-D + summary)")
    println("    struct_scan.log      (source-level struct field listing)")
    println("    flamegraph_flat.txt / profile_tree.txt")
    println("    benchmarks.txt")
    println()
    println("  Whole-port focus:")
    println("    Scan A: struct defs (untyped/Any/abstract/Union fields) with file:line")
    println("    Scan B: reflected fieldtype audit over the OracleD module tree")
    println("    Scan C: JET.report_file over the entire src/ include tree")
    println("    Scan D: selective deep-dive on hot-path functions")
    println()
    println(join(fill("=", 72)))
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function main(args = ARGS)
    t_start = time()
    selected = String[]
    structonly = false
    nojetscan = false
    for a in args
        m = match(r"^--phase([123])$", a)
        m === nothing || push!(selected, m.captures[1])
        a == "--structsonly" && (structonly = true)
        a == "--nojetscan" && (nojetscan = true)
    end
    run_all = isempty(selected)
    run_phase(p) = run_all || (p in selected)

    if structonly
        # just the struct scans (fast)
        phase1_type_stability(; structonly = true, nojetscan = true)
    else
        run_phase("1") && phase1_type_stability(; structonly = false, nojetscan)
        run_phase("2") && phase2_profiling()
        run_phase("3") && phase3_benchmarking()
        run_phase("1") && phase4_summary()
    end

    elapsed = time() - t_start
    println("\n  Done in $(@sprintf("%.1f", elapsed)) s")
    println("  Run: $(abspath(RUN_DIR))/")
end

main()
