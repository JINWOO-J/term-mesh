# vim:ft=zsh
#
# term-mesh ZDOTDIR bootstrap for zsh.

# TEST: define a bare function at the very top — does it survive to .zshrc?
_tm_test_survive() { builtin print "alive"; }
builtin print -- "[tm-zshenv] TOP _tm_test=$(builtin whence -w _tm_test_survive 2>&1) ZDOTDIR=${ZDOTDIR:-unset} GHOSTTY_ZSH_ZDOTDIR=${GHOSTTY_ZSH_ZDOTDIR:-unset}" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null

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

builtin print -- "[tm-zshenv] after-restore ZDOTDIR=${ZDOTDIR:-unset}" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null

{
    builtin typeset _termmesh_file="${ZDOTDIR-$HOME}/.zshenv"
    builtin print -- "[tm-zshenv] sourcing user=$_termmesh_file" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    [[ ! -r "$_termmesh_file" ]] || builtin source -- "$_termmesh_file"
    builtin print -- "[tm-zshenv] after-user-zshenv _tm_test=$(builtin whence -w _tm_test_survive 2>&1)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
} always {
    builtin print -- "[tm-zshenv] always-start interactive=$([[ -o interactive ]] && echo y || echo n) _tm_test=$(builtin whence -w _tm_test_survive 2>&1)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    if [[ -o interactive ]]; then
        if [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
            builtin typeset _termmesh_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            if [[ -r "$_termmesh_ghostty" ]]; then
                builtin source -- "$_termmesh_ghostty"
                builtin print -- "[tm-zshenv] after-ghostty _tm_test=$(builtin whence -w _tm_test_survive 2>&1) _ghostty_state=${_ghostty_state:-unset}" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
            fi
        fi

        if [[ "${TERMMESH_SHELL_INTEGRATION:-${CMUX_SHELL_INTEGRATION:-1}}" != "0" && -n "${TERMMESH_SHELL_INTEGRATION_DIR:-${CMUX_SHELL_INTEGRATION_DIR:-}}" ]]; then
            builtin typeset _termmesh_integ="${TERMMESH_SHELL_INTEGRATION_DIR:-$CMUX_SHELL_INTEGRATION_DIR}/term-mesh-zsh-integration.zsh"
            if [[ -r "$_termmesh_integ" ]]; then
                builtin source -- "$_termmesh_integ"
                builtin print -- "[tm-zshenv] after-integ _termmesh_send=$(builtin whence -w _termmesh_send 2>&1) _tm_test=$(builtin whence -w _tm_test_survive 2>&1)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
            fi
        fi
    fi
    builtin print -- "[tm-zshenv] always-end _termmesh_send=$(builtin whence -w _termmesh_send 2>&1) _tm_test=$(builtin whence -w _tm_test_survive 2>&1)" >> /tmp/term-mesh-zshenv-debug.log 2>/dev/null
    builtin unset _termmesh_file _termmesh_ghostty _termmesh_integ
}
