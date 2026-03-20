using HerbInterpret
using PythonCall

PythonExt = Base.get_extension(HerbInterpret, :PythonExt)
@assert PythonExt !== nothing
using .PythonExt: python_grammar
using HerbInterpret: unparse_rn


@testset "Unpasring python" begin
    gr = python_grammar
    @show gr
    rn = @rulenode 1{17{20},  2{4{9{15{18}}}, 4{9{15{19}}}}}
    unparsed_python = unparse_rn(rn, gr)
    # call our unparsed pyhton.
    # now we have a variable "a" in the environment
    pyexec(unparsed_python, Main)
    # evaluate "a" returning Julia Int type.
    a = pyeval(Int, "a", Main)
    @test a == 3
end