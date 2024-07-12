using HerbInterpret
using HerbCore
using HerbGrammar
using Test

@testset verbose=true "HerbInterpret.jl" begin
    include("test_execute_on_input.jl")

    include("test_angelic_conditions/test_bit_trie.jl")
    include("test_angelic_conditions/test_execute_angelic.jl")
end
