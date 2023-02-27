module Evaluation

using ..Data
using ..Grammars

include("interpreter.jl")

export 
    SymbolTable,
    interpret,
    evaluate_examples
    evaluate_all_examples,
    evaluate_with_input,
    execute_program_on_examples


end # module
