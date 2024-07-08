"""
    passes_the_same_tests_or_more(program::RuleNode, grammar::AbstractGrammar, tests::AbstractVector{<:IOExample}, passed_tests::BitVector)::Bool

Checks if the provided program passes all the tests (or more) that have been provided. The function breaks early if a test fails.

# Arguments
- `program`: The program to test.
- `grammar`: The grammar rules of the program.
- `tests`: A vector of `IOExample` objects representing the input-output test cases.
- `passed_tests`: A BitVector representing the tests that the program has already passed.

# Returns
Returns true if the program passes all the tests in marked in `passed_Tests`, false otherwise.

"""
function passes_the_same_tests_or_more(program::RuleNode, grammar::AbstractGrammar, tests::AbstractVector{<:IOExample}, passed_tests::BitVector)::Bool
    symboltable = SymbolTable(grammar)
    expr = rulenode2expr(program, grammar)
    for (index, test) in enumerate(tests)
        # If original does not pass, then skip
        if !passed_tests[index]
            continue
        end
        # Else check that new program also passes the test
        try
            output = execute_on_input(symboltable, expr, test.in)
            if (output != test.out)
                return false
            end
        catch _
            return false
        end
    end
    true
end

"""
    update_passed_tests!(
        program::RuleNode, grammar::AbstractGrammar, symboltable::SymbolTable, tests::AbstractVector{<:IOExample},
        prev_passed_tests::BitVector, angelic_conditions::Dict{UInt16, UInt8}, config::ConfigAngelic)

Updates the tests that the program passes. This is done by running `program` for all `tests`, and updates the `prev_passed_tests` vector with the results.
May run the program optimistically ("angelically") if the syntax tree contains holes.

# Arguments
- `program`: The program to be tested.
- `grammar`: The grammar rules of the program.
- `symboltable`: A symbol table for the grammar.
- `tests`: A vector of `IOExample` objects representing the input-output test cases.
- `prev_passed_tests`: A `BitVector` representing the tests that the program has previously passed.
- `angelic_conditions`: A dictionary mapping indices of angelic condition candidates, to the child index that may be changed.
- `config`: The configuration for angelic conditions of FrAngel.

"""
function update_passed_tests!(
    program::RuleNode,
    grammar::AbstractGrammar,
    symboltable::SymbolTable,
    tests::AbstractVector{<:IOExample},
    prev_passed_tests::BitVector,
    angelic_conditions::Dict{UInt16,UInt8},
    angelic_config::ConfigAngelic
)
    # If angelic -> evaluate optimistically
    if contains_hole(program)
        @assert !isa(angelic_config.angelic_rulenode, Nothing)
        angelic_rulenode = angelic_config.angelic_rulenode::RuleNode
        fails = 0
        for (index, test) in enumerate(tests)
            # Angelically evaluate the program for this test
            prev_passed_tests[index] = execute_angelic_on_input(symboltable, program, grammar, test.in, test.out,
                angelic_rulenode, angelic_config.max_execute_attempts, angelic_conditions)
            if !prev_passed_tests[index]
                fails += 1
                # If it fails too many tests, preemtively end evaluation
                if angelic_config.max_allowed_fails < fails / length(tests)
                    return nothing
                end
            end
        end
        nothing
        # Otherwise, evaluate regularly
    else
        expr = rulenode2expr(program, grammar)
        for (index, test) in enumerate(tests)
            try
                output = execute_on_input(symboltable, expr, test.in)
                prev_passed_tests[index] = output == test.out
            catch _
                prev_passed_tests[index] = false
            end
        end
        expr
    end
end