function pulse-docs --description "Open the pulse internals docs in a browser"
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
