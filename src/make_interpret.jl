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
    _collect_lambda_args(lhs)

Return the flat list of variables bound by a lambda's argument list `lhs`.

Supports plain symbols (`x`), tuples (`(x, y)`), type annotations (`x::T`),
and varargs (`x...`), in any combination (e.g. `(x::Int, ys...)`).
Rejects zero-argument lambdas, destructuring patterns, and keyword-style
parameters.
"""
function _collect_lambda_args(lhs)
    if lhs isa Symbol
        return Symbol[lhs]
    elseif lhs isa Expr
        if lhs.head == :(::)
            return _collect_lambda_args(lhs.args[1])
        elseif lhs.head == :...
            return _collect_lambda_args(lhs.args[1])
        elseif lhs.head == :tuple && !isempty(lhs.args) &&
               all(a -> a isa Symbol || (a isa Expr && a.head in (:(::), :...)), lhs.args)
            return Symbol[s for a in lhs.args for s in _collect_lambda_args(a)]
        end
    end
    throw(ArgumentError("Unsupported lambda argument syntax: $lhs"))
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

Grammar rules may contain lambdas (e.g. `Func = x -> Func(x) + 1`); their
argument variables are tracked so they resolve as plain locals rather than
as nonterminals or globals in `target_module`.

Returns a vector of branching expressions.
"""
function build_match_cases(
    grammar::AbstractGrammar;
    target_module::Module = @__MODULE__,
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
    self_name::Symbol = :self,
)
    input_set = input_symbols === nothing ? nothing : Set(input_symbols)
    nonterminals = Set{Symbol}(t for t in grammar.types if t !== nothing)

    # recurse on child i as: <self_name>(c[i], input)
    recur(i) = :( $(self_name)(c[$i], input) )

    # Emit code to evaluate a rule RHS, consuming children c[i] for nonterminals.
    # `bound` holds lambda-bound variables, checked first so they aren't
    # mistaken for nonterminals or globals.
    function emit_eval(x, next_child::Base.RefValue{Int}, bound::Set{Symbol} = Set{Symbol}())
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
            if x.head == :->
                lhs, rhs = x.args[1], x.args[2]
                bound2 = union(bound, _collect_lambda_args(lhs))
                return Expr(:->, lhs, emit_eval(rhs, next_child, bound2))
            elseif x.head == :call
                f = emit_eval(x.args[1], next_child, bound)
                args = [emit_eval(a, next_child, bound) for a in x.args[2:end]]
                return Expr(:call, f, args...)
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

# `invokelatest` crosses the world-age boundary once, here, into the
# freshly-`Core.eval`'d `gi.core`. Its recursive calls resolve themselves
# directly by name, so no further `invokelatest` is needed per AST node.
#
# Value type left unconstrained: Dict is invariant in it, so a
# `Dict{Symbol,Any}`-only signature would reject e.g. `Dict{Symbol,Int}`.
function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   input::AbstractDict{Symbol})
    return Base.invokelatest(gi.core, prog, input)
end

# Vector of inputs
function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   inputs::AbstractVector{<:AbstractDict{Symbol}})
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
self-recursive function defined via `Core.eval`) that can be applied to:

- a single input dictionary:
  `interp(prog, input::AbstractDict{Symbol})`
- a vector of input dictionaries:
  `interp(prog, inputs::AbstractVector{<:AbstractDict{Symbol}})`
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
    # Gensym'd so the generated function can recurse on itself by name,
    # as a normal, specializable Julia call.
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

    core = Core.eval(cache_module, ex)
    return GeneratedInterpreter(core)
end


"""
    build_match_cases_stateful(grammar; target_module=@__MODULE__, state_name=:state, self_name=:self)

Like `build_match_cases`, but emits code for a state-threading interpreter body:
- recursion is expressed as `<self_name>(child, state)`
- sequencing `(A; B)`, `IF(cond, t, f)` and `WHILE(cond, body)` are handled
  specially, threading `state` through
- an ordinary named call (e.g. `inc()`, `apply(Func)`) implicitly receives
  `state` as its last argument
- grammar rules may contain lambdas (e.g. `Func = x -> double(x)`); their
  bodies are pure expressions and do *not* receive `state` implicitly
"""
function build_match_cases_stateful(
        grammar::AbstractGrammar;
        target_module::Module = @__MODULE__,
        state_name::Symbol = :state,
        self_name::Symbol = :self,
    )
    branches = Expr[]
    max_steps = 1000
    nonterminals = Set{Symbol}(t for t in grammar.types if t !== nothing)

    # recurse into i-th child with threaded state
    child_call(i) = :( $(self_name)(c[$i], $(state_name)) )

    # `bound` holds lambda-bound variables. `implicit_state` is false inside
    # a lambda body, where calls are pure expressions and must not receive
    # `state` implicitly.
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
            if implicit_state && x.head == :block
                # (A; B) sequencing
                return :( $(self_name)(c[2], $(self_name)(c[1], $(state_name))) )

            elseif implicit_state && x.head == :call && x.args[1] == :(;)
                # alternative encoding of sequencing
                return :( $(self_name)(c[2], $(self_name)(c[1], $(state_name))) )

            elseif implicit_state && x.head == :call && x.args[1] == :IF
                return :( $(self_name)(c[1], $(state_name)) ?
                          $(self_name)(c[2], $(state_name)) :
                          $(self_name)(c[3], $(state_name)) )

            elseif implicit_state && x.head == :call && x.args[1] == :WHILE
                # Inline a bounded while-loop: WHILE(cond, body)
                return quote
                    local st  = $(state_name)
                    local ctr = $(max_steps)
                    while ctr > 0 && $(self_name)(c[1], st)
                        st = $(self_name)(c[2], st)
                        ctr -= 1
                    end
                    st
                end

            elseif x.head == :->
                lhs, rhs = x.args[1], x.args[2]
                bound2 = union(bound, _collect_lambda_args(lhs))
                return Expr(:->, lhs, emit_eval(rhs, next_child, bound2; implicit_state = false))

            elseif x.head == :call
                f_raw = x.args[1]
                f = emit_eval(f_raw, next_child, bound; implicit_state)
                args = [emit_eval(a, next_child, bound; implicit_state) for a in x.args[2:end]]

                # A bare, unbound, non-nonterminal callee is a named primitive in
                # `target_module`: it receives `state` as an extra argument, e.g.
                # `inc()` -> `inc(state)`, `apply(Func)` -> `apply(f, state)`.
                # Calls through lambdas or nonterminal-produced functions don't.
                needs_state = implicit_state && f_raw isa Symbol &&
                    !(f_raw in bound) && !(f_raw in nonterminals)

                return needs_state ?
                    Expr(:call, f, args..., state_name) :
                    Expr(:call, f, args...)
            else
                return Expr(x.head, (emit_eval(a, next_child, bound; implicit_state) for a in x.args)...)
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
                op !== :IF && op !== :WHILE && op !== :(;) &&
                all(a -> (a isa Symbol) && (a in nonterminals), args)

            if pure
                nargs = length(args)
                child_vals = [child_call(i) for i in 1:nargs]
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
                rhs_code = child_call(1)  # Alias: Start = Sequence, etc.
            else
                # bare terminal symbol is a value/function, not a stateful primitive call
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
    core::F
end

# See `GeneratedInterpreter`: `invokelatest` is only needed once here,
# to cross into the freshly-`Core.eval`'d `gi.core`.
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
    make_stateful_interpreter(grammar; target_module=@__MODULE__, cache_module=HerbInterpret)

Build a state-threading interpreter, defined via `Core.eval` as a
self-recursive function (see `make_interpreter`).

- `target_module` controls where primitives (inc, moveRight, etc.) are resolved.
- `cache_module` controls the module in which the generated function is defined.
- Generated `WHILE` loops are bounded to 1000 iterations.
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

    core = Core.eval(cache_module, ex)
    return GeneratedStatefulInterpreter(core)
end
