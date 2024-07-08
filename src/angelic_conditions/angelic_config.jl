"""
    struct ConfigAngelic

A configuration struct for angelic conditions. Includes both generation- and evaluation-specific parameters.

# Fields
- `max_time::Float16`: The maximum time allowed for resolving a single angelic expression.
- `boolean_expr_max_depth::Int`: The maximum depth of boolean expressions when resolving angelic conditions.
- `max_execute_attempts::Int`: The maximal attempts of executing the program with angelic evaluation.
- `max_allowed_fails::Float16`: The maximum allowed fraction of failed tests during evaluation before short-circuit failure.
- `angelic_rulenode::Union{Nothing,RuleNode}`: The angelic rulenode. Used to replace angelic conditions/holes right before evaluation.

"""
@kwdef mutable struct ConfigAngelic
    max_time::Float16 = 0.1
    boolean_expr_max_depth::Int64 = 3
    max_execute_attempts::Int = 55
    max_allowed_fails::Float16 = 0.75
    angelic_rulenode::Union{Nothing,RuleNode} = nothing
end