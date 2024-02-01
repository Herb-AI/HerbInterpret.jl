using Base: depwarn
"""
    test_all_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Vector{Bool}

Runs the interpreter on all examples with the given input table and expression. 
The symbol table defines everything (functions, symbols) that are not input variables to the program to be synthesised.
Returns a list of true/false values indicating if the expression satisfies the corresponding example.
WARNING: This function throws exceptions that are caused in the given expression.
These exceptions have to be handled by the caller of this function.
"""
function test_all_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Vector{Bool}
    depwarn("`test_all_examples` is deprecated and should no longer be used.", :test_all_examples)
    throw(ErrorException("`test_all_examples` has been deprecated and should not be used."))

    outcomes = Vector{Bool}(undef, length(examples))
    for example ∈ filter(e -> e isa IOExample, examples)
        push!(outcomes, example.out == execute_on_input(tab, expr, example.in))
    end
    return outcomes
end

"""
    test_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Bool

Evaluates all examples and returns true iff all examples pass.
Shortcircuits as soon as an example is found for which the program doesn't work. 
Returns false if one of the examples produces an error.
"""
function test_examples(tab::SymbolTable, expr::Any, examples::Vector{IOExample})::Bool
    depwarn("`test_examples` is deprecated and should no longer be used.", :test_examples)
    throw(ErrorException("`test_examples` has been deprecated and should not be used."))

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
    execute_on_input(tab::SymbolTable, expr::Any, input::Dict)

Interprets an expression or symbol with the given symboltable and the input.
WARNING: This function throws exceptions that are caused in the given expression.
These exceptions have to be handled by the caller of this function.
"""
function execute_on_input(tab::SymbolTable, expr::Any, input::Dict{Symbol, <:Any})::Any
    # Add input variable values
    symbols = merge(tab, input)
    return interpret(symbols, expr)
end


"""
    execute_on_input(tab::SymbolTable, expr::Any, inputs::Vector{Dict{Symbol, Any}})::Vector{Any}

Executes a given expression on a set of inputs and returns the respective outputs.
WARNING: This function throws exceptions that are caused in the given expression.
These exceptions have to be handled by the caller of this function.
"""
function execute_on_input(tab::SymbolTable, expr::Any, input::Vector{Dict{Symbol, Any}})::Vector{Any}
    return [execute_on_input(tab, expr, example) for example in input]
end

function execute_on_input(grammar::Grammar, program::RuleNode, input::Vector{Dict{Symbol, Any}})::Vector{Any}
    expression = rulenode2expr(program, grammar)
    symboltable = SymbolTable(grammar)
    return execute_on_input(symboltable, expression, input)
end

function execute_on_input(grammar::Grammar, program::RuleNode, input::Dict{Symbol, Any})::Any
    expression = rulenode2expr(program, grammar)
    symboltable = SymbolTable(grammar)
    return execute_on_input(symboltable, expression, input)
end


"""
    evaluate_program(program::RuleNode, examples::Vector{<:IOExample}, grammar::Grammar, evaluation_function::Function)

Runs a program on the examples and returns tuples of actual desired output and the program's output
"""
function evaluate_program(program::RuleNode, examples::Vector{<:IOExample}, grammar::Grammar, evaluation_function::Function)
    depwarn("`evaluate_program` is deprecated and should no longer be used. Please use HerbSearch.evaluate instead.", :evaluate_program)
    throw(ErrorException("`evaluate_program` has been deprecated and should not be used."))

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
interpret(tab::SymbolTable, x::Any) = x
interpret(tab::SymbolTable, s::Symbol) = tab[s]

function interpret(tab::SymbolTable, ex::Expr)
    args = ex.args
    if ex.head == :call
        if ex.args[1] == Symbol(".&")
            return (interpret(tab, args[2]) .& interpret(tab, args[3]))
        elseif ex.args[1] == Symbol(".|")
            return (interpret(tab, args[2]) .| interpret(tab, args[3]))
        elseif ex.args[1] == Symbol(".==")
            return (interpret(tab, args[2]) .== interpret(tab, args[3]))
        elseif ex.args[1] == Symbol(".>=")
            return (interpret(tab, args[2]) .>= interpret(tab, args[3]))
        elseif ex.args[1] == Symbol(".<=")
            return (interpret(tab, args[2]) .<= interpret(tab, args[3]))
        else
            len = length(args)
            #unroll for performance and avoid excessive allocations
            if len == 1
                return tab[args[1]]()
            elseif len == 2
                return tab[args[1]](interpret(tab,args[2]))
            elseif len == 3
                return tab[args[1]](interpret(tab,args[2]), interpret(tab,args[3]))
            elseif len == 4
                return tab[args[1]](interpret(tab,args[2]), interpret(tab,args[3]), interpret(tab,args[4]))
            elseif len == 5
                return tab[args[1]](interpret(tab,args[2]), interpret(tab,args[3]), interpret(tab,args[4]),
                                       interpret(tab,args[5]))
            elseif len == 6
                return tab[args[1]](interpret(tab,args[2]), interpret(tab,args[3]), interpret(tab,args[4]),
                                       interpret(tab,args[5]), interpret(tab,args[6]))
            else
                return tab[args[1]](interpret.(Ref(tab),args[2:end])...)
            end
        end
    elseif ex.head == :(.)
        return Base.broadcast(Base.eval(args[1]), interpret(tab, args[2])...)
    elseif ex.head == :tuple
        return tuple(interpret.(Ref(tab), args)...)
    elseif ex.head == :vect
        return [interpret.(Ref(tab), args)...]
    elseif ex.head == :||
        return (interpret(tab, args[1]) || interpret(tab, args[2]))
    elseif ex.head == :&&
        return (interpret(tab, args[1]) && interpret(tab, args[2]))
    elseif ex.head == :(=)
        return (tab[args[1]] = interpret(tab, args[2])) #assignments made to symboltable
    elseif ex.head == :block
        result = nothing
        for x in args
            result = interpret(tab, x)
        end
        return result
    elseif ex.head == :if
        if interpret(tab, args[1])
            return interpret(tab, args[2])
        else
            return interpret(tab, args[3])
        end
    elseif ex.head == :while
        result = nothing

        while interpret(tab, ex.args[1])
            result = interpret(tab, ex.args[2])
        end
        return result
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
call_func(M::Module, f::Symbol) = getproperty(M,f)()
call_func(M::Module, f::Symbol, x1) = getproperty(M,f)f(x1)
call_func(M::Module, f::Symbol, x1, x2) = getproperty(M,f)(x1, x2)
call_func(M::Module, f::Symbol, x1, x2, x3) = getproperty(M,f)(x1, x2, x3)
call_func(M::Module, f::Symbol, x1, x2, x3, x4) = getproperty(M,f)(x1, x2, x3, x4)
call_func(M::Module, f::Symbol, x1, x2, x3, x4, x5) = getproperty(M,f)(x1, x2, x3, x4, x5)
