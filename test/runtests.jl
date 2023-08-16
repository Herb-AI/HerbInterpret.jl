using HerbEvaluation
using Test

@testset "HerbEvaluation.jl" begin
    # Write your tests here. 
    @testset "Simple test_with_input (x + 2)" begin
        tab = Dict{Symbol,Any}(:+ => +)
        input_dict = Dict(:x => 3)
        @test test_with_input(tab, :(x + 2), input_dict) == 5
    end

    @testset "Simple test_with_input (x * x + 2)" begin
        tab = Dict{Symbol,Any}(:+ => +, :* => *)
        input = 3
        f(x) = x * x + 2
        input_dict = Dict(:x => input,:f => f)
        @test test_with_input(tab, :(f(x)), input_dict) == f(input)
    end
end
