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
        input_dict = Dict(:x => 3)
        @test test_with_input(tab, :(x * x + 2), input_dict) == 3 * 3 + 2
    end
end
