# HerbInterpret.jl

[![codecov](https://codecov.io/github/Herb-AI/HerbInterpret.jl/graph/badge.svg?token=XQCX4ZN0SG)](https://codecov.io/github/Herb-AI/HerbInterpret.jl)
[![Build Status](https://github.com/Herb-AI/HerbInterpret.jl/actions/workflows/CI.yml/badge.svg?branch=master)](https://github.com/Herb-AI/HerbInterpret.jl/actions/workflows/CI.yml?query=branch%3Amaster)
[![Dev-Docs](https://img.shields.io/badge/docs-latest-blue.svg)](https://Herb-AI.github.io/Herb.jl/dev)

This package provides functionality for interpreting (candidate) programs in the Herb Program Synthesis framework. `HerbInterpret.jl` can handle arbitrary Julia expressions, but also arbitrary other interpretors for which an evaluation function is given.

## Usage

The simplest way to evaluate a candidate program is to convert it to a Julia
`Expr` with `rulenode2expr` and run it with `execute_on_input`:

```julia
using HerbCore, HerbGrammar, HerbInterpret

grammar = @csgrammar begin
    Number = |(1:2)
    Number = x
    Number = Number + Number
    Number = Number * Number
end

rn = @rulenode 4{3,1}  # x + 1

expr = rulenode2expr(rn, grammar)
output = execute_on_input(grammar2symboltable(grammar, Main), expr, Dict(:x => 6))
println(output)  # 7
```

For tight loops that evaluate many candidate programs against the same
grammar (e.g. during search), `make_interpreter` builds a dedicated,
self-recursive interpreter function once and reuses it for every
candidate, which is substantially faster than re-running `rulenode2expr` +
`execute_on_input` for each one:

```julia
using HerbCore, HerbGrammar, HerbInterpret

grammar = @csgrammar begin
    Number = |(1:2)
    Number = x
    Number = Number + Number
    Number = Number * Number
end

# Build once, outside the loop.
interp = make_interpreter(grammar; input_symbols = [:x])

rn = @rulenode 4{3,1}  # x + 1
output = interp(rn, Dict{Symbol,Any}(:x => 6))
println(output)  # 7

# Also accepts a vector of inputs, an `IOExample`, or a vector of `IOExample`s:
outputs = interp(rn, [Dict{Symbol,Any}(:x => 6), Dict{Symbol,Any}(:x => 10)])
println(outputs)  # [7, 11]
```

If the grammar's operators live in another module (e.g. a benchmark
module defining domain-specific primitives), pass `target_module` so they
resolve correctly:

```julia
interp = make_interpreter(grammar; input_symbols = [:x], target_module = MyBenchmarkModule)
```

