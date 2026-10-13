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
    _child(i::Int)

`c[i]`, asserted to be a `RuleNode`.

The generated interpreters evaluate *complete* programs; `HerbCore.get_children`
is typed to return `Vector{AbstractRuleNode}` so that partially-built trees
(`Hole`s) can share the same container during search, but that abstract element
type is exactly what defeats type inference on the recursive call below --
without this assertion, the recursive call's inferred return type (and hence
every *other* call to the same function) widens to `Any`, which costs an
allocation and a dynamic dispatch at *every* node, not just the children's.
Asserting the concrete type here is what lets Julia specialize and inline the
whole recursive cascade for a given grammar.

A `Hole` (or `UniformHole`) reaching this point raises a `TypeError` rather than
silently producing nonsense -- evaluating an incomplete choice has no defined
meaning anyway, and failing fast on it is preferable to guessing.
"""
_child(i::Int) = :( c[$i]::RuleNode )

"""
    _access_input(x::Symbol)

Read input symbol `x` from the (`NamedTuple`-typed, see [`GeneratedInterpreter`](@ref))
`input` binding. Compiles to a direct, type-stable field load rather than a
`Dict` lookup.
"""
_access_input(x::Symbol) = Expr(:., :input, QuoteNode(x))


"""
    build_match_cases(grammar; target_module=@__MODULE__, input_symbols=nothing)

Return `(by_type, names)`:

- `by_type::Dict{Symbol,Vector{Pair{Int,Any}}}`: for each nonterminal of
  `grammar` that owns at least one (non-removed) rule, its `rule_index =>
  rhs_code` pairs, in ascending rule-index order. Each nonterminal's rules are
  meant to become *its own* generated function (see [`make_interpreter`](@ref)
  and [`build_dispatch`](@ref)) rather than all being spliced into one -- a
  single recursive function serving every nonterminal has no way to keep its
  inferred return type narrower than the union of *all* of them put together
  (concretely: `Union{Int, Vector{Int}, Bool, ...}`, which Julia's inference
  gives up on and widens to `Any`), whereas one function per nonterminal is
  exactly as narrow as that nonterminal's own rules make it -- typically a
  single concrete type, since a well-formed grammar is "sorted" (every rule
  under one nonterminal produces the same kind of value).
- `names`: every input symbol the branches read (in first-seen order), i.e.
  every symbol that satisfies [`_is_input_tag`](@ref) anywhere in the grammar.
  This is exactly the set of fields the `input` `NamedTuple` must have for the
  generated code to run; see [`GeneratedInterpreter`](@ref).

A recursive reference to a child of nonterminal `nt` at position `i` compiles
to `getfield(selves, QuoteNode(nt))(selves, c[i]::RuleNode, input)`, where
`selves` is the `NamedTuple` of all the per-nonterminal functions (see
[`make_interpreter`](@ref)) -- the generalisation of the old single
self-referential function to a mutually-recursive family, one member per
nonterminal.
"""
function build_match_cases(
    grammar::AbstractGrammar;
    target_module::Module = @__MODULE__,
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
)
    input_set = input_symbols === nothing ? nothing : Set(input_symbols)
    names = Symbol[]

    # recurse into child i, whose nonterminal type is `nt`
    recur(nt::Symbol, i::Int) =
        :( getfield(selves, $(QuoteNode(nt)))(selves, $(_child(i)), input) )

    read_input(x::Symbol) = (x in names || push!(names, x); _access_input(x))

    # Emit code to evaluate a rule RHS, consuming children c[i] for nonterminals.
    function emit_eval(x, next_child::Base.RefValue{Int})
        if x isa Symbol
            if x in grammar.types
                i = next_child[]
                next_child[] += 1
                return recur(x, i)
            elseif _is_input_tag(x, input_set)
                return read_input(x)
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

    by_type = Dict{Symbol,Vector{Pair{Int,Any}}}()

    for (ind, rhs_rule) in pairs(grammar.rules)
        nt = grammar.types[ind]
        nt === nothing && continue  # removed rule: no longer reachable, nothing to generate

        rhs_code = nothing

        if rhs_rule isa Expr && rhs_rule.head == :call
            op   = rhs_rule.args[1]
            args = rhs_rule.args[2:end]

            pure =
                (op isa Symbol) &&
                all(a -> (a isa Symbol) && (a in grammar.types), args)

            if pure
                child_vals = [recur(args[i], i) for i in eachindex(args)]
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
                rhs_code = recur(rhs_rule, 1)  # Start = Number  etc.
            elseif _is_input_tag(rhs_rule, input_set)
                rhs_code = read_input(rhs_rule)
            else
                rhs_code = GlobalRef(target_module, rhs_rule)
            end

        else
            rhs_code = rhs_rule
        end

        push!(get!(() -> Pair{Int,Any}[], by_type, nt), ind => rhs_code)
    end

    return by_type, Tuple(names)
end

"""
    build_dispatch(branches::AbstractVector{Pair{Int,Any}})

Turns `rule_index => rhs_code` pairs (as [`build_match_cases`](@ref)/
[`build_match_cases_stateful`](@ref) produce them for one nonterminal's bucket)
into the `Expr` that dispatches on `r`: a flat cascade `r == i1 && return e1; r
== i2 && return e2; ...`.

A balanced binary search over the sorted indices was tried here too, on the
theory that `O(log n)` comparisons should beat this cascade's up-to-`O(n)` once
a nonterminal has enough rules (DeepCoder's `ExprArr` has 20+). Measured, it
lost consistently (regressions across every benchmark, worse at every depth) --
the flat cascade's branches are cheap, uniform, well-predicted compares that
the compiler already turns into efficient code, while the tree's nested
`if/elseif` adds real per-level overhead (two comparisons instead of one, worse
control flow for the optimizer) that the saved comparisons never paid back at
these rule counts (a few dozen at most, so `log2(n)` is only a factor of 2-3
off from `n`, not enough to win). Kept as the flat cascade on that evidence;
measure again with `benchmark/run.jl` before trying this direction again.
"""
function build_dispatch(branches::AbstractVector{Pair{Int,Any}})
    guards = [:( r == $ind && return $rhs_code ) for (ind, rhs_code) in branches]
    return Expr(:block, guards..., :(error("No matching rule index: ", r)))
end


"""
    GeneratedInterpreter{Selves,Names}

`Selves` is a `NamedTuple{nonterminals}` of one `RuntimeGeneratedFunction` per
nonterminal of the grammar (see [`build_match_cases`](@ref)); each is called as
`f(selves, prog, input)` and can recurse into any of its siblings (including
itself) through `selves`, which is threaded through unchanged -- the same
self-reference trick a single function would use, generalised to a mutually
recursive family.

`types` is the grammar's own `types` vector, kept so that a top-level call can
look up which member of `selves` a given `prog` has to start at (`prog` need
not be of the nonterminal the grammar calls `Start`; whichever nonterminal
`HerbCore.get_rule(prog)` belongs to is used).

`Names` is the `Tuple` of input symbols the generated bodies read, carried as a
type parameter so that converting an input `Dict` to a `NamedTuple` (see
[`_as_namedtuple`](@ref)) can be specialized for it rather than discovering the
field names at every call.
"""
struct GeneratedInterpreter{Selves,Names}
    selves::Selves
    types::Vector{Union{Nothing,Symbol}}
end

GeneratedInterpreter(selves::Selves, types::AbstractVector, names::Tuple{Vararg{Symbol}}) where {Selves} =
    GeneratedInterpreter{Selves,names}(selves, types)

"""
    _as_namedtuple(input::AbstractDict{Symbol}, ::Val{names}) where names

Converts an input `Dict` to a `NamedTuple` with the given field `names`, read
directly out of `input` (`NamedTuple{names}((input[names[1]], input[names[2]], ...))`).

The generated interpreter bodies read each input symbol as a field access
(`input.x`, see [`_access_input`](@ref)), which is only type-stable -- and
therefore only avoids boxing every value coming out of the dict as `Any` -- when
`input` itself is concretely typed. A `Dict{Symbol,Any}` can never be that,
regardless of what it actually holds, so it is converted once per call here,
outside the recursion, rather than looked up by key at every node.

Knowing `names` ahead of time (rather than reading them off the dict via
`keys`/`values`, which are not known-length and so go through a slower, more
allocating generic conversion) is most of what makes this cheap: on a 2-entry
dict this runs in ~60ns/2 allocations against ~300ns/10 allocations for the
`keys`/`values` route, and it is paid once per `(program, example)` pair.
"""
@generated function _as_namedtuple(input::AbstractDict{Symbol}, ::Val{names}) where {names}
    accesses = [:(input[$(QuoteNode(n))]) for n in names]
    return :( NamedTuple{$names}(($(accesses...),)) )
end
_as_namedtuple(input::NamedTuple, ::Val) = input  # already converted, e.g. by a caller that reuses one

"""
    _start_function(gi::GeneratedInterpreter, prog)

The member of `gi.selves` that handles `prog`'s own nonterminal. Only this
single lookup, done once per top-level call rather than once per node, is a
dynamic (`Symbol`-keyed) dispatch; see [`GeneratedInterpreter`](@ref).
"""
_start_function(gi::GeneratedInterpreter, prog::HerbCore.AbstractRuleNode) =
    getfield(gi.selves, gi.types[HerbCore.get_rule(prog)]::Symbol)

# Single input
function (gi::GeneratedInterpreter{Selves,Names})(prog::HerbCore.AbstractRuleNode,
                                   input::AbstractDict{Symbol,Any}) where {Selves,Names}
    f = _start_function(gi, prog)
    return f(gi.selves, prog, _as_namedtuple(input, Val(Names)))
end

# Vector of inputs
function (gi::GeneratedInterpreter{Selves,Names})(prog::HerbCore.AbstractRuleNode,
                                   inputs::AbstractVector{<:AbstractDict{Symbol,Any}}) where {Selves,Names}
    f = _start_function(gi, prog)
    selves = gi.selves
    val = Val(Names)
    return [f(selves, prog, _as_namedtuple(input, val)) for input in inputs]
end

# Already-`prepare_input`-ed input(s): no conversion left to do. This is the
# fast path a search loop should use -- see `prepare_input`.
function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode, input::NamedTuple)
    f = _start_function(gi, prog)
    return f(gi.selves, prog, input)
end

function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode, inputs::AbstractVector{<:NamedTuple})
    f = _start_function(gi, prog)
    selves = gi.selves
    return [f(selves, prog, input) for input in inputs]
end

"""
    prepare_input(gi::GeneratedInterpreter, input)

Converts `input` (an `AbstractDict{Symbol,Any}`, an `IOExample`, or a vector of
either) to the `NamedTuple` form `gi` actually reads from, once.

Program synthesis evaluates many candidate programs against the same fixed set
of examples; calling `gi(prog, input)` directly repeats the dict/example ->
`NamedTuple` conversion (see [`_as_namedtuple`](@ref)) on every single one of
them, even though `input` never changes. Converting once with this function and
passing the result to `gi(prog, ...)` for every candidate skips that repeated
cost entirely -- `gi` dispatches on the already-converted `NamedTuple` directly.
"""
prepare_input(gi::GeneratedInterpreter{Selves,Names}, input::AbstractDict{Symbol,Any}) where {Selves,Names} =
    _as_namedtuple(input, Val(Names))
prepare_input(gi::GeneratedInterpreter, ex::HerbSpecification.IOExample) = prepare_input(gi, ex.in)
prepare_input(gi::GeneratedInterpreter, inputs::AbstractVector{<:AbstractDict{Symbol,Any}}) =
    [prepare_input(gi, input) for input in inputs]
prepare_input(gi::GeneratedInterpreter, exs::AbstractVector{<:HerbSpecification.IOExample}) =
    [prepare_input(gi, ex) for ex in exs]

function (gi::GeneratedInterpreter)(prog::HerbCore.AbstractRuleNode,
                                   ex::HerbSpecification.IOExample)
    return gi(prog, ex.in)
end

# Vector of IOExamples: this is what `take_examples`-style `Vector{<:IOExample}`
# inputs actually go through (not the `AbstractDict` vector overload above), so
# it gets the same treatment: `_start_function` and `Val(Names)` computed once
# for the whole vector rather than once per example via a doubly-indirected
# `gi(prog, ex)` -> `gi(prog, ex.in)` call chain.
function (gi::GeneratedInterpreter{Selves,Names})(prog::HerbCore.AbstractRuleNode,
                                   exs::AbstractVector{<:HerbSpecification.IOExample}) where {Selves,Names}
    f = _start_function(gi, prog)
    selves = gi.selves
    val = Val(Names)
    return [f(selves, prog, _as_namedtuple(ex.in, val)) for ex in exs]
end


"""
    make_interpreter(grammar::AbstractGrammar; input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing, target_module::Module = @__MODULE__, cache_module::Module = HerbInterpret)


Construct a fast, *runtime-generated* interpreter for programs represented as
`HerbCore.AbstractRuleNode`s.

The returned value is a callable `GeneratedInterpreter` (a thin wrapper around
one `RuntimeGeneratedFunctions.RuntimeGeneratedFunction` per nonterminal of
`grammar`, see [`build_match_cases`](@ref)) that can be applied to:

- a single input dictionary:
  `interp(prog, input::AbstractDict{Symbol,Any})`
- a vector of input dictionaries:
  `interp(prog, inputs::AbstractVector{<:AbstractDict{Symbol,Any}})`
- a single `HerbSpecification.IOExample`:
  `interp(prog, ex::IOExample)` (uses `ex.in`)
- a vector of `IOExample`s:
  `interp(prog, exs::AbstractVector{<:IOExample})`

Each input dictionary is converted to a `NamedTuple` once per call (see
[`_as_namedtuple`](@ref)) before the recursive evaluation starts; the generated
bodies then read inputs as field accesses rather than `Dict` lookups. Together
with generating one function per nonterminal instead of one for the whole
grammar (so each one's return type is whatever its own rules produce, usually a
single concrete type, rather than the union of every nonterminal's), this is
what lets the whole recursive cascade compile to concretely-typed code instead
of boxing every value as `Any`.

`prog` (and every node reached while evaluating it) must be a `RuleNode` --
`Hole`s represent an undetermined choice among the grammar's rules, which has no
defined evaluation semantics, and the generated code asserts the concrete type
to stay fast rather than silently guessing; a `Hole` reaching the interpreter
raises a `TypeError`.

## Arguments

- `grammar`: The grammar whose rule indices define the operational semantics.
  The interpreter dispatches by `r = HerbCore.get_rule(prog)`.

## Keyword arguments

- `input_symbols`: Optional list of symbols that should be interpreted as *inputs*.  If provided, terminals matching these symbols (and any symbol following the `_arg_` convention) are read from the `input` dict.

- `target_module`: Module in which operator/function symbols appearing in the grammar are resolved. This is important when the grammar uses domain-specific primitives (e.g. `concat_cvc`, `substr_cvc`) that are defined in a benchmark module rather than in the caller’s module.

- `cache_module`: Module used by `RuntimeGeneratedFunctions.jl` to store its internal cache.
"""
function make_interpreter(grammar::AbstractGrammar;
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
    target_module::Module = @__MODULE__,
    cache_module::Module = HerbInterpret
)
    # ensure the cache exists in the chosen cache module
    RuntimeGeneratedFunctions.init(cache_module)

    # build if-then-else statements to evaluate the expressions, grouped by
    # which nonterminal they belong to
    by_type, names = build_match_cases(grammar;
        target_module = target_module,
        input_symbols = input_symbols
    )

    nonterminals = Tuple(sort!(collect(keys(by_type))))  # any fixed order; just needs to be consistent

    cores = map(nonterminals) do nt
        cascade = build_dispatch(by_type[nt])
        # Constructs an anonymous function with an extra `selves` arg for
        # recursion into itself or into any sibling nonterminal's function.
        ex = :(function (selves, prog, input)
            r = HerbCore.get_rule(prog)
            c = HerbCore.get_children(prog)
            $cascade
        end)
        Base.remove_linenums!(ex)
        RuntimeGeneratedFunctions.RuntimeGeneratedFunction(cache_module, target_module, ex)
    end

    selves = NamedTuple{nonterminals}(cores)
    return GeneratedInterpreter(selves, grammar.types, names)
end


"""
    build_match_cases_stateful(grammar; target_module=@__MODULE__, state_name=:state)

Like [`build_match_cases`](@ref), but for the state-threading convention
`make_stateful_interpreter` uses (`Transformation = moveRight()` really means
`moveRight(state)`, and `IF`/`WHILE` thread `state` through their branches).
Returns `by_type::Dict{Symbol,Vector{Expr}}`, one entry per nonterminal, for
the same reason `build_match_cases` does: a single recursive function serving
every nonterminal can only ever be inferred as narrowly as the union of all of
their return types (e.g. `Union{RobotState,Bool}` for a grammar whose
`Condition`s return `Bool` and everything else returns the state type), which
Julia abandons as `Any`, whereas one function per nonterminal is exactly as
narrow as that nonterminal's own rules make it.

`WHILE` is inlined (bounded by 1000 iterations) to avoid needing external
helpers.
"""
function build_match_cases_stateful(
        grammar::AbstractGrammar;
        target_module::Module = @__MODULE__,
        state_name::Symbol = :state,
    )
    by_type = Dict{Symbol,Vector{Pair{Int,Any}}}()
    max_steps = 1000

    # recurse into child i, whose nonterminal type is `nt`, with threaded state
    # (see `_child` for why the type assertion on c[i] matters here)
    call_nt(nt::Symbol, i::Int, state_expr) =
        :( getfield(selves, $(QuoteNode(nt)))(selves, $(_child(i)), $(state_expr)) )
    child_call(nt::Symbol, i::Int) = call_nt(nt, i, state_name)

    for (ind, rhs_rule) in pairs(grammar.rules)
        nt = grammar.types[ind]
        nt === nothing && continue  # removed rule

        rhs_code = nothing

        if rhs_rule isa Expr
            if rhs_rule.head == :block
                # (A; B) sequencing -- rhs_rule.args are the two child nonterminals
                a, b = rhs_rule.args[1], rhs_rule.args[2]
                rhs_code = :( getfield(selves, $(QuoteNode(b)))(selves,
                                $(_child(2)),
                                $(child_call(a, 1))) )

            elseif rhs_rule.head == :call && rhs_rule.args[1] == :(;)
                # alternative encoding of sequencing
                a, b = rhs_rule.args[2], rhs_rule.args[3]
                rhs_code = :( getfield(selves, $(QuoteNode(b)))(selves,
                                $(_child(2)),
                                $(child_call(a, 1))) )

            elseif rhs_rule.head == :call && rhs_rule.args[1] == :IF
                cond_nt, then_nt, else_nt = rhs_rule.args[2], rhs_rule.args[3], rhs_rule.args[4]
                rhs_code = :( $(child_call(cond_nt, 1)) ?
                              $(child_call(then_nt, 2)) :
                              $(child_call(else_nt, 3)) )

            elseif rhs_rule.head == :call && rhs_rule.args[1] == :WHILE
                # Inline a bounded while-loop:
                # WHILE(cond, body)
                #
                # Both cond and body must be re-evaluated against the
                # accumulating loop-local `st`, not the function's incoming
                # `state_name` -- that incoming value never changes, so using
                # it here (as `child_call` does everywhere else) would check
                # the *original* condition forever and recompute the *same*
                # one-step body result on every iteration.
                cond_nt, body_nt = rhs_rule.args[2], rhs_rule.args[3]
                rhs_code = quote
                    local st  = $(state_name)
                    local ctr = $(max_steps)
                    while ctr > 0 && $(call_nt(cond_nt, 1, :st))
                        st = $(call_nt(body_nt, 2, :st))
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
                    child_vals = [child_call(args[i], i) for i in eachindex(args)]
                    rhs_code   = Expr(:call, _qualify(target_module, f), child_vals...)
                end
            else
                # fallback: forward to first child, whatever nonterminal it is
                rhs_code = child_call(only(rhs_rule.args), 1)
            end

        elseif rhs_rule isa Symbol
            if rhs_rule in grammar.types
                # Alias: Start = Sequence, etc.
                rhs_code = child_call(rhs_rule, 1)
            else
                # Rare: terminal symbol treated as primitive on state
                rhs_code = Expr(:call, _qualify(target_module, rhs_rule), state_name)
            end

        else
            # literal terminal
            rhs_code = rhs_rule
        end

        push!(get!(() -> Pair{Int,Any}[], by_type, nt), ind => rhs_code)
    end

    return by_type
end


"""
    GeneratedStatefulInterpreter{Selves}

The state-threading analogue of [`GeneratedInterpreter`](@ref): `selves` is a
`NamedTuple{nonterminals}` of one `RuntimeGeneratedFunction` per nonterminal
(see [`build_match_cases_stateful`](@ref)), and `types` is the grammar's own
`types` vector, used to find which member of `selves` a given `prog` has to
start at.
"""
struct GeneratedStatefulInterpreter{Selves}
    selves::Selves
    types::Vector{Union{Nothing,Symbol}}
end

_start_function(gi::GeneratedStatefulInterpreter, prog::HerbCore.AbstractRuleNode) =
    getfield(gi.selves, gi.types[HerbCore.get_rule(prog)]::Symbol)

# single state
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, state)
    f = _start_function(gi, prog)
    return f(gi.selves, prog, state)
end

# vector of states
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, states::AbstractVector)
    f = _start_function(gi, prog)
    selves = gi.selves
    return [f(selves, prog, state) for state in states]
end

# IOExample (state in :_arg_1)
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, ex::HerbSpecification.IOExample)
    return gi(prog, ex.in[:_arg_1])
end

# vector of IOExamples -- `_start_function` computed once for the whole
# vector rather than once per example via a doubly-indirected `gi(prog, ex)`
# -> `gi(prog, ex.in[:_arg_1])` call chain.
function (gi::GeneratedStatefulInterpreter)(prog::HerbCore.AbstractRuleNode, exs::AbstractVector{<:HerbSpecification.IOExample})
    f = _start_function(gi, prog)
    selves = gi.selves
    return [f(selves, prog, ex.in[:_arg_1]) for ex in exs]
end


"""
    make_stateful_interpreter(grammar; target_module=@__MODULE__, cache_module=HerbInterpret)

Build a RuntimeGeneratedFunctions-backed state-threading interpreter: one
function per nonterminal of `grammar` (see [`build_match_cases_stateful`](@ref)
for why), each able to recurse into any of them (including itself) through a
shared `selves` `NamedTuple`.

- `target_module` controls where primitives (inc, moveRight, etc.) are resolved.
- `cache_module` controls where RGF stores its cache. **This module must have**
  `RuntimeGeneratedFunctions.init(@__MODULE__)` executed at module top level.

Bounds generated `WHILE` loops at 1000 iterations.

As with [`make_interpreter`](@ref), every node of `prog` must be a `RuleNode`;
a `Hole` raises a `TypeError` rather than being silently misinterpreted.
"""
function make_stateful_interpreter(
        grammar::AbstractGrammar;
        target_module::Module = @__MODULE__,
        cache_module::Module  = HerbInterpret,
    )
    # IMPORTANT: cache_module must be initialized at module top-level.
    RuntimeGeneratedFunctions.init(cache_module)

    by_type = build_match_cases_stateful(grammar;
        target_module = target_module,
        state_name    = :state
    )

    nonterminals = Tuple(sort!(collect(keys(by_type))))

    cores = map(nonterminals) do nt
        cascade = build_dispatch(by_type[nt])

        # RGF body is an anonymous function. We add `selves` for recursion into
        # itself or into any sibling nonterminal's function.
        ex = :(function (selves, prog, state)
            r = HerbCore.get_rule(prog)
            c = HerbCore.get_children(prog)
            $cascade
        end)
        Base.remove_linenums!(ex)
        RuntimeGeneratedFunctions.RuntimeGeneratedFunction(cache_module, target_module, ex)
    end

    selves = NamedTuple{nonterminals}(cores)
    return GeneratedStatefulInterpreter(selves, grammar.types)
end
