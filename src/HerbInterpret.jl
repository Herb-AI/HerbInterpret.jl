module HerbInterpret

using DataStructures # Queue

using HerbCore
using HerbGrammar
using HerbSpecification

include("interpreter.jl")

include("angelic_conditions/bit_trie.jl")
include("angelic_conditions/angelic_config.jl")
include("angelic_conditions/execute_angelic.jl")

export 
    SymbolTable,
    interpret,

    execute_on_input,
    update_✝γ_path,
    CodePath,

    create_angelic_expression,
    ConfigAngelic,
    execute_angelic_on_input,
    get_code_paths!,

    BitTrie,
    BitTrieNode,
    trie_add!,
    trie_contains,

    passes_the_same_tests_or_more,
    update_passed_tests!

end # module HerbInterpret
