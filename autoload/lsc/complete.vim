" Use InsertCharPre to reliably know what is typed, but don't send the
" completion request until the file reflects the inserted character. Track typed
" characters in `s:next_char` and use CursorMovedI to act on the change.
"
" Every typed character can potentially start a completion request:
" - "Trigger" characters (as specified during initialization) always start a
"   completion request when they are typed
" - Characters that match '\w' start a completion in words of at least length 3

function! lsc#complete#insertCharPre() abort
  let s:next_char = v:char
endfunction

function! lsc#complete#textChanged() abort
  if &paste | return | endif
  if !g:lsc_enable_autocomplete | return | endif
  " This may be <BS> or similar if not due to a character typed
  if empty(s:next_char) | return | endif
  call s:typedCharacter()
  let s:next_char = ''
endfunction

function! s:typedCharacter() abort
  if s:isTrigger(s:next_char)
      \ || (s:isCompletable() && !has_key(s:completion_waiting, &filetype))
    call s:startCompletion(v:true)
  else
    let s:completion_canceled = v:true
  endif
endfunction

if !exists('s:initialized')
  let s:next_char = ''
  " filetype -> ?, used as a Set
  let s:completion_waiting = {}
  let s:completion_canceled = v:false
  let s:initialized = v:true
endif

" Clean state associated with a server.
function! lsc#complete#clean(filetype) abort
  call s:MarkNotCompleting(a:filetype)
endfunction

function! s:MarkCompleting(filetype) abort
  let s:completion_waiting[a:filetype] = v:true
endfunction

function! s:MarkNotCompleting(filetype) abort
  if has_key(s:completion_waiting, a:filetype)
    unlet s:completion_waiting[a:filetype]
  endif
endfunction

function! s:isTrigger(char) abort
  for l:server in lsc#server#current()
    if index(l:server.capabilities.completion.triggerCharacters, a:char) >= 0
      return v:true
    endif
  endfor
  return v:false
endfunction

augroup LscCompletion
  autocmd!
  autocmd CompleteDone * let b:lsc_is_completing = v:false
      \ | silent! unlet b:lsc_completion
augroup END

" Whether the cursor follows a minimum count of  word characters, and completion
" isn't already in progress.
"
" Minimum length can be configured with `g:lsc_autocomplete_length`.
function! s:isCompletable() abort
  if exists('b:lsc_is_completing') && b:lsc_is_completing
    return v:false
  endif
  if s:next_char !~# '\w' | return v:false | endif
  let l:cur_col = col('.')
  let l:min_length = exists('g:lsc_autocomplete_length') ?
      \ g:lsc_autocomplete_length : 3
  if l:min_length == v:false | return v:false | endif
  if l:cur_col < (l:min_length + 1) | return v:false | endif
  let word = getline('.')[l:cur_col - (l:min_length + 1):l:cur_col - 2]
  return word =~# '^\w*$'
endfunction

function! s:startCompletion(isAuto) abort
  let b:lsc_is_completing = v:true
  let s:completion_canceled = v:false
  call s:MarkCompleting(&filetype)
  call lsc#file#flushChanges()
  let l:params = lsc#params#documentPosition()
  " TODO handle multiple servers
  let l:server = lsc#server#forFileType(&filetype)[0]
  call l:server.request('textDocument/completion', l:params,
      \ lsc#util#gateResult('Complete',
      \     function('<SID>OnResult', [a:isAuto]), function('<SID>OnSkip')))
endfunction

function! s:OnResult(isAuto, completion) abort
  call s:MarkNotCompleting(&filetype)
  if s:completion_canceled
    let b:lsc_is_completing = v:false
  endif
  let completions = s:CompletionItems(a:completion)
  if (a:isAuto)
    call s:SuggestCompletions(completions)
  else
    let b:lsc_completion = completions
  endif
endfunction

" TODO this could be the wrong buffer?
function! s:OnSkip(completion) abort
  call s:MarkNotCompleting(&filetype)
  let b:lsc_is_completing = v:false
endfunction

function! s:SuggestCompletions(completion) abort
  if mode() !=# 'i' || len(a:completion.items) == 0
    let b:lsc_is_completing = v:false
    return
  endif
  let start = s:FindStart(a:completion)
  let suggestions = a:completion.items
  if start != col('.')
    let base = getline('.')[start - 1:col('.') - 2]
    let suggestions = s:FindSuggestions(base, a:completion)
  endif
  call s:SetCompleteOpt()
  if exists('#User#LSCAutocomplete')
    doautocmd <nomodeline> User LSCAutocomplete
  endif
  call complete(start, suggestions)
endfunction

function! s:SetCompleteOpt() abort
  if type(g:lsc_auto_completeopt) == type('')
    " Set completeopt locally exactly like the user wants
    execute 'setl completeopt='.g:lsc_auto_completeopt
  elseif (type(g:lsc_auto_completeopt) == type(v:true)
      \ || type(g:lsc_auto_completeopt) == type(0))
      \ && g:lsc_auto_completeopt
    " Set the options that impact behavior for autocomplete use cases without
    " touching other like `preview`
    setl completeopt-=longest
    setl completeopt+=menu,menuone,noinsert,noselect
  endif
endfunction

function! lsc#complete#complete(findstart, base) abort
  if !exists('b:lsc_completion')
    let l:searchStart = reltime()
    call s:startCompletion(v:false)
    let l:timeout = get(g:, 'lsc_complete_timeout', 5)
    while !exists('b:lsc_completion')
        \ && reltimefloat(reltime(l:searchStart)) <= l:timeout
      sleep 100m
    endwhile
    if !exists('b:lsc_completion')
      return -1
    endif
  endif
  if a:findstart
    if len(b:lsc_completion.items) == 0
      unlet b:lsc_completion
      return -3
    endif
    return  s:FindStart(b:lsc_completion) - 1
  else
    return s:FindSuggestions(a:base, b:lsc_completion)
  endif
endfunction

" Finds the 1-based index of the first character in the completion.
function! s:FindStart(completion) abort
  if has_key(a:completion, 'start_col')
    return a:completion.start_col
  endif
  return s:GuessCompletionStart()
endfunction

" Finds the 1-based index of the character after the last non word character
" behind the cursor.
function! s:GuessCompletionStart() abort
  let search = col('.') - 2
  let line = getline('.')
  while search > 0
    let char = line[search]
    if char !~# '\w'
      return search + 2
    endif
    let search -= 1
  endwhile
  return 1
endfunction

function! s:FindSuggestions(base, completion) abort
  let items = copy(a:completion.items)
  if len(a:base) == 0 | return items | endif
  return filter(items, {_, item -> s:MatchSuggestion(a:base, item)})
endfunction

function! s:MatchSuggestion(base, suggestion) abort
  let word = a:suggestion
  if type(word) == type({}) | let word = word.word | endif
  return word =~? a:base
endfunction

" Normalize LSP completion suggestions to the format used by vim.
"
" Returns a dict with:
" `items`: The vim complete-item values
" `start_col`: The start of the first range found, if any, in the suggestions
"
" Since different suggestions could, in theory, specify different ranges
" autocomplete behavior could be incorrect since vim `complete` only allows a
" single start columns for every suggestion.
function! s:CompletionItems(completion_result) abort
  let completion_items = []
  if type(a:completion_result) == type([])
    let completion_items = a:completion_result
  elseif type(a:completion_result) == type({})
    let completion_items = a:completion_result.items
  endif
  call map(completion_items, {_, item -> s:CompletionItem(item)})
  let completion = {'items' : completion_items}
  for item in completion_items
    if has_key(item, 'start_col')
      let completion.start_col = item.start_col
      break
    endif
  endfor
  return completion
endfunction

" Translate from the LSP representation to the Vim representation of a
" completion item.
"
" `word` suggestions are taken from the highest priority field according to
" order `textEdit` > `insertText` > `label`.
" `label` is always expected to be set and is used as the `abbr` shown in the
" popupmenu. This may be different from the inserted text.
function! s:CompletionItem(completion_item) abort
  let item = {'abbr': a:completion_item.label, 'icase': 1, 'dup': 1}
  if has_key(a:completion_item, 'textEdit')
      \ && type(a:completion_item.textEdit) == type({})
      \ && has_key(a:completion_item.textEdit, 'newText')
    let item.word = a:completion_item.textEdit.newText
    let item.start_col = a:completion_item.textEdit.range.start.character + 1
  elseif has_key(a:completion_item, 'insertText')
      \ && !empty(a:completion_item.insertText)
    let item.word = a:completion_item.insertText
  else
    let item.word = a:completion_item.label
  endif
  if has_key(a:completion_item, 'insertTextFormat') && a:completion_item.insertTextFormat == 2
    let item.user_data = json_encode({
          \ 'snippet': item.word,
          \ 'snippet_trigger': item.word
          \ })
  endif
  if has_key(a:completion_item, 'kind')
    let item.kind = s:CompletionItemKind(a:completion_item.kind)
  endif
  if has_key(a:completion_item, 'detail') && a:completion_item.detail != v:null
    let detail_lines = split(a:completion_item.detail, "\n")
    if len(detail_lines) > 0
      let item.menu = detail_lines[0]
    endif
  endif
  if has_key(a:completion_item, 'documentation')
    let documentation = a:completion_item.documentation
    if type(documentation) == type('')
      let item.info = documentation
    elseif type(documentation) == type({}) && has_key(documentation, 'value')
      let item.info = documentation.value
    endif
  endif
  return item
endfunction

function! s:CompletionItemKind(completion_kind) abort
  if a:completion_kind ==  2
      \ || a:completion_kind == 3
      \ || a:completion_kind == 4
    " Method, Function, Constructor
    return 'f'
  elseif a:completion_kind == 5 " Field
    return 'm'
  elseif a:completion_kind == 6 " Variable
    return 'v'
  elseif a:completion_kind == 7
      \ || a:completion_kind == 8
      \ || a:completion_kind == 13
    " Class, Interface, Enum
    return 't'
  elseif a:completion_kind == 14
      \ || a:completion_kind == 11
      \ || a:completion_kind == 12
      \ || a:completion_kind == 1
      \ || a:completion_kind == 16
    " Keyword, Unit, Value, Text, Color
    return 'd'
  endif
  " Many kinds are unmapped
  return ''
endfunction
