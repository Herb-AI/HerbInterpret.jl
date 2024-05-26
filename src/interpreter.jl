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

"""
    execute_on_input(tab::SymbolTable, expr::Any, input::Dict{Symbol, T})::Any where T

Evaluates an expression `expr` within the context of a symbol table `tab` and a single input dictionary `input`. 
The input dictionary keys should match the symbols used in the expression, and their values are used during the expression's evaluation.

# Arguments
- `tab::SymbolTable`: A symbol table containing predefined symbols and their associated values or functions.
- `expr::Any`: The expression to be evaluated. Can be any Julia expression that is valid within the context of the provided symbol table and input.
- `input::Dict{Symbol, T}`: A dictionary where each key is a symbol used in the expression, and the value is the corresponding value to be used in the expression's evaluation. The type `T` can be any type.

# Returns
- `Any`: The result of evaluating the expression with the given symbol table and input dictionary.

!!! warning
    This function throws exceptions that are caused in the given expression. These exceptions have to be handled by the caller of this function.

"""
function execute_on_input(
    tab::SymbolTable,
    expr::Any,
    input::Dict{Symbol,T},
    attempt_code_path::Union{Vector{Char},Nothing}=nothing,
    actual_code_path::Union{Vector{Char},Nothing}=nothing,
    limit_iterations::Int=30,
)::Any where {T}
    # Add input variable values
    symbols = merge(tab, input)
    return interpret(symbols, expr, attempt_code_path, actual_code_path, limit_iterations)
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

function interpret(tab::SymbolTable, ex::Expr, attempt_code_path::Union{Vector{Char},Nothing}=nothing, actual_code_path::Union{Vector{Char},Nothing}=nothing, it::Int=30)
    args = ex.args
    if ex.head == :call
        if ex.args[1] == Symbol(".&")
            return (interpret(tab, args[2], attempt_code_path, actual_code_path, it) .& interpret(tab, args[3], attempt_code_path, actual_code_path, it))
        elseif ex.args[1] == Symbol(".|")
            return (interpret(tab, args[2], attempt_code_path, actual_code_path, it) .| interpret(tab, args[3], attempt_code_path, actual_code_path, it))
        elseif ex.args[1] == Symbol(".==")
            return (interpret(tab, args[2], attempt_code_path, actual_code_path, it) .== interpret(tab, args[3], attempt_code_path, actual_code_path, it))
        elseif ex.args[1] == Symbol(".>=")
            return (interpret(tab, args[2], attempt_code_path, actual_code_path, it) .>= interpret(tab, args[3], attempt_code_path, actual_code_path, it))
        elseif ex.args[1] == Symbol(".<=")
            return (interpret(tab, args[2], attempt_code_path, actual_code_path, it) .<= interpret(tab, args[3], attempt_code_path, actual_code_path, it))
        elseif ex.args[1] == Symbol("<")
            return (interpret(tab, args[2], attempt_code_path, actual_code_path, it) < interpret(tab, args[3], attempt_code_path, actual_code_path, it))
        else
            len = length(args)
            #unroll for performance and avoid excessive allocations
            if len == 1
                return tab[args[1]]()
            elseif len == 2
                return tab[args[1]](interpret(tab, args[2], attempt_code_path, actual_code_path, it))
            elseif len == 3
                return tab[args[1]](interpret(tab, args[2], attempt_code_path, actual_code_path, it), interpret(tab, args[3], attempt_code_path, actual_code_path, it))
            elseif len == 4
                return tab[args[1]](
                    interpret(tab, args[2], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[3], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[4], attempt_code_path, actual_code_path, it))
            elseif len == 5
                return tab[args[1]](
                    interpret(tab, args[2], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[3], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[4], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[5], attempt_code_path, actual_code_path, it))
            elseif len == 6
                return tab[args[1]](
                    interpret(tab, args[2], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[3], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[4], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[5], attempt_code_path, actual_code_path, it),
                    interpret(tab, args[6], attempt_code_path, actual_code_path, it))
            else
                return tab[args[1]](interpret.(Ref(tab), args[2:end], Ref(attempt_code_path), Ref(actual_code_path), it)...)
            end
        end
    elseif ex.head == :(.)
        return Base.broadcast(Base.eval(args[1]), interpret(tab, args[2], attempt_code_path, actual_code_path, it)...)
    elseif ex.head == :tuple
        return tuple(interpret.(Ref(tab), args, Ref(attempt_code_path), Ref(actual_code_path), it)...)
    elseif ex.head == :vect
        return [interpret.(Ref(tab), args, Ref(attempt_code_path), Ref(actual_code_path), it)...]
    elseif ex.head == :||
        return (interpret(tab, args[1], attempt_code_path, actual_code_path, it) || interpret(tab, args[2], attempt_code_path, actual_code_path, it))
    elseif ex.head == :&&
        return (interpret(tab, args[1], attempt_code_path, actual_code_path, it) && interpret(tab, args[2], attempt_code_path, actual_code_path, it))
    elseif ex.head == :(=)
        return (tab[args[1]] = interpret(tab, args[2], attempt_code_path, actual_code_path, it)) #assignments made to symboltable
    elseif ex.head == :block
        result = nothing
        for x in args
            result = interpret(tab, x, attempt_code_path, actual_code_path, it)
        end
        return result
    elseif ex.head == :if && !isnothing(actual_code_path)
        interpret(tab, args[1], attempt_code_path, actual_code_path, it)
        if update_✝γ_path(attempt_code_path, actual_code_path)
            return interpret(tab, args[2], attempt_code_path, actual_code_path, it)
        else
            return interpret(tab, args[3], attempt_code_path, actual_code_path, it)
        end
    elseif ex.head == :if
        if interpret(tab, args[1], attempt_code_path, actual_code_path, it)
            return interpret(tab, args[2], attempt_code_path, actual_code_path, it)
        else
            return interpret(tab, args[3], attempt_code_path, actual_code_path, it)
        end
    elseif ex.head == :while && !isnothing(actual_code_path)
        interpret(tab, args[1], attempt_code_path, actual_code_path, it)
        while update_✝γ_path(attempt_code_path, actual_code_path)
            if it == 0
                break
            end
            it -= 1
            interpret(tab, args[2], attempt_code_path, actual_code_path, it)
        end
    elseif ex.head == :while
        while interpret(tab, args[1], attempt_code_path, actual_code_path, it)
            if it == 0
                break
            end
            it -= 1
            interpret(tab, args[2], attempt_code_path, actual_code_path, it)
        end
    elseif ex.head == :return
        interpret(tab, args[1], attempt_code_path, actual_code_path, it)
    else
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
    update_✝γ_path(✝γ_code_path::Vector{Char}, ✝γ_actual_code_path::Vector{Char})

The injected function call that goes into where previously were the holes/angelic conditions. It updates the actual path taken during angelic evaluation.

# Arguments
- `✝γ_code_path`: The `attempted` code path. Values are removed until empty.
- `✝γ_actual_code_path`: The actual code path - Values from `✝γ_code_path` are appended until it is empty, then only the `false` path is taken.

# Returns
The next path to be taken in this control statement - either the first value of `✝γ_code_path`, or `false`.

"""
function update_✝γ_path(✝γ_code_path::Vector{Char}, ✝γ_actual_code_path::Vector{Char})::Bool
    # If attempted flow already completed - append `false` until return
    if length(✝γ_code_path) == 0
        push!(✝γ_actual_code_path, '0')
        return false
    end
    # Else take next and append to actual path
    res = ✝γ_code_path[1]
    popfirst!(✝γ_code_path)
    push!(✝γ_actual_code_path, res)
    res == '1'
end