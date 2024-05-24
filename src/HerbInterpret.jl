module HerbInterpret

using HerbCore
using HerbGrammar
using HerbSpecification

include("interpreter.jl")

export 
    SymbolTable,
    interpret,

    execute_on_input,
    update_✝γ_path

end # module HerbInterpret
