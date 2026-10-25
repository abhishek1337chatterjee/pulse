function __pulse_card_bullets --description "Print a bold heading, then one '• item' row per item; args: heading item ..."
    echo (set_color --bold)$argv[1](set_color normal)
    for item in $argv[2..-1]
        echo "• $item"
    end
end
