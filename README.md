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

### Stateful interpreters

Some DSLs (e.g. robot/turtle languages) don't take an input dict but
instead thread a single state value through the program, with dedicated
`IF`/`WHILE` control-flow rules. `make_stateful_interpreter` builds an
interpreter for that style of grammar:

```julia
using HerbCore, HerbGrammar, HerbInterpret

struct RobotState
    pos::Int
end

moveRight(s::RobotState) = RobotState(s.pos + 1)
atWall(s::RobotState) = s.pos >= 3

grammar = @cfgrammar begin
    Start = Sequence
    Sequence = Step
    Sequence = (Step; Sequence)
    Step = moveRight()
    Step = WHILE(Cond, Step)
    Cond = atWall()
end

interp = make_stateful_interpreter(grammar; target_module = @__MODULE__)

rn = @rulenode 1{2{4}}  # moveRight()
output = interp(rn, RobotState(0))
println(output)  # RobotState(1)
```

Recognized control-flow forms in the grammar are:
- `(Step; Sequence)` — sequencing, threads state through both children in order
- `IF(Cond, Step, Step)` — branches on the condition
- `WHILE(Cond, Step)` — loops while the condition holds, bounded to 1000 iterations

As with `make_interpreter`, pass `target_module` to resolve primitives
defined elsewhere, and `cache_module` to control where the generated
function is defined.

### Lambdas

Grammar rules may contain lambda expressions, e.g. to synthesize a function
passed to a higher-order primitive like `map`. Lambda argument variables are
resolved as plain locals rather than as nonterminals or globals, and lambda
bodies can themselves reference nonterminals (so a lambda can call another
synthesized function):

```julia
using HerbCore, HerbGrammar, HerbInterpret

grammar = @csgrammar begin
    Arr = _arg_1
    Arr = map(Func, Arr)

    Func = iseven
    Func = x -> x + 1
end

interp = make_interpreter(grammar)

input = Dict{Symbol,Any}(:_arg_1 => [1, 2, 3, 4])

rn = @rulenode 2{4,1}  # map(x -> x + 1, arr)
println(interp(rn, input))  # [2, 3, 4, 5]
```

`make_stateful_interpreter` supports lambdas the same way, except lambda
bodies are treated as pure expressions: named calls inside a lambda do
*not* receive `state` implicitly (unlike ordinary DSL rules, where e.g.
`inc()` becomes `inc(state)`).

