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
    build_match_cases(grammar; target_module=@__MODULE__, input_symbols=nothing, self_name=:self)

Return a vector of "guarded return" branches of the form:

    r == k && return <rhs>

These branches are intended to be spliced into a block after
`r = get_rule(prog); c = get_children(prog)`, inside a function named
`self_name` (so that recursive calls `self_name(c[i], input)` refer to that
function directly, rather than threading a `self` callable through every
call as an extra argument).

Returns a vector of branching expressions.
"""
function build_match_cases(
    grammar::AbstractGrammar;
    target_module::Module = @__MODULE__,
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
    self_name::Symbol = :self,
)
    input_set = input_symbols === nothing ? nothing : Set(input_symbols)

    # recurse on child i as: <self_name>(c[i], input)
    recur(i) = :( $(self_name)(c[$i], input) )

    # Emit code to evaluate a rule RHS, consuming children c[i] for nonterminals.
    function emit_eval(x, next_child::Base.RefValue{Int})
        if x isa Symbol
            if x in grammar.types
                i = next_child[]
                next_child[] += 1
                return recur(i)
            elseif _is_input_tag(x, input_set)
                return :( input[$(QuoteNode(x))] )
            else
                return GlobalRef(target_module, x)
            end
        elseif x isa Expr
            if x.head == :call
                f = _qualify(target_module, x.args[1])
                args = [emit_eval(a, next_child) for a in x.args[2:end]]
                return Expr(:call, f, args...)
            elseif x.head == :if
                cond = emit_eval(x.args[1], next_child)
                tbr  = emit_eval(x.args[2], next_child)
                fbr  = emit_eval(x.args[3], next_child)
                return Expr(:if, cond, tbr, fbr)
            else
                return Expr(x.head, (emit_eval(a, next_child) for a in x.args)...)
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
                all(a -> (a isa Symbol) && (a in grammar.types), args)

            if pure
                nargs = length(args)
                child_vals = [recur(i) for i in 1:nargs]
                rhs_code = Expr(:call, _qualify(target_module, op), child_vals...)
            else
                nxt = Ref(1)
                rhs_code = emit_eval(rhs_rule, nxt)
            end

        elseif rhs_rule isa Expr && rhs_rule.head == :if
            nxt = Ref(1)
            rhs_code = emit_eval(rhs_rule, nxt)

        elseif rhs_rule isa Symbol
            if rhs_rule in grammar.types
                rhs_code = recur(1)  # Start = Number  etc.
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

# Single input
#
# `gi.core` is a genuinely named, self-recursive function defined via `Core.eval`
# (see `make_interpreter`), not a `RuntimeGeneratedFunctions`-backed callable that
# threads `self` through every node. `invokelatest` is therefore only needed here,
# once, to cross the world-age boundary into freshly-`eval`'d code; every recursive
# call inside `gi.core`'s own body resolves itself by name at the (already current)
# world age, so it pays no further dynamic-dispatch tax per AST node.
function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   input::AbstractDict{Symbol,Any})
    return Base.invokelatest(gi.core, prog, input)
end

# Vector of inputs
function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   inputs::AbstractVector{<:AbstractDict{Symbol,Any}})
    return [Base.invokelatest(gi.core, prog, input) for input in inputs]
end

function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   ex::HerbSpecification.IOExample)
    return gi(prog, ex.in)
end

function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   exs::AbstractVector{<:HerbSpecification.IOExample})
    return [gi(prog, ex) for ex in exs]
end


"""
    make_interpreter(grammar::AbstractGrammar; input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing, target_module::Module = @__MODULE__, cache_module::Module = HerbInterpret)


Construct a fast, *runtime-generated* interpreter for programs represented as
`HerbCore.AbstractRuleNode`s.

The returned value is a callable `GeneratedInterpreter` (a small wrapper around a
genuinely named, self-recursive function defined via `Core.eval`) that can be
applied to:

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

- `input_symbols`: Optional list of symbols that should be interpreted as *inputs*.  If provided, terminals matching these symbols (and any symbol following the `_arg_` convention) are read from the `input` dict.

- `target_module`: Module in which operator/function symbols appearing in the grammar are resolved. This is important when the grammar uses domain-specific primitives (e.g. `concat_cvc`, `substr_cvc`) that are defined in a benchmark module rather than in the caller’s module.

- `cache_module`: Module in which the generated function is defined (via `Core.eval`).
"""
function make_interpreter(grammar::AbstractGrammar;
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
    target_module::Module = @__MODULE__,
    cache_module::Module = HerbInterpret
)
    # A gensym'd name, not a `self` parameter threaded through every call: this
    # lets the generated function recurse on itself directly (a normal,
    # specializable Julia call), instead of paying a world-age dynamic-dispatch
    # tax on every single AST node. See `GeneratedInterpreter`'s call operators.
    fname = gensym(:herb_interpret)

    # build if-then-else statements to evaluate the expressions
    branches = build_match_cases(grammar;
        target_module = target_module,
        input_symbols = input_symbols,
        self_name = fname,
    )

    # Add error for non-existent indices
    cascade = Expr(:block, branches..., :(error("No matching rule index: ", r)))

    ex = :(function $(fname)(prog, input)
        r = HerbCore.get_rule(prog)
        c = HerbCore.get_children(prog)
        $cascade
    end)
    Base.remove_linenums!(ex)

    # `Core.eval` returns the function object itself, already resolved at the
    # current world age -- unlike a separate `getfield(cache_module, fname)`
    # right after, which (on Julia >=1.12) would itself be a world-age-sensitive
    # global-binding read performed from this (older) frame.
    core = Core.eval(cache_module, ex)
    return GeneratedInterpreter(core)
end


"""
    build_match_cases_stateful(grammar; target_module=@__MODULE__, state_name=:state, self_name=:self)

Like `build_match_cases`, but emits code for a state-threading interpreter body:
- recursion is expressed as `<self_name>(child, state)` (a direct, named call --
  see `make_stateful_interpreter`)
- `WHILE` is inlined (bounded by `max_steps`) to avoid needing external helpers
"""
function build_match_cases_stateful(
        grammar::AbstractGrammar;
        target_module::Module = @__MODULE__,
        state_name::Symbol = :state,
        self_name::Symbol = :self,
    )
    branches = Expr[]
    max_steps=1000

    # recurse into i-th child with threaded state
    child_call(i) = :( $(self_name)(c[$i], $(state_name)) )

    for (ind, rhs_rule) in pairs(grammar.rules)
        rhs_code = nothing

        if rhs_rule isa Expr
            if rhs_rule.head == :block
                # (A; B) sequencing
                rhs_code = :( $(self_name)(c[2], $(self_name)(c[1], $(state_name))) )

            elseif rhs_rule.head == :call && rhs_rule.args[1] == :(;)
                # alternative encoding of sequencing
                rhs_code = :( $(self_name)(c[2], $(self_name)(c[1], $(state_name))) )

            elseif rhs_rule.head == :call && rhs_rule.args[1] == :IF
                rhs_code = :( $(self_name)(c[1], $(state_name)) ?
                              $(self_name)(c[2], $(state_name)) :
                              $(self_name)(c[3], $(state_name)) )

            elseif rhs_rule.head == :call && rhs_rule.args[1] == :WHILE
                # Inline a bounded while-loop:
                # WHILE(cond, body)
                rhs_code = quote
                    local st  = $(state_name)
                    local ctr = $(max_steps)
                    while ctr > 0 && $(self_name)(c[1], st)
                        st = $(self_name)(c[2], st)
                        ctr -= 1
                    end
                    st
                end

            elseif rhs_rule.head == :call
                f    = rhs_rule.args[1]
                args = rhs_rule.args[2:end]

                # Most stateful primitives are 0-arg: inc(), moveRight(), etc.
                if isempty(args)
                    rhs_code = Expr(:call, _qualify(target_module, f), state_name)
                else
                    # For calls with nonterminals, interpret children and pass results
                    nargs      = length(args)
                    child_vals = [child_call(i) for i in 1:nargs]
                    rhs_code   = Expr(:call, _qualify(target_module, f), child_vals...)
                end
            else
                # fallback: forward to first child
                rhs_code = :( $(self_name)(c[1], $(state_name)) )
            end

        elseif rhs_rule isa Symbol
            if rhs_rule in grammar.types
                # Alias: Start = Sequence, etc.
                rhs_code = :( $(self_name)(c[1], $(state_name)) )
            else
                # Rare: terminal symbol treated as primitive on state
                rhs_code = Expr(:call, _qualify(target_module, rhs_rule), state_name)
            end

        else
            # literal terminal
            rhs_code = rhs_rule
        end

        push!(branches, :( r == $(ind) && return $rhs_code ))
    end

    return branches
end


struct GeneratedStatefulInterpreter{F}
    core::F
end

# single state
#
# See `GeneratedInterpreter`: `gi.core` recurses on itself by name, so
# `invokelatest` is only needed once here, not per AST node.
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, state)
    return Base.invokelatest(gi.core, prog, state)
end

# vector of states
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, states::AbstractVector)
    return [Base.invokelatest(gi.core, prog, state) for state in states]
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
    make_stateful_interpreter(grammar; target_module=@__MODULE__, cache_module=HerbInterpret, max_steps=1000)

Build a state-threading interpreter, defined via `Core.eval` as a genuinely
named, self-recursive function (see `make_interpreter`).

- `target_module` controls where primitives (inc, moveRight, etc.) are resolved.
- `cache_module` controls the module in which the generated function is defined.
- `max_steps` bounds generated WHILE loops.
"""
function make_stateful_interpreter(
        grammar::AbstractGrammar;
        target_module::Module = @__MODULE__,
        cache_module::Module  = HerbInterpret,
    )
    fname = gensym(:herb_interpret_stateful)

    branches = build_match_cases_stateful(grammar;
        target_module = target_module,
        state_name    = :state,
        self_name     = fname,
    )

    cascade = Expr(:block, branches..., :(error("No matching rule index: ", r)))

    ex = :(function $(fname)(prog, state)
        r = HerbCore.get_rule(prog)
        c = HerbCore.get_children(prog)
        $cascade
    end)
    Base.remove_linenums!(ex)

    # `Core.eval` returns the function object itself, already resolved at the
    # current world age -- unlike a separate `getfield(cache_module, fname)`
    # right after, which (on Julia >=1.12) would itself be a world-age-sensitive
    # global-binding read performed from this (older) frame.
    core = Core.eval(cache_module, ex)
    return GeneratedStatefulInterpreter(core)
end
