using HerbInterpret
using HerbCore
using HerbGrammar
using Test

@testset verbose=true "HerbInterpret.jl" begin
    include("test_execute_on_input.jl")
end
