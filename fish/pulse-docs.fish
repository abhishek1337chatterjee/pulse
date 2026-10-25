function pulse-docs --description "Open the pulse internals docs in a browser"
    # Help card data: command, description pairs, then tips.
    set -l help_commands \
        "pulse-docs" "Open docs/index.html in your browser" \
        "pulse-docs help" "Show this help"
    set -l help_tips \
        "Docs = landing page + claude-stats, battery-stats, internals." \
        "No xdg-open? It prints the path to open by hand."

    switch "$argv[1]"
        case help -h --help
            __pulse_card "pulse-docs help" (__pulse_card_pairs Commands $help_commands) "" (__pulse_card_bullets Tips $help_tips)
            return 0
        case ''
        case '*'
            printf "Unknown command '%s'.\n\n" $argv[1]
            pulse-docs help
            return 1
    end

    set -l doc "$HOME/Documents/pulse/docs/index.html"
    if not test -f "$doc"
        echo "pulse-docs: file not found at $doc"
        echo "  did you clone pulse to ~/Documents/pulse and run install.sh?"
        return 1
    end
    if command -q xdg-open
        xdg-open "$doc" >/dev/null 2>&1 &
        disown
        echo "opened $doc"
    else
        echo "$doc"
        echo "(no xdg-open found — open the path manually)"
    end
end
