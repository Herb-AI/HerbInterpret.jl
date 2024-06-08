using Base: depwarn
"""
    test_all_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Vector{Bool}

!!! warning 
    This function is deprecated. Please use [`execute_on_input`](@ref) instead.

Runs the interpreter on all examples with the given input table and expression. 
The symbol table defines everything (functions, symbols) that are not input variables to the program to be synthesised.
Returns a list of true/false values indicating if the expression satisfies the corresponding example.
WARNING: This function throws exceptions that are caused in the given expression.
These exceptions have to be handled by the caller of this function.
"""
function test_all_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Vector{Bool}
    depwarn("`test_all_examples` is deprecated and should no longer be used.", :test_all_examples)

    outcomes = Vector{Bool}(undef, length(examples))
    for example ∈ filter(e -> e isa IOExample, examples)
        push!(outcomes, example.out == execute_on_input(tab, expr, example.in))
    end
    return outcomes
end

"""
    test_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Bool

!!! warning 
    This function is deprecated. Please use [`execute_on_input`](@ref) instead.

Evaluates all examples and returns true iff all examples pass.
Shortcircuits as soon as an example is found for which the program doesn't work. 
Returns false if one of the examples produces an error.
"""
function test_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Bool
    depwarn("`test_examples` is deprecated and should no longer be used.", :test_examples)

    for example ∈ filter(e -> e isa IOExample, examples)
        try
            output = execute_on_input(tab, expr, example.in)
            if output ≠ execute_on_input(tab, expr, example.in)
                return false
            end
        catch
            return false
        end
    end
    return true
end

@kwdef mutable struct CodePath
    code_path::BitVector
    idx::UInt8
end

angelic_condition_flag = Symbol("update_✝_angelic_path")

@kwdef mutable struct InterpArgs
    attempt_code_path::Union{CodePath,Nothing}
    actual_code_path::Union{BitVector,Nothing}
    limit_iterations::Int
    is_breaking::Bool
end

"""
    execute_on_input(tab::SymbolTable, expr::Any, input::Dict{Symbol, T}, attempt_code_path::Union{CodePath, Nothing}, actual_code_path::Union{BitVector, Nothing}, 
        limit_iterations::Int)::Any where T

Evaluates an expression `expr` within the context of a symbol table `tab` and a single input dictionary `input`. 
The input dictionary keys should match the symbols used in the expression, and their values are used during the expression's evaluation.
If provided, a code path should be attempted, and also recorded in the actual_code_path.

# Arguments
- `tab::SymbolTable`: A symbol table containing predefined symbols and their associated values or functions.
- `expr::Any`: The expression to be evaluated. Can be any Julia expression that is valid within the context of the provided symbol table and input.
- `input::Dict{Symbol, T}`: A dictionary where each key is a symbol used in the expression, and the value is the corresponding value to be used in the expression's evaluation. The type `T` can be any type.
- `attempt_code_path::Union{CodePath, Nothing}`: The attempted code path. Can be `nothing` if no code path should be attempted
- `actual_code_path::Union{BitVector, Nothing}`: The actual code path. Values from `attempt_code_path` are appended until it is empty, then only the `false` path is taken.
- `limit_iterations::Int`: The maximum number of iterations allowed for the evaluation of the expression. Used to avoid infinite loops.

# Returns
- `Any`: The result of evaluating the expression with the given symbol table and input dictionary.

!!! warning
    This function throws exceptions that are caused in the given expression. These exceptions have to be handled by the caller of this function.

"""
function execute_on_input(
    tab::SymbolTable,
    expr::Any,
    input::Dict{Symbol,T},
    attempt_code_path::Union{CodePath,Nothing}=nothing,
    actual_code_path::Union{BitVector,Nothing}=nothing,
    limit_iterations::Int=90,
)::Any where {T}
    # Add input variable values
    symbols = merge(tab, input)
    return interpret(symbols, expr, InterpArgs(attempt_code_path, actual_code_path, limit_iterations, false))
end

"""
    execute_on_input(tab::SymbolTable, expr::Any, input::Vector{T})::Vector{<:Any} where T <: Dict{Symbol, <:Any}

Wrapper around [`execute_on_input`](@ref) to execute all inputs given as an array.

# Arguments
- `tab::SymbolTable`: A symbol table containing predefined symbols and their associated values or functions.
- `expr::Any`: The expression to be evaluated for each input dictionary.
- `inputs::Vector{T}`: A vector of dictionaries, each serving as an individual set of inputs for the expression's evaluation.

# Returns
- `Vector{<:Any}`: A vector containing the results of evaluating the expression for each input dictionary.
"""
function execute_on_input(tab::SymbolTable, expr::Any, input::Vector{T})::Vector{<:Any} where {T<:Dict{Symbol,<:Any}}
    return [execute_on_input(tab, expr, example) for example in input]
end

"""
    execute_on_input(grammar::AbstractGrammar, program::RuleNode, input::Dict{Symbol, T})::Any where T

Converts a `RuleNode` program into an expression using a given `grammar`, then evaluates this expression with a single input dictionary `input` and a symbol table derived from the `grammar` using `execute_on_input(tab::SymbolTable, expr::Any, input::Dict{Symbol, T})`.

# Arguments
- `grammar::AbstractGrammar`: A grammar object used to convert the `RuleNode` into an executable expression.
- `program::RuleNode`: The program, represented as a `RuleNode`, to be converted and evaluated.
- `input::Dict{Symbol, T}`: A dictionary providing input values for symbols used in the generated expression.

# Returns
- `Any`: The result of evaluating the generated expression with the given input dictionary.
"""
function execute_on_input(grammar::AbstractGrammar, program::RuleNode, input::Dict{Symbol,T})::Any where {T}
    expression = rulenode2expr(program, grammar)
    symboltable = SymbolTable(grammar)
    return execute_on_input(symboltable, expression, input)
end

"""
    execute_on_input(grammar::AbstractGrammar, program::RuleNode, input::Vector{T})::Vector{Any} where T <: Dict{Symbol, <:Any}

Converts a `RuleNode` program into an expression using a given `grammar`, then evaluates this expression for each input dictionary in a vector `input` and a symbol table derived from the `grammar` using `execute_on_input(tab::SymbolTable, expr::Any, input::Dict{Symbol, T})`.

# Arguments
- `grammar::AbstractGrammar`: A grammar object used to convert the `RuleNode` into an executable expression.
- `program::RuleNode`: The program, represented as a `RuleNode`, to be converted and evaluated.
- `input::Vector{T}`: A vector of dictionaries, each providing input values for symbols used in the generated expression.

# Returns
- `Vector{Any}`: A vector containing the results of evaluating the generated expression for each input dictionary.
"""
function execute_on_input(grammar::AbstractGrammar, program::RuleNode, input::Vector{T})::Vector{Any} where {T<:Dict{Symbol,<:Any}}
    expression = rulenode2expr(program, grammar)
    symboltable = SymbolTable(grammar)
    return execute_on_input(symboltable, expression, input)
end


"""
    evaluate_program(program::RuleNode, examples::Vector{<:IOExample}, grammar::AbstractGrammar, evaluation_function::Function)

Runs a program on the examples and returns tuples of actual desired output and the program's output
"""
function evaluate_program(program::RuleNode, examples::Vector{<:IOExample}, grammar::AbstractGrammar, evaluation_function::Function)
    depwarn("`evaluate_program` is deprecated and should no longer be used. Please use HerbSearch.evaluate instead.", :evaluate_program)

    results = Tuple{<:Number,<:Number}[]
    expression = rulenode2expr(program, grammar)
    symbol_table = SymbolTable(grammar)
    for example ∈ filter(e -> e isa IOExample, examples)
        outcome = evaluation_function(symbol_table, expression, example.in)
        push!(results, (example.out, outcome))
    end
    return results
end


"""
    interpret(tab::SymbolTable, ex::Expr)

Evaluates an expression without compiling it.
Uses AST and symbol lookups. Only supports :call and :(=)
expressions at the moment.

Example usage:
```
tab = SymbolTable(:f => f, :x => x)
ex = :(f(x))
interpret(tab, ex)
```

WARNING: This function throws exceptions that are caused in the given expression.
These exceptions have to be handled by the caller of this function.
"""
interpret(tab::SymbolTable, x::Any, _::Any...) = x
interpret(tab::SymbolTable, s::Symbol, _::Any...) = tab[s]

function interpret(tab::SymbolTable, ex::Expr, interp_args::InterpArgs)
    args = ex.args
    if ex.head == :call
        if ex.args[1] == Symbol(".&")
            return (interpret(tab, args[2], interp_args) .& interpret(tab, args[3], interp_args))
        elseif ex.args[1] == Symbol(".|")
            return (interpret(tab, args[2], interp_args) .| interpret(tab, args[3], interp_args))
        elseif ex.args[1] == Symbol(".==")
            return (interpret(tab, args[2], interp_args) .== interpret(tab, args[3], interp_args))
        elseif ex.args[1] == Symbol(".>=")
            return (interpret(tab, args[2], interp_args) .>= interpret(tab, args[3], interp_args))
        elseif ex.args[1] == Symbol(".<=")
            return (interpret(tab, args[2], interp_args) .<= interpret(tab, args[3], interp_args))
        elseif ex.args[1] == Symbol("<")
            return (interpret(tab, args[2], interp_args) < interpret(tab, args[3], interp_args))
        else
            len = length(args)
            #unroll for performance and avoid excessive allocations
            if len == 1
                return tab[args[1]]()
            elseif len == 2
                return tab[args[1]](interpret(tab, args[2], interp_args))
            elseif len == 3
                return tab[args[1]](interpret(tab, args[2], interp_args), interpret(tab, args[3], interp_args))
            elseif len == 4
                return tab[args[1]](
                    interpret(tab, args[2], interp_args),
                    interpret(tab, args[3], interp_args),
                    interpret(tab, args[4], interp_args))
            elseif len == 5
                return tab[args[1]](
                    interpret(tab, args[2], interp_args),
                    interpret(tab, args[3], interp_args),
                    interpret(tab, args[4], interp_args),
                    interpret(tab, args[5], interp_args))
            elseif len == 6
                return tab[args[1]](
                    interpret(tab, args[2], interp_args),
                    interpret(tab, args[3], interp_args),
                    interpret(tab, args[4], interp_args),
                    interpret(tab, args[5], interp_args),
                    interpret(tab, args[6], interp_args))
            else
                return tab[args[1]](interpret.(Ref(tab), args[2:end], Ref(interp_args))...)
            end
        end
    elseif ex.head == :(.)
        return Base.broadcast(Base.eval(args[1]), interpret(tab, args[2], interp_args)...)
    elseif ex.head == :tuple
        return tuple(interpret.(Ref(tab), args, Ref(interp_args))...)
    elseif ex.head == :vect
        return [interpret.(Ref(tab), args, Ref(interp_args))...]
    elseif ex.head == :||
        if !isnothing(interp_args.actual_code_path) && args[1] == angelic_condition_flag
            return update_✝γ_path(interp_args.attempt_code_path, interp_args.actual_code_path) || interpret(tab, args[2], interp_args)
        else
            return (interpret(tab, args[1], interp_args) || interpret(tab, args[2], interp_args))
        end
    elseif ex.head == :&&
        return (interpret(tab, args[1], interp_args) && interpret(tab, args[2], interp_args))
    elseif ex.head == :(=)
        return (tab[args[1]] = interpret(tab, args[2], interp_args)) #assignments made to symboltable
    elseif ex.head == :block
        result = nothing
        for x in args
            result = interpret(tab, x, interp_args)
        end
        return result
    elseif ex.head == :if
        if !isnothing(interp_args.actual_code_path) && args[1] == angelic_condition_flag
            if update_✝γ_path(interp_args.attempt_code_path, interp_args.actual_code_path)
                return interpret(tab, args[2], interp_args)
            elseif length(args) > 2
                return interpret(tab, args[3], interp_args)
            end
        else
            if interpret(tab, args[1], interp_args)
                return interpret(tab, args[2], interp_args)
            elseif length(args) > 2
                return interpret(tab, args[3], interp_args)
            end
        end
    elseif ex.head == :while
        if !isnothing(interp_args.actual_code_path) && args[1] == angelic_condition_flag
            while update_✝γ_path(interp_args.attempt_code_path, interp_args.actual_code_path)
                interp_args.limit_iterations -= 1
                interpret(tab, args[2], interp_args)
                if interp_args.limit_iterations <= 0 || interp_args.is_breaking
                    interp_args.is_breaking = false
                    break
                end
            end
        else
            while interpret(tab, args[1], interp_args)
                interp_args.limit_iterations -= 1
                interpret(tab, args[2], interp_args)
                if interp_args.limit_iterations <= 0 || interp_args.is_breaking
                    interp_args.is_breaking = false
                    break
                end
            end
        end
    elseif ex.head == :return
        interpret(tab, args[1], interp_args)
    elseif ex.head == :break
        interp_args.is_breaking = true
    else
        print(ex)
        error("Expression type not supported")
    end
end


### Raw interpret, no symbol table
function interpret(ex::Expr, M::Module=Main)
    result = if ex.head == :call
        call_func(M, ex.args...)
    elseif ex.head == :vect
        ex.args
    else
        Core.eval(M, ex)
    end
end
call_func(M::Module, f::Symbol) = getproperty(M, f)()
call_func(M::Module, f::Symbol, x1) = getproperty(M, f)f(x1)
call_func(M::Module, f::Symbol, x1, x2) = getproperty(M, f)(x1, x2)
call_func(M::Module, f::Symbol, x1, x2, x3) = getproperty(M, f)(x1, x2, x3)
call_func(M::Module, f::Symbol, x1, x2, x3, x4) = getproperty(M, f)(x1, x2, x3, x4)
call_func(M::Module, f::Symbol, x1, x2, x3, x4, x5) = getproperty(M, f)(x1, x2, x3, x4, x5)

"""
    update_✝γ_path(✝γ_code_path::CodePath, ✝γ_actual_code_path::BitVector)

A helper function used to keep track of the taken code path during execution of control statements.

# Arguments
- `✝γ_code_path`: The `attempted` code path. Values are added until entire path is taken.
- `✝γ_actual_code_path`: The actual code path - Values from `✝γ_code_path` are appended until it is empty, then only the `false` path is taken.

# Returns
The next path to be taken in this control statement - either the first value of `✝γ_code_path`, or `false`.

"""
function update_✝γ_path(✝γ_code_path::CodePath, ✝γ_actual_code_path::BitVector)::Bool
    # If attempted flow already completed - append `false` until return
    if length(✝γ_code_path.code_path) <= ✝γ_code_path.idx
        push!(✝γ_actual_code_path, false)
        return false
    end
    # Else take next and append to actual path
    ✝γ_code_path.idx += 1
    res = ✝γ_code_path.code_path[✝γ_code_path.idx]
    push!(✝γ_actual_code_path, res)
    res == 1
end