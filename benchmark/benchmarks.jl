using Pkg
Pkg.activate(@__DIR__) # activate the benchmark environment
Pkg.instantiate()

using BenchmarkTools
using HerbInterpret

const SUITE = BenchmarkGroup()

SUITE["interpret"] = BenchmarkGroup()

tab = Dict{Symbol, Any}(
    :%      => rem,
    :(==)   => ==,
    :string => string,
    :Int    => Int64,
    :String => String,
    :input1 => 15
)

SUITE["interpret"]["compiled"] = @benchmarkable example = (input1) -> if input1 % 5 == 0 && input1 % 3 == 0 return "FizzBuzz" else string(input1) end
SUITE["interpret"]["compiled"] = @benchmarkable interpret(tab, :(if input1 % 5 == 0 && input1 % 3 == 0 return "FizzBuzz" else string(input1) end))
