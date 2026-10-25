function __pulse_card_pairs --description "Print a bold heading, then 'name  description' rows with names in cyan; args: heading name desc ..."
    set -l heading $argv[1]
    set -l pairs $argv[2..-1]

    # Fish has no step slicing, so pick every second item by index.
    set -l name_indexes (seq 1 2 (count $pairs))
    set -l name_width (math "max($(string length -- $pairs[$name_indexes] | string join ,)) + 2")

    echo (set_color --bold)$heading(set_color normal)
    for index in $name_indexes
        set -l name (string pad -r -w $name_width -- $pairs[$index])
        echo (set_color cyan)$name(set_color normal)$pairs[(math $index + 1)]
    end
end
