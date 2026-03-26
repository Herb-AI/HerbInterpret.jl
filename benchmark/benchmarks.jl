using BenchmarkTools
using Random: seed!
using HerbGrammar: @csgrammar, grammar2symboltable, rulenode2expr
using HerbCore: RuleNode
using HerbSearch: BFSIterator
using HerbInterpret: make_interpreter

function create_interpret_benchmark()
    suite = BenchmarkGroup()
    seed!(42) # keep random expressions constant
    g = @csgrammar begin
        Var = Var + Var
        Var = Var * Var
        Var = Var / Var
        Var = |(0:5)
    end

    interpret = make_interpreter(g; cache_module=@__MODULE__, target_module=@__MODULE__)
    suite["Random Expressions"] = @benchmarkable interpret.($EXPRS)

    return suite
end

function create_benchmarks()
    suite = BenchmarkGroup()
    suite["interpret"] = create_interpret_benchmark()
    return suite
end

const SUITE = create_benchmarks()
