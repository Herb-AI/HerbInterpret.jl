using RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__) 

"""
    _is_input_tag(tag, input_set)

Checks whether a tag is an input. 
A tag is treated as an *input terminal* if:

1. it is a `Symbol` that contains the substring `"_arg_"` (the default convention), OR
2. `input_set` is provided and `tag ∈ input_set`.
"""
_is_input_tag(tag, input_set) =
    tag isa Symbol && (occursin("_arg_", String(tag)) || (input_set !== nothing && (tag in input_set)))


"""
    _qualify(target_module::Module, f)

Resolve symbol `f` in `target_module` at compile time.
"""
function _qualify(target_module::Module, f)
    return f isa Symbol ? GlobalRef(target_module, f) : f
end

"""
    _collect_lambda_args(lhs)

Return the flat list of variables bound by a lambda lhs.

Supports:
```
- x
- (x, y)
- x::T
- (x::T, y::S)
- varargs like x...
```

Concretely this supports the following examples:
```
x -> Func(x)
(x) -> Func(x)
(x::Int) -> x + 1
(x, y) -> x + y
(x::Int, y::Int) -> x * y
(xs...) -> sum(xs)
(x, ys...) -> x + length(ys)
```

But not:
```
() -> 1                 # zero-arg lambda
((x, y), z) -> x + z    # destructuring / nested tuple patterns
(; x=1) -> x            # keyword-style parameter forms
```
"""
function _collect_lambda_args(lhs)
    if lhs isa Symbol
        return Symbol[lhs]

    elseif lhs isa Expr
        if lhs.head == :(::)
            return _collect_lambda_args(lhs.args[1])

        elseif lhs.head == :tuple
            out = Symbol[]
            for a in lhs.args
                append!(out, _collect_lambda_args(a))
            end
            return out

        elseif lhs.head == :...
            return _collect_lambda_args(lhs.args[1])
        end
    end

    throw(ArgumentError("Unsupported lambda argument syntax: $lhs"))
end

"""
    build_match_cases(grammar; target_module=@__MODULE__, input_symbols=nothing)

Return a vector of "guarded return" branches of the form:

    r == k && return <rhs>

These branches are intended to be spliced into a block after
`r = get_rule(prog); c = get_children(prog)`.

Returns a vector of branching expressions.

Is based on `emit_eval`, which translates nested rules like
```
Number = Number + 1
```
into
```
Expr(:call,
     GlobalRef(target_module, :+),
     :(self(self, c[1], input)),
     1)
```
which denotes the intended operation within the target module applied to the evaluation result of the children, here `c[1]`.

"""
function build_match_cases(
    grammar::AbstractGrammar;
    target_module::Module = @__MODULE__,
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
)
    input_set = input_symbols === nothing ? nothing : Set(input_symbols)
    
    nonterminals = Set{Symbol}(t for t in grammar.types if t !== nothing)

    # recurse on child i as: c[i]
    recur(i) = :( c[$i] )

    # `bound` is needed to lambda values apart from grammar symbols and globals
    # `next_child` denotes which child to consume next.
    function emit_eval(
        x,
        next_child::Base.RefValue{Int},
        bound::Set{Symbol} = Set{Symbol}(),
    )
        if x isa Symbol
            if x in bound
                return x
            elseif x in nonterminals
                i = next_child[]
                next_child[] += 1
                return recur(i)
            elseif _is_input_tag(x, input_set)
                return :( input[$(QuoteNode(x))] )
            else
                return GlobalRef(target_module, x)
            end

        elseif x isa Expr
            # x is a lambda function
            if x.head == :->
                lhs = x.args[1]
                rhs = x.args[2]

                bound2 = copy(bound)
                union!(bound2, _collect_lambda_args(lhs))

                return Expr(:->, lhs, emit_eval(rhs, next_child, bound2))
            # x is a function call
            elseif x.head == :call
                f = emit_eval(x.args[1], next_child, bound)
                args = [emit_eval(a, next_child, bound) for a in x.args[2:end]]
                return Expr(:call, f, args...)

            # x is an if-then-else block
            elseif x.head == :if
                cond = emit_eval(x.args[1], next_child, bound)
                tbr  = emit_eval(x.args[2], next_child, bound)
                fbr  = emit_eval(x.args[3], next_child, bound)
                return Expr(:if, cond, tbr, fbr)

            else
                return Expr(x.head, (emit_eval(a, next_child, bound) for a in x.args)...)
            end
        else
            return x
        end
    end

    branches = Expr[]

    for (ind, rhs_rule) in pairs(grammar.rules)
        rhs_code = nothing

        if rhs_rule isa Expr && rhs_rule.head == :call
            op   = rhs_rule.args[1]
            args = rhs_rule.args[2:end]

            pure =
                (op isa Symbol) &&
                !(op in nonterminals) &&
                all(a -> (a isa Symbol) && (a in nonterminals), args)

            if pure
                nargs = length(args)
                child_vals = [recur(i) for i in 1:nargs]
                rhs_code = Expr(:call, GlobalRef(target_module, op), child_vals...)
            else
                nxt = Ref(1)
                rhs_code = emit_eval(rhs_rule, nxt)
            end

        elseif rhs_rule isa Expr
            nxt = Ref(1)
            rhs_code = emit_eval(rhs_rule, nxt)

        elseif rhs_rule isa Symbol
            if rhs_rule in nonterminals
                rhs_code = recur(1)
            elseif _is_input_tag(rhs_rule, input_set)
                rhs_code = :( input[$(QuoteNode(rhs_rule))] )
            else
                rhs_code = GlobalRef(target_module, rhs_rule)
            end

        else
            rhs_code = rhs_rule
        end

        push!(branches, :( r == $(ind) && return $rhs_code ))
    end

    return branches
end


struct GeneratedInterpreter{F}
    core::F
end

struct GeneratedOutputInterpreter{F}
    core::F
end

# Single input
function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   input::AbstractDict{Symbol,Any})
    return gi.core(gi.core, prog, input)
end

function (gi::GeneratedOutputInterpreter)(rule::Int,
                                   children_outputs::AbstractVector{<:Any},
                                   input::AbstractDict{Symbol,Any})
    return gi.core(gi.core, rule, children_outputs, input)
end

# Vector of inputs
function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   inputs::AbstractVector{<:AbstractDict{Symbol,Any}})
    return (gi.core).((gi.core,), (prog,), inputs)   # broadcasts (self, prog, input)
end

function (gi::GeneratedOutputInterpreter)(rule::Int,
                                   children_outputs::AbstractVector{<:AbstractVector{<:Any}},
                                   inputs::AbstractVector{<:AbstractDict{Symbol,Any}})
    return [gi.core(gi.core, rule, [outputs[index] for outputs in children_outputs], input) for (index, input) in enumerate(inputs)]
end

function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   ex::HerbSpecification.IOExample)
    return gi(prog, ex.in)
end

function (gi::GeneratedOutputInterpreter)(rule::Int,
                                   children_outputs::AbstractVector{<:Any},
                                   ex::HerbSpecification.IOExample)
    return gi(rule, children_outputs, ex.in)
end

function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   exs::AbstractVector{<:HerbSpecification.IOExample})
    return [gi(prog, ex) for ex in exs]
end

function (gi::GeneratedOutputInterpreter)(rule::Int,
                                   children_outputs::AbstractVector{<:AbstractVector{<:Any}},
                                   exs::AbstractVector{<:HerbSpecification.IOExample})
    return [gi(rule, [outputs[index] for outputs in children_outputs], ex) for (index, ex) in enumerate(exs)]
end

#
#   Vector{Any}[]
#   Vector{IOExample{Any, String}}

"""
    make_interpreter(grammar::AbstractGrammar; input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing, target_module::Module = @__MODULE__, cache_module::Module = HerbInterpret)


Constructs a fast, runtime-generated interpreter for programs represented as `HerbCore.AbstractRuleNode`s.

The returned value is a callable `GeneratedInterpreter` (a small wrapper around a `RuntimeGeneratedFunctions.RuntimeGeneratedFunction`) that can be applied to:

- a single input dictionary:
  `interp(prog, input::AbstractDict{Symbol,Any})`
- a vector of input dictionaries:
  `interp(prog, inputs::AbstractVector{<:AbstractDict{Symbol,Any}})`
- a single `HerbSpecification.IOExample`:
  `interp(prog, ex::IOExample)` (uses `ex.in`)
- a vector of `IOExample`s:
  `interp(prog, exs::AbstractVector{<:IOExample})`

## Arguments

- `grammar`: The grammar whose rule indices define the operational semantics.
  The interpreter dispatches by `r = HerbCore.get_rule(prog)`.

## Keyword arguments

- `input_symbols`: Optional list of symbols that should be interpreted as inputs.  If provided, terminals matching these symbols (and any symbol following the `_arg_X` convention) are read from the `input` dict.

- `target_module`: Module in which operator/function symbols appearing in the grammar are resolved. This is important when the grammar uses domain-specific primitives (e.g. `concat_cvc`, `substr_cvc`) that are defined in a benchmark module rather than in the caller’s module.

- `cache_module`: Module used by `RuntimeGeneratedFunctions.jl` to store its internal cachen. 
"""
function make_interpreter(grammar::AbstractGrammar;
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
    target_module::Module = @__MODULE__,
    cache_module::Module = HerbInterpret
)
    # ensure the cache exists in the chosen cache module
    RuntimeGeneratedFunctions.init(cache_module)

    # build if-then-else statements to evaluate the expressions
    branches = build_match_cases(grammar;
        target_module = target_module,
        input_symbols = input_symbols
    )

    # Add error for non-existent indices
    cascade = Expr(:block, branches..., :(error("No matching rule index: ", r)))

    # Bit of meta-programming magic:
    # Constructs an anonymous function with an extra self arg for recursion.
    ex = :(function (self, prog, input)
        r = HerbCore.get_rule(prog)
        c = [self(self, child, input) for child in get_children(prog)]
        any(isnothing, c) && return nothing
        $cascade
    end)
    Base.remove_linenums!(ex)

    # Call RuntimeGeneratedFunction on this, so we can directly use it
    core = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(cache_module, target_module, ex)
    return GeneratedInterpreter(core)
end


function make_output_interpreter(grammar::AbstractGrammar;
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
    target_module::Module = @__MODULE__,
    cache_module::Module = HerbInterpret
)
    # ensure the cache exists in the chosen cache module
    RuntimeGeneratedFunctions.init(cache_module)

    # build if-then-else statements to evaluate the expressions
    branches = build_match_cases(grammar;
        target_module = target_module,
        input_symbols = input_symbols
    )

    # Add error for non-existent indices
    cascade = Expr(:block, branches..., :(error("No matching rule index: ", r)))

    # Bit of meta-programming magic:
    # Constructs an anonymous function with an extra self arg for recursion.
    ex = :(function (self, rule, children_outputs, input)
        r = rule
        c = children_outputs
        any(isnothing, c) && return nothing
        $cascade
    end)
    Base.remove_linenums!(ex)

    # Call RuntimeGeneratedFunction on this, so we can directly use it
    core = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(cache_module, target_module, ex)
    return GeneratedOutputInterpreter(core)
end


"""
    build_match_cases_stateful(grammar; target_module=@__MODULE__, state_name=:state, max_steps=1000)

Build guarded return branches for a state-threading interpreter over
`HerbCore.AbstractRuleNode`s.

The generated code assumes a function body with local variables

    r = HerbCore.get_rule(prog)
    c = HerbCore.get_children(prog)

and returns expressions of the form

    r == k && return <rhs>

Semantics:
- nonterminals recurse as `self(self, c[i], state)`
- sequencing `(A; B)` threads state left-to-right
- `IF(cond, t, f)` and `WHILE(cond, body)` are handled specially
- ordinary named calls in DSL rules receive `state` implicitly
- lambda bodies are rewritten as pure expressions, with bound variables
  tracked so they are not mistaken for globals or nonterminals

`target_module` is the module in which terminal symbols and primitive
functions are resovled, `state_name` is the threaded state variable name,
and `max_steps` bounds generated `WHILE` loops.
"""
function build_match_cases_stateful(
    grammar::AbstractGrammar;
    target_module::Module = @__MODULE__,
    state_name::Symbol = :state,
    max_steps::Int = 1000,
)
    branches = Expr[]

    nonterminals = Set{Symbol}(t for t in grammar.types if t !== nothing)

    # recurse into i-th child with threaded state
    child_call(i) = :( self(self, c[$i], $(state_name)) )

    function emit_eval(
        x,
        next_child::Base.RefValue{Int},
        bound::Set{Symbol} = Set{Symbol}();
        implicit_state::Bool = true,
    )
        if x isa Symbol
            if x in bound
                return x
            elseif x in nonterminals
                i = next_child[]
                next_child[] += 1
                return child_call(i)
            else
                return GlobalRef(target_module, x)
            end

        elseif x isa Expr
            # sequencing: (A; B)
            if implicit_state && x.head == :block
                return :( self(self, c[2], self(self, c[1], $(state_name))) )

            elseif implicit_state && x.head == :call && x.args[1] == :(;)
                return :( self(self, c[2], self(self, c[1], $(state_name))) )

            # IF(cond, then, else)
            elseif implicit_state && x.head == :call && x.args[1] == :IF
                return :( self(self, c[1], $(state_name)) ?
                          self(self, c[2], $(state_name)) :
                          self(self, c[3], $(state_name)) )

            # WHILE(cond, body)
            elseif implicit_state && x.head == :call && x.args[1] == :WHILE
                return quote
                    local st  = $(state_name)
                    local ctr = $(max_steps)
                    while ctr > 0 && self(self, c[1], st)
                        st = self(self, c[2], st)
                        ctr -= 1
                    end
                    st
                end

            # lambda
            elseif x.head == :->
                lhs = x.args[1]
                rhs = x.args[2]

                bound2 = copy(bound)
                union!(bound2, _collect_lambda_args(lhs))

                # lambda bodies are treated as ordinary pure expressions
                return Expr(:->, lhs, emit_eval(rhs, next_child, bound2; implicit_state=false))

            # generic function call
            elseif x.head == :call
                f_raw = x.args[1]
                f = emit_eval(f_raw, next_child, bound; implicit_state=implicit_state)
                args = [emit_eval(a, next_child, bound; implicit_state=implicit_state) for a in x.args[2:end]]

                # In stateful mode, a named global call gets `state` appended.
                # This makes:
                #   inc()       -> inc(state)
                #   apply(Func) -> apply(f, state)
                #
                # But calls through lambdas / nonterminal-produced functions
                # do NOT get state appended.
                needs_state =
                    implicit_state &&
                    (f_raw isa Symbol) &&
                    !(f_raw in bound) &&
                    !(f_raw in nonterminals)

                return needs_state ?
                    Expr(:call, f, args..., state_name) :
                    Expr(:call, f, args...)

            else
                return Expr(
                    x.head,
                    (emit_eval(a, next_child, bound; implicit_state=implicit_state) for a in x.args)...,
                )
            end
        else
            return x
        end
    end

    for (ind, rhs_rule) in pairs(grammar.rules)
        rhs_code = nothing

        if rhs_rule isa Expr && rhs_rule.head == :call
            op   = rhs_rule.args[1]
            args = rhs_rule.args[2:end]

            pure =
                (op isa Symbol) &&
                !(op in nonterminals) &&
                op != :IF &&
                op != :WHILE &&
                op != :(;) &&
                all(a -> (a isa Symbol) && (a in nonterminals), args)

            if pure
                nargs = length(args)
                child_vals = [child_call(i) for i in 1:nargs]

                # stateful named calls receive state as final arg
                rhs_code = Expr(:call, GlobalRef(target_module, op), child_vals..., state_name)
            else
                nxt = Ref(1)
                rhs_code = emit_eval(rhs_rule, nxt)
            end

        elseif rhs_rule isa Expr
            nxt = Ref(1)
            rhs_code = emit_eval(rhs_rule, nxt)

        elseif rhs_rule isa Symbol
            if rhs_rule in nonterminals
                # alias: Start = Step, etc.
                rhs_code = child_call(1)
            else
                # bare terminal symbol is a value/function, not a stateful primitive
                rhs_code = GlobalRef(target_module, rhs_rule)
            end

        else
            rhs_code = rhs_rule
        end

        push!(branches, :( r == $(ind) && return $rhs_code ))
    end

    return branches
end

struct GeneratedStatefulInterpreter{F}
    core::F  # RuntimeGeneratedFunction
end

# single state
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, state)
    return gi.core(gi.core, prog, state)
end

# vector of states
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, states::AbstractVector)
    core = gi.core
    return core.((core,), (prog,), states)
end

# IOExample (state in :_arg_1)
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, ex::HerbSpecification.IOExample)
    return gi(prog, ex.in[:_arg_1])
end

# vector of IOExamples
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, exs::AbstractVector{<:HerbSpecification.IOExample})
    return [gi(prog, ex) for ex in exs]
end


"""
    make_stateful_interpreter(grammar::AbstractGrammar;
        target_module::Module = @__MODULE__,
        cache_module::Module  = HerbInterpret,
    )

Build a fast runtime-generated interpreter for state-threading DSLs over
`HerbCore.AbstractRuleNode`s.

The returned `GeneratedStatefulInterpreter` supports:

- `interp(prog, state)`
- `interp(prog, states::AbstractVector)`
- `interp(prog, ex::HerbSpecification.IOExample)` using `ex.in[:_arg_1]`
- `interp(prog, exs::AbstractVector{<:HerbSpecification.IOExample})`

The interpreter threads state through recursive child evaluation, supports
sequencing, conditionals, and bounded `WHILE` loops, and resolves grammar
primitives in `target_module`.

`cache_module` is the module used by `RuntimeGeneratedFunctions.jl` for its
internal cache and must be initialized with
`RuntimeGeneratedFunctions.init(@__MODULE__)` at module top level.
"""
function make_stateful_interpreter(
        grammar::AbstractGrammar;
        target_module::Module = @__MODULE__,
        cache_module::Module  = HerbInterpret,
    )
    # IMPORTANT: cache_module must be initialized at module top-level.
    RuntimeGeneratedFunctions.init(cache_module)

    branches = build_match_cases_stateful(grammar;
        target_module = target_module,
        state_name    = :state
    )

    cascade = Expr(:block, branches..., :(error("No matching rule index: ", r)))

    # RGF body is an anonymous function. We add `self` for recursion.
    ex = :(function (self, prog, state)
        r = HerbCore.get_rule(prog)
        c = HerbCore.get_children(prog)
        $cascade
    end)
    Base.remove_linenums!(ex)

    core = RuntimeGeneratedFunctions.RuntimeGeneratedFunction(cache_module, target_module, ex)
    return GeneratedStatefulInterpreter(core)
end
