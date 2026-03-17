# vim:ft=zsh
#
# ZDOTDIR wrapper: source the user's .zprofile, then restore ZDOTDIR to the
# integration dir so that .zshrc also loads from here (where we can finally
# inject term-mesh integration after Ghostty's always block has run).

# Save integration dir before restoring user ZDOTDIR.
builtin typeset _termmesh_integ_dir="$ZDOTDIR"

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${TERMMESH_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$TERMMESH_ZSH_ZDOTDIR"
    builtin unset TERMMESH_ZSH_ZDOTDIR
elif [[ -n "${CMUX_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$CMUX_ZSH_ZDOTDIR"
    builtin unset CMUX_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _termmesh_file="${ZDOTDIR-$HOME}/.zprofile"
[[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"

# Restore ZDOTDIR to integration dir so .zshrc loads from here.
if [[ -n "$_termmesh_integ_dir" ]]; then
    builtin export ZDOTDIR="$_termmesh_integ_dir"
fi
builtin unset _termmesh_file _termmesh_integ_dir
