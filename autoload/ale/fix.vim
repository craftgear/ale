" FIXME: Switch to using the global buffer data dictionary instead.
" Cleanup will work better if there isn't a second Dictionary we have to work
" with.
let s:buffer_data = {}
let s:job_info_map = {}

function! s:GatherOutput(job_id, line) abort
    if has_key(s:job_info_map, a:job_id)
        call add(s:job_info_map[a:job_id].output, a:line)
    endif
endfunction

function! ale#fix#ApplyQueuedFixes() abort
    let l:buffer = bufnr('')
    let l:data = get(s:buffer_data, l:buffer, {'done': 0})

    if !l:data.done
        return
    endif

    call remove(s:buffer_data, l:buffer)
    let l:lines = getbufline(l:buffer, 1, '$')

    if l:data.lines_before != l:lines
        echoerr 'The file was changed before fixing finished'
        return
    endif

    if l:data.lines_before == l:data.output
        " Don't modify the buffer if nothing has changed.
        return
    endif

    call setline(1, l:data.output)

    let l:start_line = len(l:data.output) + 1
    let l:end_line = len(l:lines)

    if l:end_line >= l:start_line
        let l:save = winsaveview()
        silent execute l:start_line . ',' . l:end_line . 'd'
        call winrestview(l:save)
    endif

    " If ALE linting is enabled, check for problems with the file again after
    " fixing problems.
    if g:ale_enabled
        call ale#Queue(g:ale_lint_delay)
    endif
endfunction

function! s:ApplyFixes(buffer, output) abort
    call ale#fix#RemoveManagedFiles(a:buffer)

    let s:buffer_data[a:buffer].output = a:output
    let s:buffer_data[a:buffer].done = 1

    " We can only change the lines of a buffer which is currently open,
    " so try and apply the fixes to the current buffer.
    call ale#fix#ApplyQueuedFixes()
endfunction

function! s:HandleExit(job_id, exit_code) abort
    if !has_key(s:job_info_map, a:job_id)
        return
    endif

    let l:job_info = remove(s:job_info_map, a:job_id)

    if has_key(l:job_info, 'file_to_read')
        let l:job_info.output = readfile(l:job_info.file_to_read)
    endif

    call s:RunFixer({
    \   'buffer': l:job_info.buffer,
    \   'input': l:job_info.output,
    \   'callback_list': l:job_info.callback_list,
    \   'callback_index': l:job_info.callback_index + 1,
    \})
endfunction

function! ale#fix#ManageDirectory(buffer, directory) abort
    call add(s:buffer_data[a:buffer].temporary_directory_list, a:directory)
endfunction

function! ale#fix#RemoveManagedFiles(buffer) abort
    if !has_key(s:buffer_data, a:buffer)
        return
    endif

    " We can't delete anything in a sandbox, so wait until we escape from
    " it to delete temporary files and directories.
    if ale#util#InSandbox()
        return
    endif

    " Delete directories like `rm -rf`.
    " Directories are handled differently from files, so paths that are
    " intended to be single files can be set up for automatic deletion without
    " accidentally deleting entire directories.
    for l:directory in s:buffer_data[a:buffer].temporary_directory_list
        call delete(l:directory, 'rf')
    endfor

    let s:buffer_data[a:buffer].temporary_directory_list = []
endfunction

function! s:CreateTemporaryFileForJob(buffer, temporary_file, input) abort
    if empty(a:temporary_file)
        " There is no file, so we didn't create anything.
        return 0
    endif

    let l:temporary_directory = fnamemodify(a:temporary_file, ':h')
    " Create the temporary directory for the file, unreadable by 'other'
    " users.
    call mkdir(l:temporary_directory, '', 0750)
    " Automatically delete the directory later.
    call ale#fix#ManageDirectory(a:buffer, l:temporary_directory)
    " Write the buffer out to a file.
    call writefile(a:input, a:temporary_file)

    return 1
endfunction

function! s:RunJob(options) abort
    let l:buffer = a:options.buffer
    let l:command = a:options.command
    let l:input = a:options.input
    let l:output_stream = a:options.output_stream
    let l:read_temporary_file = a:options.read_temporary_file

    let [l:temporary_file, l:command] = ale#command#FormatCommand(l:buffer, l:command, 1)
    call s:CreateTemporaryFileForJob(l:buffer, l:temporary_file, l:input)

    let l:command = ale#job#PrepareCommand(l:command)
    let l:job_options = {
    \   'mode': 'nl',
    \   'exit_cb': function('s:HandleExit'),
    \}

    let l:job_info = {
    \   'buffer': l:buffer,
    \   'output': [],
    \   'callback_list': a:options.callback_list,
    \   'callback_index': a:options.callback_index,
    \}

    if l:read_temporary_file
        " TODO: Check that a temporary file is set here.
        let l:job_info.file_to_read = l:temporary_file
    elseif l:output_stream ==# 'stderr'
        let l:job_options.err_cb = function('s:GatherOutput')
    elseif l:output_stream ==# 'both'
        let l:job_options.out_cb = function('s:GatherOutput')
        let l:job_options.err_cb = function('s:GatherOutput')
    else
        let l:job_options.out_cb = function('s:GatherOutput')
    endif

    if get(g:, 'ale_emulate_job_failure') == 1
        let l:job_id = 0
    elseif get(g:, 'ale_run_synchronously') == 1
        " Find a unique Job value to use, which will be the same as the ID for
        " running commands synchronously. This is only for test code.
        let l:job_id = len(s:job_info_map) + 1

        while has_key(s:job_info_map, l:job_id)
            let l:job_id += 1
        endwhile
    else
        let l:job_id = ale#job#Start(l:command, l:job_options)
    endif

    if l:job_id == 0
        return 0
    endif

    let s:job_info_map[l:job_id] = l:job_info

    if get(g:, 'ale_run_synchronously') == 1
        " Run a command synchronously if this test option is set.
        let l:output = systemlist(
        \   type(l:command) == type([])
        \   ?  join(l:command[0:1]) . ' ' . ale#Escape(l:command[2])
        \   : l:command
        \)

        if !l:read_temporary_file
            let s:job_info_map[l:job_id].output = l:output
        endif

        call l:job_options.exit_cb(l:job_id, v:shell_error)
    endif

    return 1
endfunction

function! s:RunFixer(options) abort
    let l:buffer = a:options.buffer
    let l:input = a:options.input
    let l:index = a:options.callback_index

    while len(a:options.callback_list) > l:index
        let l:result = call(a:options.callback_list[l:index], [l:buffer, copy(l:input)])

        if type(l:result) == type(0) && l:result == 0
            " When `0` is returned, skip this item.
            let l:index += 1
        elseif type(l:result) == type([])
            let l:input = l:result
            let l:index += 1
        else
            let l:job_ran = s:RunJob({
            \   'buffer': l:buffer,
            \   'command': l:result.command,
            \   'input': l:input,
            \   'output_stream': get(l:result, 'output_stream', 'stdout'),
            \   'read_temporary_file': get(l:result, 'read_temporary_file', 0),
            \   'callback_list': a:options.callback_list,
            \   'callback_index': l:index,
            \})

            if !l:job_ran
                " The job failed to run, so skip to the next item.
                let l:index += 1
            else
                " Stop here, we will handle exit later on.
                return
            endif
        endif
    endwhile

    call s:ApplyFixes(l:buffer, l:input)
endfunction

function! s:GetCallbacks() abort
    let l:callback_list = []

    for l:sub_type in split(&filetype, '\.')
        let l:sub_type_callacks = get(g:ale_fixers, l:sub_type, [])

        if type(l:sub_type_callacks) == type('')
            call add(l:callback_list, l:sub_type_callacks)
        else
            call extend(l:callback_list, l:sub_type_callacks)
        endif
    endfor

    if empty(l:callback_list)
        echoerr 'No fixers have been defined for filetype: ' . &filetype
        return []
    endif

    let l:corrected_list = []

    " Variables with capital characters are needed, or Vim will complain about
    " funcref variables.
    for l:Item in l:callback_list
        if type(l:Item) == type('')
            let l:Func = ale#fix#registry#GetFunc(l:Item)

            if !empty(l:Func)
                let l:Item = l:Func
            endif
        endif

        call add(l:corrected_list, function(l:Item))
    endfor

    return l:corrected_list
endfunction

function! ale#fix#Fix() abort
    let l:callback_list = s:GetCallbacks()

    if empty(l:callback_list)
        return
    endif

    let l:buffer = bufnr('')
    let l:input = getbufline(l:buffer, 1, '$')

    " Clean up any files we might have left behind from a previous run.
    call ale#fix#RemoveManagedFiles(l:buffer)

    " The 'done' flag tells the function for applying changes when fixing
    " is complete.
    let s:buffer_data[l:buffer] = {
    \   'lines_before': l:input,
    \   'done': 0,
    \   'temporary_directory_list': [],
    \}

    call s:RunFixer({
    \   'buffer': l:buffer,
    \   'input': l:input,
    \   'callback_index': 0,
    \   'callback_list': l:callback_list,
    \})
endfunction

" Set up an autocmd command to try and apply buffer fixes when available.
augroup ALEBufferFixGroup
    autocmd!
    autocmd BufEnter * call ale#fix#ApplyQueuedFixes()
augroup END