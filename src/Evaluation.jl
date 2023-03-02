module Evaluation

using ..Data
using ..Grammars

include("interpreter.jl")

export 
    SymbolTable,
    interpret,
    test_examples
    test_all_examples,
    test_with_input,
    execute_on_examples


end # module
