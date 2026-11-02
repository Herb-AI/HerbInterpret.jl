module OutputTestDSL
    using HerbGrammar
    const calls = Ref(0)
    checked_add(a::Int, b::Int) = (calls[] += 1; a + b)
    maybe(a::Int) = a < 0 ? nothing : a
    g = @cfgrammar begin
        N = _arg_1
        N = 1
        N = checked_add(N, N)
        N = maybe(N)
        Start = N
        F = x -> checked_add(N, x)
        N = N > 0 ? N : N
    end
end

function build_output_and_call(g, inputs)
    interp = HerbInterpret.make_output_interpreter(g; target_module=OutputTestDSL,
        cache_module=OutputTestDSL)
    interp(3, [Any[1, nothing, 3], Any[2, 4, 5]], inputs)
end

@testset "Output interpreter and nothing propagation" begin
    g = OutputTestDSL.g
    tree = make_interpreter(g; target_module=OutputTestDSL)
    output = HerbInterpret.make_output_interpreter(g; target_module=OutputTestDSL,
        cache_module=OutputTestDSL)
    inputs = [Dict{Symbol,Any}(:_arg_1 => x) for x in (2, -1, 4)]
    examples = [IOExample(input, nothing) for input in inputs]
    children = [Any[2, nothing, 4], Any[1, 1, 1]]

    @testset "Scalar and batch entry points" begin
        @test output(1, Any[], inputs) == [2, -1, 4]
        @test output(2, Any[], inputs) == [1, 1, 1]
        @test output(3, Any[2, 1], inputs[1]) == 3
        @test output(3, Any[2, 1], examples[1]) == 3
        @test output(3, Any[2, 1], Dict(:_arg_1 => 2)) == 3
        @test isequal(output(3, children, inputs), [3, nothing, 5])
        @test isequal(output(3, children, examples), [3, nothing, 5])
        @test output(1, Any[], [Dict(:_arg_1=>2), Dict(:_arg_1=>3)]) == [2, 3]
        @test output(2, Any[], empty(inputs)) == Any[]
        @test output(3, [Any[], Any[]], empty(examples)) == Any[]
        @test isequal(build_output_and_call(g, inputs), [3, nothing, 8])
        @test_throws BoundsError output(999, Any[], inputs)
        @test_throws ErrorException output(999, Any[], inputs[1])
    end

    @testset "Guard operators and propagate through ancestors" begin
        for missing in (Any[nothing, 1], Any[1, nothing], Any[nothing, nothing])
            OutputTestDSL.calls[] = 0
            @test output(3, missing, inputs[1]) === nothing
            @test OutputTestDSL.calls[] == 0
        end
        OutputTestDSL.calls[] = 0
        @test isequal(output(3, children, inputs), [3, nothing, 5])
        @test OutputTestDSL.calls[] == 2
        @test isequal(output(4, [Any[2, -1, 4]], inputs), [2, nothing, 4])
        @test isequal(output(5, [Any[2, nothing, 4]], inputs), [2, nothing, 4])
        @test isequal(output(3, [Any[nothing, nothing, nothing], Any[1, 1, 1]], inputs),
            [nothing, nothing, nothing])
        # Both batch paths agree with independent scalar calls.
        @test isequal(output(3, children, inputs),
            [output(3, [c[i] for c in children], inputs[i]) for i in eachindex(inputs)])
        program = @rulenode(5{3{4{1},2}})
        @test isequal(tree(program, inputs), [3, nothing, 5])
        @test tree(program, Dict{Symbol,Any}(:_arg_1=>nothing)) === nothing
        @test tree(@rulenode(3{2,4{1}}), inputs[2]) === nothing
        @test isequal(tree(program, examples), [3, nothing, 5])
    end

    @testset "Constant shortcut and captured child values" begin
        OutputTestDSL.calls[] = 0
        @test output(3, [Any[2, 2, 2], Any[1, 1, 1]], inputs) == [3, 3, 3]
        @test OutputTestDSL.calls[] == 1
        fs = output(6, [Any[1, 2, 3]], inputs)
        @test [f(10) for f in fs] == [11, 12, 13]
        @test output(6, Any[nothing], inputs[1]) === nothing
        fs = output(6, [Any[1, nothing, 3]], examples)
        @test fs[1](10) == 11
        @test fs[2] === nothing
        @test fs[3](10) == 13
        @test output(7, [Any[1, -1, 1], Any[10, 20, 30], Any[40, 50, 60]], inputs) == [10, 50, 30]
        # Preserve eager child validation even for an unused conditional branch.
        @test output(7, Any[1, 10, nothing], inputs[1]) === nothing
        @test isequal(output(7, [Any[1, -1, 1], Any[10, 20, nothing], Any[nothing, 50, 60]], inputs),
            [nothing, 50, nothing])
    end
end

@testset "Typed output storage" begin
    output = HerbInterpret.make_output_interpreter(OutputTestDSL.g;
        target_module=OutputTestDSL)
    inputs = [Dict{Symbol,Any}(:_arg_1=>x) for x in (2, -1, 4)]
    examples = [IOExample(input, nothing) for input in inputs]
    ints = output(1, Vector[], inputs)
    @test ints isa Vector{Int}
    @test output(3, [ints, [1, 2, 3]], examples) isa Vector{Int}
    maybe = output(4, [ints], inputs)
    @test maybe isa Vector{Union{Nothing,Int}}
    @test isequal(maybe, [2, nothing, 4])
    @test output(3, Vector[maybe, [1, 2, 3]], inputs) isa Vector{Union{Nothing,Int}}
    @test output(3, Vector[fill(nothing, 3), [1, 2, 3]], inputs) isa Vector{Nothing}
    @test output(2, Vector[], inputs) isa Vector{Int}
    @test output(1, Vector[], empty(inputs)) == []

    heterogeneous = [Dict{Symbol,Any}(:_arg_1=>x) for x in (1, "two", nothing)]
    @test isequal(output(1, Vector[], heterogeneous), [1, "two", nothing])
    # Widening must preserve values rather than convert Int to Float64.
    mixed_numbers = [Dict{Symbol,Any}(:_arg_1=>x) for x in (1, 2.5, 3)]
    mixed = output(1, Vector[], mixed_numbers)
    @test mixed[1] isa Int
    @test mixed[2] isa Float64
    arrays = [Dict{Symbol,Any}(:_arg_1=>x) for x in ([1], [2, 3], [4])]
    @test output(1, Vector[], arrays) isa Vector{Vector{Int}}
    fs = output(6, Vector[[1, 2, 3]], examples)
    @test isconcretetype(eltype(fs))
    @test [f(10) for f in fs] == [11, 12, 13]
end
