# vim:ft=zsh
#
# ZDOTDIR wrapper: source the user's .zshrc, then load term-mesh integration.
# This runs AFTER Ghostty's .zshenv always block, so functions defined here
# will not be cleared.

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

builtin print -- "[tm-zshrc] loaded ZDOTDIR=$ZDOTDIR" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null

builtin typeset _termmesh_file="${ZDOTDIR-$HOME}/.zshrc"
[[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"

# Load term-mesh integration (after Ghostty's always block has completed).
if [[ -o interactive && "${TERMMESH_SHELL_INTEGRATION:-${CMUX_SHELL_INTEGRATION:-1}}" != "0" && -n "${TERMMESH_SHELL_INTEGRATION_DIR:-${CMUX_SHELL_INTEGRATION_DIR:-}}" ]]; then
    builtin typeset _termmesh_integ="${TERMMESH_SHELL_INTEGRATION_DIR:-$CMUX_SHELL_INTEGRATION_DIR}/term-mesh-zsh-integration.zsh"
    builtin print -- "[tm-zshrc] integ=$_termmesh_integ exists=$([[ -r "$_termmesh_integ" ]] && echo yes || echo no) _termmesh_send=$(builtin whence -w _termmesh_send 2>&1)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    if [[ -r "$_termmesh_integ" ]] && ! builtin whence -w _termmesh_send >/dev/null 2>&1; then
        builtin source -- "$_termmesh_integ"
        builtin print -- "[tm-zshrc] sourced OK _termmesh_send=$(builtin whence -w _termmesh_send 2>&1)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    fi
fi

builtin unset _termmesh_file _termmesh_integ
