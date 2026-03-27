module Benchmarks

using Base: call_composed, Callable
using HerbInterpret: make_interpreter, execute_on_input
using BenchmarkTools
using HerbGrammar: @csgrammar, expr2rulenode, grammar2symboltable, rulenode2expr
using HerbCore: HerbCore, RuleNode
using HerbSearch: BFSIterator
using HerbConstraints: freeze_state
using HerbBenchmarks: PBE_BV_Track_2018 as BV
using HerbBenchmarks: PBE_SLIA_Track_2019 as SLIA
using HerbBenchmarks: get_problem_grammar_pair
using RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

function create_interpret_benchmark()
    suite = BenchmarkGroup()
    g = @csgrammar begin
        Var = Var + Var
        Var = Var * Var
        Var = Var / Var
        Var = |(0:5)
    end

    # rns = BFSIterator(g, :Var; max_depth=3)
    #
    # interpret = make_interpreter(g; cache_module=@__MODULE__, target_module=@__MODULE__)
    # suite["Random Expressions"] = @benchmarkable interpret.($rns)

    return suite
end

function collect_rulenodes_interpreter_herbbench(benchmark_module, problem_name)
    pgp = get_problem_grammar_pair(benchmark_module, problem_name)
    spec = pgp.problem.spec
    g = pgp.grammar
    st = grammar2symboltable(g, benchmark_module)
    @info "Collecting expressions to benchmark" mod = benchmark_module prob = problem_name
    it = BFSIterator(g, :Start; max_depth=4, max_size=8)
    interpret = make_interpreter(g; cache_module=@__MODULE__, target_module=benchmark_module)

    rns = [freeze_state(p) for p in it]
    rns = rns[end-100:end]
    @info "Expressions collected" length(rns) type = typeof(rns) examples = rns
    return g, st, interpret, rns, spec
end

function create_herbbench_benchmark(benchmark_module, problem_name)
    g, st, interpret, rns, spec = collect_rulenodes_interpreter_herbbench(benchmark_module, problem_name)
    return compare_generated_vs_rulenode2expr_based(st, rns, interpret, spec)
end

function compare_generated_vs_rulenode2expr_based(symbol_table, rulenodes, interpret, spec)
    suite = BenchmarkGroup()
    suite["$(length(rulenodes)) expressions"]["generated"] = @benchmarkable try
        $interpret.($rulenodes, ($spec,))
    catch e
        if !(e isa BoundsError)
            rethrow(e)
        end
    end

    suite["$(length(rulenodes)) expressions"]["rulenode2expr"] = @benchmarkable try
        execute_on_input.(($symbol_table,), $rulenodes, ($([s.in for s in spec]),))
    catch e
        if !(e isa BoundsError)
            rethrow(e)
        end
    end

    return suite
end

function create_benchmarks()
    suite = BenchmarkGroup()
    suite["interpret"] = create_interpret_benchmark()
    suite["HerbBenchmark grammars"]["BV"] = create_herbbench_benchmark(BV, "PRE_100_10")
    suite["HerbBenchmark grammars"]["SLIA"] = create_herbbench_benchmark(SLIA, "11604909")
    return suite
end
end
