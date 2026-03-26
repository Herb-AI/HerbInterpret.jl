@testitem "Quality tests" begin
    using Aqua
    @testset "Aqua" Aqua.test_all(HerbInterpret)
end
