using Pkg
Pkg.activate(@__DIR__) # activate the benchmark environment
Pkg.instantiate()

using BenchmarkTools
using HerbInterpret
@warn "About to load Metatheory. Currently, the 3.0 development branch claims to be much faster. Consider installing it."
using Metatheory

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

Mem = Dict{Symbol,Union{Bool,Int}}
read_mem = @theory v σ begin
  (v::Symbol, σ::Mem) => σ[v]
end

σ₁ = Mem(:x => 2)
program = :(x, $σ₁)

benchmark_outputs = joinpath(@__DIR__, "output")

if !isdir(benchmark_outputs) mkdir(benchmark_outputs) end

@info "Benchmarking Compiled Version"
SUITE["interpret"] = @benchmarkable example_function(15)
tune!(SUITE)
results = run(SUITE; verbose=true)
BenchmarkTools.save(joinpath(benchmark_outputs, "bench-compiled.json"), results)

println("Sleeping for 5s to relax...")
sleep(5)

@info "Benchmarking with interpreter from `HerbInterpret`"
SUITE["interpret"] = @benchmarkable interpret(tab, :(example_function(input1)))
tune!(SUITE)
results = run(SUITE; verbose=true)
BenchmarkTools.save(joinpath(benchmark_outputs, "bench-interpret.json"), results)

println("Sleeping for 5s to relax...")
sleep(5)

@info "Benchmarking With Metatheory"
SUITE["interpret"] = @benchmarkable rewrite(program, read_mem)
tune!(SUITE)
results = run(SUITE; verbose=true)
BenchmarkTools.save(joinpath(benchmark_outputs, "bench-metatheory.json"), results)

results = Dict([basename(name)[7:end-5] => BenchmarkTools.load(name) for name in readdir(benchmark_outputs, join=true)])

interpret_vs_compiled = judge(
    mean(results["interpret"][1]),
    mean(results["compiled"][1]),
)["interpret"]

@show interpret_vs_compiled

metatheory_vs_compiled = judge(
    mean(results["metatheory"][1]),
    mean(results["compiled"][1]),
)["interpret"]

@show metatheory_vs_compiled
