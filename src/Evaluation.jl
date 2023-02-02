module Evaluation

using ..Data
using ..Grammars

include("interpreter.jl")

export 
    SymbolTable,
    interpret,
    evaluate_examples
    evaluate_all_examples,
    evaluate_with_input


end # module