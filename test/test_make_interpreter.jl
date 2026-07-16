import HerbInterpret: make_interpreter

# Small module for testing state-less make_interpret
module LocalStringDSL
    using HerbCore
    concat_cvc(a::String, b::String) = a * b
end

# Simplest stateful grammar
module LocalStateDSL
    using HerbCore

    struct St
        x::Int
    end

    inc(st::St) = St(st.x + 1)
    iseven(st::St) = Base.iseven(st.x)
end

# Stateful grammar with if-then-else
module LocalStateDSL2
    using HerbCore
    using HerbGrammar

    struct St
        x::Int
    end

    inc(st::St) = St(st.x + 1)
    dec(st::St) = St(st.x - 1)
    iseven(st::St) = Base.iseven(st.x)

    g2 = @cfgrammar begin
        Start = Step
        Step  = IF(Cond, Step, Step)
        Step  = inc()
        Step  = dec()
        Step  = (Step; Step)
        Cond  = iseven()
    end
end

# Stateful grammar with WHILE
module LocalStateDSL3
    using HerbCore
    using HerbGrammar

    struct St
        x::Int
    end

    inc(st::St) = St(st.x + 1)
    lt3(st::St) = st.x < 3

    g3 = @cfgrammar begin
        Start = Step
        Step  = WHILE(Cond, Step)
        Step  = inc()
        Cond  = lt3()
    end
end

# Stateful grammar with synthesized lambda functions
module LocalStateDSL4
    using HerbCore
    using HerbGrammar

    struct St
        x::Int
    end

    # stateful primitives
    inc(st::St) = St(st.x + 1)
    dec(st::St) = St(st.x - 1)
    iseven(st::St) = Base.iseven(st.x)

    # higher-order stateful primitive: apply a synthesized function to the
    # integer inside the state
    apply(f, st::St) = St(f(st.x))

    # pure helpers for synthesized lambdas
    plus1(x::Int) = x + 1
    double(x::Int) = 2 * x

    g4 = @cfgrammar begin
        Start = Step
        Step  = apply(Func)
        Step  = IF(Cond, Step, Step)
        Step  = inc()
        Step  = dec()
        Cond  = iseven()

        Func  = plus1
        Func  = x -> double(x)
        Func  = x -> x + 1
        Func  = x -> double(Func(x)) + 1
        Func  = x -> Func(Func(x))
    end
end


"""
    _build_and_use_immediately(g; input_symbols)

Build an interpreter with `make_interpreter` and call it *within the same,
already-compiled function frame*. This is the scenario that fails with a
world-age `MethodError` unless `GeneratedInterpreter`'s call operators use
`Base.invokelatest` to cross into the freshly-`Core.eval`'d method: a bare
top-level script (or a `@testset` block, which does not introduce a new
function frame) would not actually exercise this path, so the regression
needs its own wrapping function to be meaningful.
"""
function _build_and_use_immediately(g; input_symbols = nothing)
    interp = HerbInterpret.make_interpreter(g; input_symbols = input_symbols)
    rn = @rulenode(3{1,2})  # 1 + 2
    return interp(rn, Dict{Symbol,Any}())
end

function _build_and_use_stateful_immediately(g, target_module, prog, state)
    interp = HerbInterpret.make_stateful_interpreter(g; target_module = target_module)
    return interp(prog, state)
end

# Pure helper for the synthesized-lambda tests below (resolved via `target_module=@__MODULE__`)
inc(x) = x + 1

@testset verbose=true "Test make_interpreter" begin
    @testset "World-age: build and call within the same compiled function" begin
        g = @cfgrammar begin
            Number = |(1:2)
            Number = Number + Number
        end
        @test _build_and_use_immediately(g) == 3

        g2 = @cfgrammar begin
            Start = Step
            Step  = inc()
        end
        @test _build_and_use_stateful_immediately(
            g2, LocalStateDSL, @rulenode(1{2}), LocalStateDSL.St(0),
        ) == LocalStateDSL.St(1)
    end

    @testset "Test base functionality" begin
        g = @cfgrammar begin
            Number = |(1:2)
            Number = x
            Number = Number + Number
            Number = Number * Number
            Number = Number + 1
            Number = x * 2
        end

        # Compile once
        interpret_custom = HerbInterpret.make_interpreter(g; input_symbols=[:x])

        rn = @rulenode(5{4{3,2},7})  # (x + 2) * (x * 2)
        input = Dict{Symbol,Any}(:x => 1)

        @testset "Single input dict" begin
            # Leaves
            @test interpret_custom(@rulenode(1), input) == 1
            @test interpret_custom(@rulenode(2), input) == 2
            @test interpret_custom(@rulenode(3), input) == 1

            # Pure operators
            @test interpret_custom(@rulenode(4{1,2}), input) == 3   # 1 + 2
            @test interpret_custom(@rulenode(5{1,2}), input) == 2   # 1 * 2

            # Partial rules
            @test interpret_custom(@rulenode(6{3}), input) == 2     # x + 1
            @test interpret_custom(@rulenode(7), input) == 2        # x * 2

            # Composite example
            @test interpret_custom(rn, input) == 6
        end

        @testset "Vector of input dicts" begin
            inputs = [
                Dict{Symbol,Any}(:x => 1),
                Dict{Symbol,Any}(:x => 3),
            ]
            outs = interpret_custom(rn, inputs)
            @test outs == [6, 30]  # x=1 => 6, x=3 => 30
        end

        @testset "Single IOExample" begin
            ex = HerbSpecification.IOExample(Dict{Symbol,Any}(:x => 1), nothing)
            @test interpret_custom(rn, ex) == 6
        end

        @testset "Vector of IOExamples" begin
            exs = [
                HerbSpecification.IOExample(Dict{Symbol,Any}(:x => 1), nothing),
                HerbSpecification.IOExample(Dict{Symbol,Any}(:x => 3), nothing),
            ]
            outs = interpret_custom(rn, exs)
            @test outs == [6, 30]
        end
    end

    @testset "Synthesized lambda values" begin
        @testset "Base case" begin
            g = @csgrammar begin
                Arr = _arg_1
                Arr = map(Lambda, Arr)

                Lambda = x -> Func(x)

                Func = iseven
                Func = isodd
                Func = y -> y + 1
                Func = y -> y * 2
            end

            interpret_custom = HerbInterpret.make_interpreter(g)

            input = Dict{Symbol,Any}(:_arg_1 => [1, 2, 3, 4])

            # Arr = _arg_1
            @test interpret_custom(@rulenode(1), input) == [1, 2, 3, 4]

            # Arr = map(Lambda, Arr), Lambda = x -> iseven(x)
            @test interpret_custom(@rulenode(2{3{4},1}), input) == [false, true, false, true]

            # Arr = map(Lambda, Arr), Lambda = x -> isodd(x)
            @test interpret_custom(@rulenode(2{3{5},1}), input) == [true, false, true, false]

            # Arr = map(Lambda, Arr), Lambda = x -> (y -> y + 1)(x)
            @test interpret_custom(@rulenode(2{3{6},1}), input) == [2, 3, 4, 5]

            # Arr = map(Lambda, Arr), Lambda = x -> (y -> y * 2)(x)
            @test interpret_custom(@rulenode(2{3{7},1}), input) == [2, 4, 6, 8]
        end

        @testset "Synthesized function composition" begin
            g = @csgrammar begin
                Arr = _arg_1
                Arr = map(Func, Arr)

                Func = inc
                Func = x -> 2*x
                Func = x -> x + 1
                Func = x -> 2*Func(x) + 1
                Func = x -> Func(Func(x))
            end

            interpret_custom = HerbInterpret.make_interpreter(
                g;
                target_module=@__MODULE__,
            )

            input = Dict{Symbol,Any}(:_arg_1 => [1, 2, 3, 4])

            # identity on arrays
            @test interpret_custom(@rulenode(1), input) == [1, 2, 3, 4]

            # map(inc, arr)
            @test interpret_custom(@rulenode(2{3,1}), input) == [2, 3, 4, 5]

            # map(x -> 2*x, arr)
            @test interpret_custom(@rulenode(2{4,1}), input) == [2, 4, 6, 8]

            # map(x -> x + 1, arr)
            @test interpret_custom(@rulenode(2{5,1}), input) == [2, 3, 4, 5]

            # map(x -> 2*inc(x) + 1, arr)
            @test interpret_custom(@rulenode(2{6{3},1}), input) == [5, 7, 9, 11]

            # map(x -> (x -> 2*x)(inc(x)), arr) = map(x -> 2*inc(x), arr)
            @test interpret_custom(@rulenode(2{7{4,3},1}), input) == [4, 6, 8, 10]

            # map(x -> inc(2*x), arr)
            @test interpret_custom(@rulenode(2{7{3,4},1}), input) == [3, 5, 7, 9]

            # nested composition:
            # outer = x -> 2*inc(x) + 1
            # inner = x -> x + 1
            # result = x -> 2*inc(x+1) + 1 = 2x + 5
            @test interpret_custom(@rulenode(2{7{6{3},5},1}), input) == [7, 9, 11, 13]
        end
    end

    @testset "Interpreter uses correct operators from target module" begin
        # Conflicting operator in caller module: must NOT be used
        concat_cvc(a::String, b::String) = a * "|" * b

        g = @cfgrammar begin
            Str = s
            Str = "A"
            Str = concat_cvc(Str, Str)
        end

        rn = @rulenode(3{1,2})
        input = Dict{Symbol,Any}(:s => "X")

        # Compile once, but resolve operators in LocalStringDSL
        interpret_string = HerbInterpret.make_interpreter(
            g;
            input_symbols=[:s],
            target_module=LocalStringDSL,
        )

        # Dict form
        @test interpret_string(rn, input) == "XA"

        # IOExample form (optional extra check)
        ex = HerbSpecification.IOExample(Dict{Symbol,Any}(:s => "X"), nothing)
        @test interpret_string(rn, ex) == "XA"

        # Prove caller's concat differs (and is not used)
        @test concat_cvc("X", "A") == "X|A"
    end

    @testset "Stateful interpreter generation" begin
        @testset "Test basic usage in external module" begin
            # Rule indices:
            # 1 Start    = Sequence
            # 2 Sequence = Step
            # 3 Sequence = (Step; Sequence)
            # 4 Step     = inc()
            # 5 Step     = IF(Cond, Step, Step)
            # 6 Cond     = iseven()
            g = @cfgrammar begin
                Start    = Sequence
                Sequence = Step
                Sequence = (Step; Sequence)
                Step     = inc()
                Step     = IF(Cond, Step, Step)
                Cond     = iseven()
            end

            # Build the interpreter object
            interp = HerbInterpret.make_stateful_interpreter(
                g;
                target_module = LocalStateDSL,
                cache_module  = @__MODULE__,
            )

            # Program: (inc(); inc()) starting from x=0 => x=2
            # Start=Sequence -> Sequence=(Step;Sequence) -> Step=inc(); Sequence=Step -> Step=inc()
            prog_two_incs = @rulenode(1{3{4,2{4}}})

            st0 = LocalStateDSL.St(0)
            out = interp(prog_two_incs, st0)
            @test out == LocalStateDSL.St(2)

            # Vector-of-states overload
            outs = interp(prog_two_incs, [LocalStateDSL.St(0), LocalStateDSL.St(10)])
            @test outs == [LocalStateDSL.St(2), LocalStateDSL.St(12)]
        end

        @testset "IF and sequencing semantics in external target module" begin
            # Build interpreter from grammar that lives in LocalStateDSL2
            interp2 = HerbInterpret.make_stateful_interpreter(
                LocalStateDSL2.g2;
                target_module = LocalStateDSL2,
                cache_module  = @__MODULE__,
            )

            # Rule indices in LocalStateDSL2.g2:
            # 1 Start = Step
            # 2 Step  = IF(Cond, Step, Step)
            # 3 Step  = inc()
            # 4 Step  = dec()
            # 5 Step  = (Step; Step)
            # 6 Cond  = iseven()

            # IF(iseven(), inc(), dec())
            prog_if = @rulenode(2{6,3,4})

            @test interp2(prog_if, LocalStateDSL2.St(2)) == LocalStateDSL2.St(3)  # even -> inc
            @test interp2(prog_if, LocalStateDSL2.St(3)) == LocalStateDSL2.St(2)  # odd  -> dec

            # (inc(); inc())
            prog_two_incs = @rulenode(5{3,3})
            @test interp2(prog_two_incs, LocalStateDSL2.St(0)) == LocalStateDSL2.St(2)

            # (inc(); dec())
            prog_inc_dec = @rulenode(5{3,4})
            @test interp2(prog_inc_dec, LocalStateDSL2.St(10)) == LocalStateDSL2.St(10)

            # (IF(iseven(), inc(), dec()); inc())
            prog_if_then_inc = @rulenode(5{2{6,3,4},3})
            @test interp2(prog_if_then_inc, LocalStateDSL2.St(2)) == LocalStateDSL2.St(4)  # 2 -> inc -> 3 -> inc -> 4
            @test interp2(prog_if_then_inc, LocalStateDSL2.St(3)) == LocalStateDSL2.St(3)  # 3 -> dec -> 2 -> inc -> 3

            # Vector-of-states overload
            outs_vec = interp2(prog_two_incs, [LocalStateDSL2.St(0), LocalStateDSL2.St(10)])
            @test outs_vec == [LocalStateDSL2.St(2), LocalStateDSL2.St(12)]

            # IOExample support (state is in :_arg_1)
            exs = [
                HerbSpecification.IOExample(Dict{Symbol,Any}(:_arg_1 => LocalStateDSL2.St(2)), nothing),
                HerbSpecification.IOExample(Dict{Symbol,Any}(:_arg_1 => LocalStateDSL2.St(3)), nothing),
            ]

            outs_ex = interp2(prog_if, exs)
            @test outs_ex == [LocalStateDSL2.St(3), LocalStateDSL2.St(2)]

            exs_seq = [
                HerbSpecification.IOExample(Dict{Symbol,Any}(:_arg_1 => LocalStateDSL2.St(0)), nothing),
                HerbSpecification.IOExample(Dict{Symbol,Any}(:_arg_1 => LocalStateDSL2.St(5)), nothing),
            ]

            outs_ex_seq = interp2(prog_two_incs, exs_seq)
            @test outs_ex_seq == [LocalStateDSL2.St(2), LocalStateDSL2.St(7)]
        end

        @testset "WHILE operator (bounded loop) " begin
            # Grammar lives in LocalStateDSL3.g3:
            # 1 Start=Step
            # 2 Step=WHILE(Cond, Step)
            # 3 Step=inc()
            # 4 Cond=lt3()

            interp3 = HerbInterpret.make_stateful_interpreter(
                LocalStateDSL3.g3;
                target_module = LocalStateDSL3,
                cache_module  = @__MODULE__,
            )

            # WHILE(lt3(), inc())
            prog_while = @rulenode(2{4,3})

            @test interp3(prog_while, LocalStateDSL3.St(0)) == LocalStateDSL3.St(3)
            @test interp3(prog_while, LocalStateDSL3.St(2)) == LocalStateDSL3.St(3)

            # Vector-of-states
            outs = interp3(prog_while, [LocalStateDSL3.St(0), LocalStateDSL3.St(1), LocalStateDSL3.St(3)])
            @test outs == [LocalStateDSL3.St(3), LocalStateDSL3.St(3), LocalStateDSL3.St(3)]
        end

        @testset "Stateful interpreter with synthesized lambdas in external module" begin
            # Rule indices in LocalStateDSL4.g4:
            # 1  Start = Step
            # 2  Step  = apply(Func)
            # 3  Step  = IF(Cond, Step, Step)
            # 4  Step  = inc()
            # 5  Step  = dec()
            # 6  Cond  = iseven()
            # 7  Func  = plus1
            # 8  Func  = x -> double(x)
            # 9  Func  = x -> x + 1
            # 10 Func  = x -> double(Func(x)) + 1
            # 11 Func  = x -> Func(Func(x))

            interp = HerbInterpret.make_stateful_interpreter(
                LocalStateDSL4.g4;
                target_module = LocalStateDSL4,
                cache_module  = @__MODULE__,
            )

            # apply(plus1)
            prog_plus1 = @rulenode(1{2{7}})
            @test interp(prog_plus1, LocalStateDSL4.St(1)) == LocalStateDSL4.St(2)

            # apply(x -> double(x))
            prog_double = @rulenode(1{2{8}})
            @test interp(prog_double, LocalStateDSL4.St(3)) == LocalStateDSL4.St(6)

            # apply(x -> x + 1)
            prog_lambda_plus1 = @rulenode(1{2{9}})
            @test interp(prog_lambda_plus1, LocalStateDSL4.St(3)) == LocalStateDSL4.St(4)

            # apply(x -> double(plus1(x)) + 1)
            prog_nested = @rulenode(1{2{10{7}}})
            @test interp(prog_nested, LocalStateDSL4.St(3)) == LocalStateDSL4.St(9)

            # apply(x -> Func(Func(x))), Func = [x -> double(x), plus1] => double(plus1(x))
            prog_comp1 = @rulenode(1{2{11{8,7}}})
            @test interp(prog_comp1, LocalStateDSL4.St(3)) == LocalStateDSL4.St(8)

            # apply(x -> Func(Func(x))), Func = [plus1, x -> double(x)] => plus1(double(x))
            prog_comp2 = @rulenode(1{2{11{7,8}}})
            @test interp(prog_comp2, LocalStateDSL4.St(3)) == LocalStateDSL4.St(7)

            # IF(iseven(), apply(plus1), dec())
            prog_if = @rulenode(1{3{6,2{7},5}})
            @test interp(prog_if, LocalStateDSL4.St(2)) == LocalStateDSL4.St(3)
            @test interp(prog_if, LocalStateDSL4.St(3)) == LocalStateDSL4.St(2)

            # vector-of-states overload
            outs = interp(prog_nested, [LocalStateDSL4.St(0), LocalStateDSL4.St(5)])
            @test outs == [LocalStateDSL4.St(3), LocalStateDSL4.St(13)]
        end
    end
end