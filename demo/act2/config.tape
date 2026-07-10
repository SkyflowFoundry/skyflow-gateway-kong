# config.tape — shared VHS look for the Act 2 terminal demo.
# Source this at the very TOP of a tape (every `Set` must precede the first
# Type/Enter/output command). Copied from the vhs-demos skill, with Height bumped
# for a coding agent's taller output.
Set Shell zsh
Set FontFamily "JetBrains Mono"   # installed locally; brew install --cask font-jetbrains-mono
Set FontSize 22
Set Width 1200
Set Height 900                    # coding-agent output needs vertical room (skill default is 700)
Set Padding 40
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms
Set WindowBar Colorful
Set BorderRadius 10
Set WaitTimeout 30s
# Our demos set PS1='$ '. Bare `Wait` defaults to matching a ">" prompt, so tell it
# to match our prompt instead — otherwise a bare `Wait` times out.
Set WaitPattern /\$\s?$/
