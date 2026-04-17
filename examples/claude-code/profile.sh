eval "$(direnv hook bash)"

if [ -f ~/.config/claude-code.env ]; then
    set -a
    source ~/.config/claude-code.env
    set +a
fi
