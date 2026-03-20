using MLStyle: @match

const HI = HerbInterpret

const python_grammar = @csgrammar begin

    # simple assignments
    assignmen = variable = sum
    # Arithmetic operators``
    # --------------------

    sum = sum + term 
    sum = sum - term 
    sum = term 

    term = term * factor |
        term / factor |
        term // factor |
        term % factor |
        factor

    factor = +factor |
        -factor |
        ~factor |
        signed_number |  
        variable
    
    signed_number = NUMBER |
        -NUMBER

    variable = VARNAME
    NUMBER = 1
    NUMBER = 2
    VARNAME = a
end

function HI.unparse_rn(rn::RuleNode, grammar::AbstractGrammar=python_grammar)
    
    return @match grammar.rules[rn.ind] begin
        # assume that all 2-element operations go inorder. So +{a, b} turns into a + b
        # treat exceptions separately.
        :($lhs = $rhs) => begin 
            @assert length(rn.children) == 2 "Supplied a rule $rn with incorrect number of children."
            HI.unparse_rn(rn.children[1]) * " = " * HI.unparse_rn(rn.children[2], grammar)
            end
        :($op($t1, $t2)) => begin
            @assert length(rn.children) == 2 "Supplied a rule $rn with incorrect number of children."
            #TODO: check types here
            HI.unparse_rn(rn.children[1], grammar) * string(op) * HI.unparse_rn(rn.children[2], grammar)
        end
        # all 1-element operations go in preorder
        :($op($t)) => begin
            @assert length(rn.children) == 1 "Supplied a rule $rn with incorrect number of children."
            string(op) * HI.unparse_rn(rn.children[1], grammar)
        end
        # current grammar has rules with 1 child at most unless there is an operation. 
        :($x) && if length(rn.children) == 1 end => HI.unparse_rn(only(rn.children))
        :($x) && if length(rn.children) >  2 end => begin
            @warn "Unexpected number of children in rule $rn."
        end
        :($x) => string(x)
    end

end