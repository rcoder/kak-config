#───────────────────────────────────#
#              @style               #
#───────────────────────────────────#

colorscheme gruvbox
add-highlighter global/ show-matching

hook global WinSetOption comment_line=(.*) %{
    add-highlighter -override window/todo regex "\Q%val{hook_param_capture_1}\E\h*(TODO:|FIXME:|NOTE:|XXX:)[^\n]*" 1:rgb:ff8c00+Fb
}

hook global WinCreate ^[^*]+$ %{ add-highlighter window/ number-lines -hlcursor }
hook global RegisterModified '/' %{ add-highlighter -override global/search regex "%reg{/}" 0:+b }

#───────────────────────────────────#
#              @system              #
#───────────────────────────────────#

try %{
    require-module x11
    set-option global grepcmd 'rg --follow --vimgrep'
} catch %{
    echo -debug "failed to load system modules, please run the following:"
    echo -debug "mkdir -p %val{config}/autoload && ln -s %val{runtime}/autoload %val{config}/autoload/sys"
}

#───────────────────────────────────#
#             @connect              #
#───────────────────────────────────#

try %{
    evaluate-commands %sh{
        if command -v kcr >/dev/null; then
            echo 'nop'
        else
            echo 'echo -debug "kcr binary missing"'
            echo 'fail'
        fi
    }

    define-command -hidden set-popup-alias %{
        alias global popup kitty-terminal
    }

    hook global ModuleLoaded kitty %{
        set-popup-alias
    }

    evaluate-commands %sh{ kcr init kakoune }

    map global user <ret> ' :connect-terminal nu<ret>' -docstring 'open terminal'

    declare-user-mode fzf

    map global normal <c-p> ':enter-user-mode fzf<ret>' -docstring 'fuzzy finder mode'
    map global fzf f ': + kcr-fzf-files<ret>' -docstring 'Open files'
    map global fzf b ': + kcr-fzf-buffers<ret>' -docstring 'Open buffers'
    map global fzf g ': + kcr-fzf-grep<ret>' -docstring 'Grep files'

    define-command nnn-persistent -params 0..1 -file-completion -docstring 'Open file with nnn' %{
        connect-terminal nnn %sh{echo "${@:-$(dirname "$kak_buffile")}"}
    }

    alias global nnn nnn-persistent
} catch %{
    echo -debug 'failed to initialize kakoune.cr'
}

#───────────────────────────────────#
#          @window manager          #
#───────────────────────────────────#

define-command setup-i3 -hidden %{
    require-module i3wm
    map global user w ': i3-mode<ret>' -docstring 'i3 mode'
    alias global new i3-new
    hook -group i3-hooks global KakBegin .* %{
        define-command -hidden set-i3-terminal-alias %{
            alias global terminal i3-terminal-b
            alias global terminal-l i3-terminal-l
            alias global terminal-r i3-terminal-r
            alias global terminal-b i3-terminal-b
            # TODO: implement this
            # alias global terminal-t i3-terminal-t
        }
        alias global set-terminal-alias set-i3-terminal-alias


        set-terminal-alias
    }
}

define-command setup-kitty -hidden %{
    map global user w ': kitty-mode<ret>' -docstring 'kitty mode'
    alias global new kitty-new
    hook -group kitty-hooks global KakBegin .* %{
        define-command -hidden set-kitty-terminal-alias %{
            alias global terminal kitty-terminal-b
            alias global terminal-l kitty-terminal-l
            alias global terminal-r kitty-terminal-r
            alias global terminal-b kitty-terminal-b
            alias global terminal-t kitty-terminal-t
        }
        alias global set-terminal-alias set-kitty-terminal-alias

        set-terminal-alias
    }
}

#───────────────────────────────────#
#             @options              #
#───────────────────────────────────#

set-option global startup_info_version 20200901
set-option global ui_options 'ncurses_assistant=cat' 'ncurses_set_title=false'
set-option global path '%/' './' '/usr/include'

#───────────────────────────────────#
#              @misc                #
#───────────────────────────────────#

# aliases
alias global rg grep

# restart
define-command restart -params 0..1 -file-completion -docstring 'restart instance of kakoune' %{
    nop %sh{ {
        sleep 0.1
        echo "k $1" | kitty @ --to=$kak_client_env_KITTY_LISTEN_ON send-text --stdin
    } > /dev/null 2>&1 < /dev/null & }
    kill
}

# editorconfig
hook global BufOpenFile .* %{ editorconfig-load }
hook global BufNewFile .* %{ editorconfig-load }

# leader
map global normal <space> , -docstring 'leader'
map global normal , <space> -docstring 'remove all selections except main'
map global normal <a-,> <a-space> -docstring 'remove main selection'

# formatting
map global user f ':format<ret>' -docstring 'Format'

# comment line
map global normal '#' ':comment-line<ret>' -docstring 'comment selected lines'
map global normal <a-#> ':comment-block<ret>' -docstring 'comment block'

# select under cursor
map global user S '<a-i>w*%s<c-r>/<ret>'

# wrap
map global normal = '|fmt -w $kak_opt_autowrap_column<ret>'

# delete
map global insert <c-l> '<del>'

# jump to left/right of selection
define-command swap-insert-side %{
    execute-keys -with-hooks %sh{
        selection="$kak_selection_desc"
        regex="([0-9]+)[.]([0-9]+),([0-9]+)[.]([0-9]+)"

        a1=$(printf %s "$selection" | sd -- "$regex" '$1')
        a2=$(printf %s "$selection" | sd -- "$regex" '$2')
        b1=$(printf %s "$selection" | sd -- "$regex" '$3')
        b2=$(printf %s "$selection" | sd -- "$regex" '$4')

        if [ "$a1" -eq "$b1" ]; then
            if [ "$a2" -gt "$b2" ]; then
                printf %s 'a'
            else
                printf %s 'i'
            fi
        elif [ "$a1" -gt "$b1" ]; then
            printf %s 'a'
        else
            printf %s 'i'
        fi
    }
}

map global insert <a-[> '<esc>: swap-insert-side<ret>'

#───────────────────────────────────#
#               @sql                #
#───────────────────────────────────#

declare-option str sql_db ''
declare-option str sql_user ''
declare-option str sql_pass ''
declare-option str sql_selection_cmd ''
declare-option str sql_file_cmd ''

define-command sql-exec-selection -docstring 'execute selection as sql' %{
    sql-test-inputs 'sql_selection_cmd' %opt{sql_selection_cmd}
    evaluate-commands %sh{
        # Create a temporary fifo for communication
        output=$(mktemp -d -t kak-sql-XXXXXXXX)/fifo
        cmd=$(printf %s "$kak_opt_sql_selection_cmd" | sd '\{sql_db\}' "$kak_opt_sql_db" | sd '\{sql_user\}' "$kak_opt_sql_user" | sd '\{sql_pass\}' "$kak_opt_sql_pass")
        mkfifo ${output}

        # parse selection
        selection=$(printf %s "$kak_selection" | sd "'" "'\\\''")

        # run command detached from the shell
        { eval "printf %s '$selection' | $cmd" > ${output}; } > /dev/null 2>&1 < /dev/null &

        # open in client
        echo "show-sql '$output'"
    }
}

define-command sql-exec-file -docstring 'execute file as sql' %{
    sql-test-inputs 'sql_file_cmd' %opt{sql_file_cmd}
    evaluate-commands %sh{
        # Create a temporary fifo for communication
        output=$(mktemp -d -t kak-sql-XXXXXXXX)/fifo
        cmd=$(printf %s "$kak_opt_sql_file_cmd" | sd '\{sql_db\}' "$kak_opt_sql_db" | sd '\{sql_user\}' "$kak_opt_sql_user" | sd '\{sql_pass\}' "$kak_opt_sql_pass")
        mkfifo ${output}

        # run command detached from the shell
        { eval "printf %s '$kak_buffile' | $cmd" > ${output}; } > /dev/null 2>&1 < /dev/null &

        # open in client
        echo "show-sql '$output'"
    }
}

define-command sql-test-inputs -hidden -params 2 %{
    evaluate-commands %sh{
        if [ -z "$2" ]; then
            echo "fail '$1 is not set'"
        elif [ -z "$kak_opt_sql_user" ]; then
            echo "fail 'sql_user is not set'"
        elif [ -z "$kak_opt_sql_db" ]; then
            echo "fail 'sql_db is not set'"
        elif [ -z "$kak_opt_sql_pass" ]; then
            echo "fail 'sql_pass is not set'"
        else
            echo "nop"
        fi
    }
}

define-command show-sql -hidden -params 1 -docstring 'show sql in output buffer' %{
    evaluate-commands %sh{
        # determine client
        client="$kak_client"
        if [ ! -z "$kak_opt_toolsclient" ] && printf %s "$kak_client_list" | rg -Fqw "$kak_opt_toolsclient"; then
            client="$kak_opt_toolsclient"
        fi

        # open in client
        echo "eval -client '$client' 'edit! -fifo $1 *sqlout*
            set-option buffer filetype sqlout
            hook buffer BufClose .* %{ nop %sh{ rm -r $(dirname $1)} }'" \
            | kak -p "${kak_session}"
    }
}

declare-user-mode sql

map global sql s ':sql-exec-selection<ret>' -docstring 'execute current selection'
map global sql f ':sql-exec-file<ret>' -docstring 'execute current file'

#───────────────────────────────────#
#            @filetypes             #
#───────────────────────────────────#

hook global BufCreate .*kitty[.]conf %{
    set-option buffer filetype ini
}

hook global BufCreate .*/kak/snippets/.* %{
    set-option buffer filetype snippet
}

hook global BufCreate .*[.]less %{
    set-option buffer filetype css
}

hook global WinSetOption filetype=sql %{
    map window user s ': enter-user-mode sql<ret>' -docstring 'sql mode'
    set-option window formatcmd "pg_format -"
    set-option window comment_line '--'
}

hook global WinSetOption filetype=json %{
    set-option window formatcmd "jq --monochrome-output '.'"
}

hook global WinSetOption filetype=elm %{
    set-option window formatcmd 'elm-format --stdin'
    # TODO: fix this for success
    set-option window makecmd "elm make src/Main.elm --output=/dev/null 2>&1 | kak -n -q -f '<percent>s<minus><minus><space>[\w|<space>]<plus><minus><plus><ret><a-semicolon><semicolon>i<ret><esc>Wdf<minus><semicolon>?\w<ret>Hdgll?^\d<plus>\|<ret>GiHdi<space><esc>f|a<space><esc><semicolon>?[^<space>]<ret>Hdxd<percent><a-R>gif|<a-f><space><semicolon>r:f|<semicolon>r:<a-F><space>Lc|<space><esc>giPi<space><esc>gi'"
}

hook global WinSetOption filetype=elixir %{
    set-option window formatcmd 'mix format -'
}

hook global WinSetOption filetype=rust %{
    set-option window formatcmd 'rustfmt'
}

hook global WinSetOption filetype=python %{
    set-option window formatcmd 'autopep8 -'
}

hook global WinSetOption filetype=nix %{
    set-option window formatcmd 'nixpkgs-fmt'
}

hook global WinSetOption filetype=(typescript|typescriptreact) %{
    set-option window makecmd "npx tsc --noEmit | rg 'TS\d+:' | sed -E 's/^([^\(]+)\(([0-9]+),([0-9]+)\)/\1:\2:\3/'"
}

hook global WinSetOption filetype=(typescript|typescriptreact|javascript|javascriptreact) %{
    set-option window lintcmd 'run() { cat "$1" | npx eslint -f ~/.npm-global/lib/node_modules/eslint-formatter-kakoune/index.js --stdin --stdin-filename "$kak_buffile";} && run'
    set-option window formatcmd "npx prettier --stdin-filepath %val{buffile}"
    hook window BufWritePost .* %{
        lint
    }
}

hook global WinSetOption filetype=(html) %{
    set-option window formatcmd "npx prettier --stdin-filepath %val{buffile}"
}

define-command filetype -params 1 -docstring 'Set the current filetype' %{
    set-option window filetype %arg{1}
}

define-command json %{ filetype 'json' }
define-command sql %{ filetype 'sql' }

#───────────────────────────────────#
#           @text objects           #
#───────────────────────────────────#

# TODO: finish command to select indentation without travelling past a newline after matching indentation
define-command -hidden text-object-indent %{
    # execute-keys -save-regs '/' -- 'Gh?\S<ret>hy/<c-r>"\S[^\n]*\n\n'
    execute-keys -save-regs '/' -- '<a-/>\n\n<c-r>"\S<ret>gh?\S<ret>Hygi?^<c-r>"\S[^\n]*\n\n<ret>K<a-x>'
}

#───────────────────────────────────#
#               @git                #
#───────────────────────────────────#

map global user g ': enter-user-mode git<ret>' -docstring 'git mode'

declare-user-mode git

declare-option -hidden bool git_blame_enabled false

define-command -hidden toggle-git-blame %{ evaluate-commands %sh{
    if [ "$kak_opt_git_blame_enabled" = 'true' ]; then
        printf %s 'git hide-blame; set-option window git_blame_enabled false'
    else
        printf %s 'git blame; set-option window git_blame_enabled true'
    fi
} }

define-command gitui -docstring 'open gitui as overlay on current buffer' %{
    alias global popup kitty-overlay
    connect-popup gitui
    set-popup-alias
}

map global git b ': toggle-git-blame<ret>' -docstring 'toggle blame'
map global git i ': git status<ret>' -docstring 'git status'
map global git c ': git commit<ret>' -docstring 'git commit'
map global git d ': git diff %val{buffile}<ret>' -docstring 'git diff (current file)'
map global git l ': git log -- %val{bufname}<ret>' -docstring 'git log (current file)'
map global git s ': enter-user-mode git-show<ret>' -docstring 'git show mode'
map global git u ': gitui<ret>' -docstring 'open gitui'

declare-user-mode git-show

define-command git-show-line-commit %{
    evaluate-commands %sh{
        line_commit=$(git blame -l -L "${kak_cursor_line},${kak_cursor_line}" -p -- "${kak_buffile}" | head -n 1 | awk '{print $1}')
        printf %s "git show ${line_commit}"
    }
}

map global git-show s ': git show %val{selection}<ret>' -docstring 'show current selection'
map global git-show l ": git-show-line-commit<ret>" -docstring 'show line commit'

#───────────────────────────────────#
#               @yank               #
#───────────────────────────────────#

define-command yank-line-commit -params 1 -docstring 'yank commit hash for current line' %{
    set-register %arg{1} %sh( git blame -l -L "${kak_cursor_line},${kak_cursor_line}" -p -- "${kak_buffile}" | head -n 1 | awk '{print $1}' )
}

declare-user-mode yank
map global user y ': enter-user-mode yank<ret>' -docstring 'yank mode'
map global yank b ': set-register %{"} %val{bufname}<ret>' -docstring 'yank bufname'
map global yank g ': yank-line-commit "<ret>' -docstring 'yank commit for current line'

#───────────────────────────────────#
#             whitespace            #
#───────────────────────────────────#

define-command clean-whitespace %{ execute-keys -draft '<percent>s^<space><plus>$<ret>d' }

#───────────────────────────────────#
#              @ide                 #
#───────────────────────────────────#

map global user h ': grep-previous-match<ret>' -docstring 'Jump to the previous grep match'
map global user l ': grep-next-match<ret>' -docstring 'Jump to the next grep match'
map global user H ': make-previous-error<ret>' -docstring 'Jump to the previous make error'
map global user L ': make-next-error<ret>' -docstring 'Jump to the next make error'

map global user k ': lint-previous-message<ret>' -docstring 'Jump to the previous lint message'
map global user j ': lint-next-message<ret>' -docstring 'Jump to the next lint message'

define-command ide %{
    # TODO: hacky, find a way to poll, remove sleeps
    rename-client main
    set-option global jumpclient main

    nop %sh{ {
        send() {
            kcr -c "$kak_client" -s "$kak_session" send -- "$@"
        }

        i3() {
            i3-msg -q "$@"
        }

        send alias global terminal i3-terminal-l
        send nnn; sleep 0.3
        send set-terminal-alias

        i3 resize set width 15ppt; sleep 0.1
        i3 focus right; sleep 0.1

        send i3-new-d ":rename-client<space>tools<ret>"; sleep 0.3
        send set global toolsclient tools

        i3 move up; sleep 0.1
        i3 resize set height 20ppt; sleep 0.1
        i3 focus down; sleep 0.1

        send connect-terminal nu; sleep 0.3

        i3 resize set height 25ppt; sleep 0.1
        i3 focus up

    } > /dev/null 2>&1 < /dev/null & }
}

#───────────────────────────────────#
#           @highlight              #
#───────────────────────────────────#
# https://github.com/mawww/config/blob/master/kakrc

declare-option -hidden regex curword
set-face global CurWord default,rgba:80808040

hook global NormalIdle .* %{
    eval -draft %{ try %{
        exec <space><a-i>w <a-k>\A\w+\z<ret>
        set-option buffer curword "\b\Q%val{selection}\E\b"
    } catch %{
        set-option buffer curword ''
    } }
}
add-highlighter global/ dynregex '%opt{curword}' 0:CurWord

#───────────────────────────────────#
#             @plugins              #
#───────────────────────────────────#

source "%val{config}/plugins/plug.kak/rc/plug.kak"

plug "andreyorst/plug.kak" noload

plug "kak-lsp/kak-lsp" do %{
    cargo install --locked --force --path .
} config %{
    # set global lsp_cmd "kak-lsp -s %val{session} -vvv --log /tmp/kak-lsp.log"
    declare-option -hidden str lsp_language ''

    set-option global lsp_hover_anchor true
    set-option global lsp_diagnostic_line_error_sign '✗'
    set-option global lsp_diagnostic_line_warning_sign '⚠'

    define-command lsp-hover-info -docstring 'show hover info' %{
      set-option buffer lsp_show_hover_format 'printf %s "${lsp_info}"'
      lsp-hover
    }

    define-command lsp-hover-diagnostics -docstring 'show hover diagnostics' %{
      set-option buffer lsp_show_hover_format 'printf %s "${lsp_diagnostics}"'
      lsp-hover
    }

    define-command lsp-restart -docstring 'restart lsp server' %{
        lsp-exit
        lsp-start
    }

    # TODO: would be nice to have <c-space> trigger explicit LSP completion
    # currently kak-lsp does not seem to add entry to <c-x> menu in insert mode

    hook global WinSetOption lsp_language=elm %{
        # TODO: remove after https://github.com/ul/kak-lsp/issues/40 resolved
        set-option buffer lsp_completion_fragment_start %{execute-keys <esc><a-h>s\$?[\w.]+.\z<ret>}
        set-option buffer lsp_completion_trigger %{ fail "completion disabled" }
    }

    hook global WinSetOption filetype=(elm|elixir|javascript|typescript|typescriptreact|javascriptreact|python|rust) %{
        echo -debug "initializing lsp for window"
        lsp-enable-window
        set-option window lsp_language %val{hook_param_capture_1}
        map window user ';' ':lsp-hover-info<ret>' -docstring 'hover'
        map window user ':' ':lsp-hover-diagnostics<ret>' -docstring 'diagnostics'
        map window user . ':lsp-code-actions<ret>' -docstring 'code actions'
        map window goto I '\:lsp-implementation<ret>' -docstring 'goto implementation'
        map window user <a-h> ':lsp-goto-previous-match<ret>' -docstring 'LSP goto previous'
        map window user <a-l> ':lsp-goto-next-match<ret>' -docstring 'LSP goto next'
        map window user <a-k> ':lsp-find-error --previous<ret>' -docstring 'goto previous LSP error'
        map window user <a-j> ':lsp-find-error<ret>' -docstring 'goto next LSP error'
        map window user r ':lsp-rename-prompt<ret>' -docstring 'rename'
    }

    hook global WinSetOption filetype=rust %{
        hook window -group rust-inlay-hints BufReload .* rust-analyzer-inlay-hints
        hook window -group rust-inlay-hints NormalIdle .* rust-analyzer-inlay-hints
        hook window -group rust-inlay-hints InsertIdle .* rust-analyzer-inlay-hints
        hook -once -always window WinSetOption filetype=.* %{
            remove-hooks window rust-inlay-hints
        }
    }
}

plug "andreyorst/smarttab.kak" defer smarttab %{
} config %{
    hook global WinSetOption filetype=(?!makefile)(?!snippet).* %{
        expandtab
        set-option window softtabstop %opt{indentwidth}
        hook window WinSetOption indentwidth=([0-9]+) %{
            set-option window softtabstop %val{hook_param_capture_1}
        }
    }
    hook global WinSetOption filetype=(makefile|snippet) noexpandtab
}

# for use with `man`
plug "eraserhd/kak-ansi" do %{
    make
}

plug "alexherbo2/auto-pairs.kak" defer auto-pairs %{
    auto-pairs-enable
} demand

plug "alexherbo2/replace-mode.kak" commit "a569d3df8311a0447e65348a7d48c2dea5415df0" config %{
    map global user R ': enter-replace-mode<ret>' -docstring 'Enter replace mode'
}

plug "occivink/kakoune-snippets" config %{
    set-option global snippets_auto_expand false

    define-command snippets-trigger-line -docstring 'Execute any snippet triggers in current line' %{
        execute-keys "giGls%opt{snippets_triggers_regex}<ret>:snippets-expand-trigger<ret>"
    }

    define-command snippets-trigger-line-start -docstring 'Execute any snippet triggers before cursor' %{
        execute-keys ";Gis%opt{snippets_triggers_regex}<ret>:snippets-expand-trigger<ret>"
    }

    define-command snippets-trigger-last-word -docstring 'Execute any snippet triggers in last WORD before cursor' %{
        execute-keys ";b<a-I>s%opt{snippets_triggers_regex}<ret>:snippets-expand-trigger<ret>"
    }

    define-command -hidden reenter-insert-mode -docstring 're-enter insert mode after replacing snippet' %{
        execute-keys -save-regs '"' -with-hooks %sh{
            if [ "1" -eq "${kak_selection_length}" ]; then
                printf %s 'i'
            else
                printf %s 'c'
            fi
        }
    }

    # move to next placeholder
    map global normal <a-space> ': snippets-select-next-placeholders<ret>'
    map global insert <a-space> '<esc>: snippets-select-next-placeholders<ret>: reenter-insert-mode<ret>'

    # triggers
    map global insert <a-ret> '<esc>: snippets-trigger-last-word<ret>: reenter-insert-mode<ret>'
    map global normal <a-ret> ': snippets-trigger-last-word<ret>' -docstring 'trigger snippets in line'
}

plug "JJK96/kakoune-emmet" config %{
    # FIXME: this fails when there is any other code on that line
    # ideally I would like this to go back until it hits ^ or the first
    # whitespace that is not inside of pairs ([],{},"",'')
    map global insert <a-e> '<esc>giGl: emmet<ret>i'
}

plug "https://gitlab.com/Screwtapello/kakoune-state-save" config %{
    hook global KakBegin .* %{
        state-save-reg-load colon
        state-save-reg-load pipe
        state-save-reg-load slash
    }

    hook global KakEnd .* %{
        state-save-reg-save colon
        state-save-reg-save pipe
        state-save-reg-save slash
    }
}

plug "Parasrah/kitty.kak" defer kitty %{
    define-command nnn-current -params 0..1 -file-completion -docstring 'Open file with nnn (volatile)' %{
        kitty-overlay sh -c %{
            PAGER=""
            kak_buffile=$1 kak_session=$2 kak_client=$3
            shift 3
            kak_pwd="${@:-$(dirname "${kak_buffile}")}"
            filename=$(nnn -p - "${kak_pwd}")
            kak_cmd="evaluate-commands -client $kak_client edit $filename"
            echo $kak_cmd | kak -p $kak_session
        } -- %val{buffile} %val{session} %val{client} %arg{@}
    }

    define-command nvim -docstring 'Open current buffer in neovim' %{
        kitty-overlay sh -c %{
            kak_buffile=$1
            cursor_line=$2
            nvim $kak_buffile +$cursor_line -c "execute 'normal! zz'"
        } -- %val{buffile} %val{cursor_line}
    }

    map global normal <minus> ': nnn-current<ret>' -docstring 'open up nnn for the current buffer directory'
}

plug "Parasrah/filelist.kak"

plug "Parasrah/casing.kak"

plug "Parasrah/clipboard.kak" defer clipboard %{
    declare-user-mode copy
    map global user c ':enter-user-mode copy<ret>' -docstring 'copy mode'
    map global copy b ' :set-register %opt{clipboard_register} %val{bufname}<ret>' -docstring 'copy bufname'
    map global copy g ' :yank-line-commit %opt{clipboard_register}<ret>' -docstring 'copy commit for current line'

    # TODO: create keymap for "py and "pp
} demand

plug "Parasrah/hestia.kak" defer hestia %{
    set-option global hestia_key 'B909C2B388D31FD5CBCAE1A94CBE600F7547E797'

    hestia-load-machine
    hestia-load-project
} demand

plug "Parasrah/i3.kak" config %{
    evaluate-commands %sh{
        if pgrep -x "i3" >/dev/null; then
            echo 'setup-i3'
        else
            echo 'nop'
        fi
    }
}
