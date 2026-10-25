function __pulse_card --description "Draw a rounded box titled argv[1] around the remaining lines"
    set -l title $argv[1]
    set -l lines $argv[2..-1]

    # Visible length skips colour codes, so coloured rows still line up.
    set -l widest (math "max($(string length --visible -- "$title  " $lines | string join ,))")
    set -l inner_width (math $widest + 4)

    echo "╭─ $title "(string repeat -n (math $inner_width - (string length -- $title) - 3) ─)"╮"
    for line in $lines
        set -l padding (string repeat -n (math $widest - (string length --visible -- "$line")) ' ')
        echo "│  $line$padding  │"
    end
    echo "╰"(string repeat -n $inner_width ─)"╯"
end
