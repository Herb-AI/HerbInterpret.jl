using Pkg
Pkg.activate(@__DIR__) # activate the benchmark environment
Pkg.instantiate()

using BenchmarkTools
using HerbInterpret

const SUITE = BenchmarkGroup()

SUITE["interpret"] = BenchmarkGroup()

function example_function(input1)
    if input1 % 5 == 0 && input1 % 3 == 0
        return "FizzBuzz"
    elseif input1 % 3 == 0
        return "Fizz"
    elseif input1 % 5 == 0
        return "Buzz"
    else
        return string(input1)
    end
end

tab = Dict{Symbol, Any}(
    :%      => rem,
    :(==)   => ==,
    :string => string,
    :Int    => Int64,
    :String => String,
    :input1 => 15,
    :example_function => example_function
)

SUITE["interpret"]["compiled"] = @benchmarkable example_function(15)
SUITE["interpret"]["interpreted"] = @benchmarkable interpret(tab, :(example_function(input1)))
