import Base.StackTraces: lookup, UNKNOWN, show_spec_linfo, StackFrame

# deprecated functions: use `getdict` instead
lookup(ip::UInt) = lookup(convert(Ptr{Cvoid}, ip))


const IP = Union{UInt,Base.InterpreterIP}
const LineInfoDict = Dict{IP, Vector{StackFrame}}
const LineInfoFlatDict = Dict{IP, StackFrame}

struct ProfileFormat
    maxdepth::Int
    mincount::Int
    noisefloor::Float64
    sortedby::Symbol
    combine::Bool
    C::Bool
    recur::Symbol
    function ProfileFormat(;
        C = false,
        combine = true,
        maxdepth::Int = typemax(Int),
        mincount::Int = 0,
        noisefloor = 0,
        sortedby::Symbol = :filefuncline,
        recur::Symbol = :off)
        return new(maxdepth, mincount, noisefloor, sortedby, combine, C, recur)
    end
end

"""
    getdict(data::Vector{UInt})
Given a list of instruction pointers, build a dictionary mapping from those pointers to
LineInfo objects (as returned by `StackTraces.lookup()`).  This allows us to quickly take
a list of instruction pointers and convert it to `LineInfo` objects.
"""
function getdict(data)
    return LineInfoDict(x=>lookup(x) for x in unique(data))
end

"""
    flatten(btdata::Vector, lidict::LineInfoDict) -> (newdata::Vector{UInt64}, newdict::LineInfoFlatDict)

Produces "flattened" backtrace data. Individual instruction pointers
sometimes correspond to a multi-frame backtrace due to inlining; in
such cases, this function inserts fake instruction pointers for the
inlined calls, and returns a dictionary that is a 1-to-1 mapping
between instruction pointers and a single StackFrame.
"""
function flatten(data::Vector, lidict::LineInfoDict)
    # Makes fake instruction pointers, counting down from typemax(UInt)
    newip = typemax(UInt64) - 1
    taken = Set(keys(lidict))  # make sure we don't pick one that's already used
    newdict = Dict{IP,StackFrame}()
    newmap  = Dict{IP,Vector{UInt64}}()
    for (ip, trace) in lidict
        if length(trace) == 1
            newdict[ip] = trace[1]
        else
            newm = UInt64[]
            for sf in trace
                while newip ∈ taken && newip > 0
                    newip -= 1
                end
                newip == 0 && error("all possible instruction pointers used")
                push!(newm, newip)
                newdict[newip] = sf
                newip -= 1
            end
            newmap[ip] = newm
        end
    end
    newdata = UInt64[]
    for ip::UInt64 in data
        if haskey(newmap, ip)
            append!(newdata, newmap[ip])
        else
            push!(newdata, ip)
        end
    end
    return (newdata, newdict)
end

# Take a file-system path and try to form a concise representation of it
# based on the package ecosystem
function short_path(spath::Symbol, filenamecache::Dict{Symbol, String})
    return get!(filenamecache, spath) do
        path = string(spath)
        if isabspath(path)
            if ispath(path)
                # try to replace the file-system prefix with a short "@Module" one,
                # assuming that profile came from the current machine
                # (or at least has the same file-system layout)
                root = path
                while !isempty(root)
                    root, base = splitdir(root)
                    isempty(base) && break
                    @assert startswith(path, root)
                    for proj in Base.project_names
                        project_file = joinpath(root, proj)
                        if Base.isfile_casesensitive(project_file)
                            pkgid = Base.project_file_name_uuid(project_file, "")
                            isempty(pkgid.name) && return path # bad Project file
                            # return the joined the module name prefix and path suffix
                            path = path[nextind(path, sizeof(root)):end]
                            return string("@", pkgid.name, path)
                        end
                    end
                end
            end
            return path
        elseif isfile(joinpath(Sys.BINDIR::String, Base.DATAROOTDIR, "julia", "base", path))
            # do the same mechanic for Base (or Core/Compiler) files as above,
            # but they start from a relative path
            return joinpath("@Base", normpath(path))
        else
            # for non-existent relative paths (such as "REPL[1]"), just consider simplifying them
            return normpath(path) # drop leading "./"
        end
    end
end

"""
    callers(funcname, [data, lidict], [filename=<filename>], [linerange=<start:stop>]) -> Vector{Tuple{count, lineinfo}}

Given a previous profiling run, determine who called a particular function. Supplying the
filename (and optionally, range of line numbers over which the function is defined) allows
you to disambiguate an overloaded method. The returned value is a vector containing a count
of the number of calls and line information about the caller. One can optionally supply
backtrace `data` obtained from [`Time.retrieve`](@ref); otherwise, the current internal
profile buffer is used.
"""
function callers end

function callers(funcname::String, bt::Vector, lidict::LineInfoFlatDict; filename = nothing, linerange = nothing)
    if filename === nothing && linerange === nothing
        return callersf(li -> String(li.func) == funcname,
            bt, lidict)
    end
    filename === nothing && throw(ArgumentError("if supplying linerange, you must also supply the filename"))
    filename = String(filename)
    if linerange === nothing
        return callersf(li -> String(li.func) == funcname && String(li.file) == filename,
            bt, lidict)
    else
        return callersf(li -> String(li.func) == funcname && String(li.file) == filename && in(li.line, linerange),
            bt, lidict)
    end
end

callers(funcname::String, bt::Vector, lidict::LineInfoDict; kwargs...) =
    callers(funcname, flatten(bt, lidict)...; kwargs...)
callers(func::Function, bt::Vector, lidict::LineInfoFlatDict; kwargs...) =
    callers(string(func), bt, lidict; kwargs...)


## Print as a flat list
# Counts the number of times each line appears, at any nesting level and at the topmost level
# Merging multiple equivalent entries and recursive calls
function parse_flat(::Type{T}, data::Vector{UInt64}, lidict::Union{LineInfoDict, LineInfoFlatDict}, C::Bool) where {T}
    lilist = StackFrame[]
    n = Int[]
    m = Int[]
    lilist_idx = Dict{T, Int}()
    recursive = Set{T}()
    first = true
    totalshots = 0
    for ip in data
        if ip == 0
            totalshots += 1
            empty!(recursive)
            first = true
            continue
        end
        frames = lidict[ip]
        nframes = (frames isa Vector ? length(frames) : 1)
        for i = 1:nframes
            frame = (frames isa Vector ? frames[i] : frames)
            !C && frame.from_c && continue
            key = (T === UInt64 ? ip : frame)
            idx = get!(lilist_idx, key, length(lilist) + 1)
            if idx > length(lilist)
                push!(recursive, key)
                push!(lilist, frame)
                push!(n, 1)
                push!(m, 0)
            elseif !(key in recursive)
                push!(recursive, key)
                n[idx] += 1
            end
            if first
                m[idx] += 1
                first = false
            end
        end
    end
    @assert length(lilist) == length(n) == length(m) == length(lilist_idx)
    return (lilist, n, m, totalshots)
end

function flat(io::IO, data::Vector{UInt64}, lidict::Union{LineInfoDict, LineInfoFlatDict}, cols::Int, fmt::ProfileFormat)
    lilist, n, m, totalshots = parse_flat(fmt.combine ? StackFrame : UInt64, data, lidict, fmt.C)
    if isempty(lilist)
        warning_empty()
        return
    end
    if false # optional: drop the "non-interpretable" ones
        keep = map(frame -> frame != UNKNOWN && frame.line != 0, lilist)
        lilist = lilist[keep]
        n = n[keep]
        m = m[keep]
    end
    filenamemap = Dict{Symbol,String}()
    print_flat(io, lilist, n, m, cols, filenamemap, fmt)
    Base.println(io, "Total snapshots: ", totalshots)
    nothing
end

function print_flat(io::IO, lilist::Vector{StackFrame},
        n::Vector{Int}, m::Vector{Int},
        cols::Int, filenamemap::Dict{Symbol,String},
        fmt::ProfileFormat)
    if fmt.sortedby == :count
        p = sortperm(n)
    elseif fmt.sortedby == :overhead
        p = sortperm(m)
    else
        p = liperm(lilist)
    end
    lilist = lilist[p]
    n = n[p]
    m = m[p]
    filenames = String[short_path(li.file, filenamemap) for li in lilist]
    funcnames = String[string(li.func) for li in lilist]
    wcounts = max(6, ndigits(maximum(n)))
    wself = max(9, ndigits(maximum(m)))
    maxline = 1
    maxfile = 6
    maxfunc = 10
    for i in 1:length(lilist)
        li = lilist[i]
        maxline = max(maxline, li.line)
        maxfunc = max(maxfunc, length(funcnames[i]))
        maxfile = max(maxfile, length(filenames[i]))
    end
    wline = max(5, ndigits(maxline))
    ntext = max(20, cols - wcounts - wself - wline - 3)
    maxfunc += 25 # for type signatures
    if maxfile + maxfunc <= ntext
        wfile = maxfile
        wfunc = ntext - maxfunc # take the full width (for type sig)
    else
        wfile = 2*ntext÷5
        wfunc = 3*ntext÷5
    end
    println(io, lpad("Count", wcounts, " "), " ", lpad("Overhead", wself, " "), " ",
            rpad("File", wfile, " "), " ", lpad("Line", wline, " "), " Function")
    println(io, lpad("=====", wcounts, " "), " ", lpad("========", wself, " "), " ",
            rpad("====", wfile, " "), " ", lpad("====", wline, " "), " ========")
    for i = 1:length(n)
        n[i] < fmt.mincount && continue
        li = lilist[i]
        Base.print(io, lpad(string(n[i]), wcounts, " "), " ")
        Base.print(io, lpad(string(m[i]), wself, " "), " ")
        if li == UNKNOWN
            if !fmt.combine && li.pointer != 0
                Base.print(io, "@0x", string(li.pointer, base=16))
            else
                Base.print(io, "[any unknown stackframes]")
            end
        else
            file = filenames[i]
            isempty(file) && (file = "[unknown file]")
            Base.print(io, rpad(rtruncto(file, wfile), wfile, " "), " ")
            Base.print(io, lpad(li.line > 0 ? string(li.line) : "?", wline, " "), " ")
            fname = funcnames[i]
            if !li.from_c && li.linfo !== nothing
                fname = sprint(show_spec_linfo, li)
            end
            isempty(fname) && (fname = "[unknown function]")
            Base.print(io, ltruncto(fname, wfunc))
        end
        println(io)
    end
    nothing
end

## A tree representation

# Representation of a prefix trie of backtrace counts
mutable struct StackFrameTree{T} # where T <: Union{UInt64, StackFrame}
    # content fields:
    frame::StackFrame
    count::Int          # number of frames this appeared in
    overhead::Int       # number frames where this was the code being executed
    flat_count::Int     # number of times this frame was in the flattened representation (unlike count, this'll sum to 100% of parent)
    max_recur::Int      # maximum number of times this frame was the *top* of the recursion in the stack
    count_recur::Int    # sum of the number of times this frame was the *top* of the recursion in a stack (divide by count to get an average)
    down::Dict{T, StackFrameTree{T}}
    # construction workers:
    recur::Int
    builder_key::Vector{UInt64}
    builder_value::Vector{StackFrameTree{T}}
    up::StackFrameTree{T}
    StackFrameTree{T}() where {T} = new(UNKNOWN, 0, 0, 0, 0, 0, Dict{T, StackFrameTree{T}}(), 0, UInt64[], StackFrameTree{T}[])
end


const indent_s = "    ╎"^10
const indent_z = collect(eachindex(indent_s))
function indent(depth::Int)
    depth < 1 && return ""
    depth <= length(indent_z) && return indent_s[1:indent_z[depth]]
    div, rem = divrem(depth, length(indent_z))
    return (indent_s^div) * SubString(indent_s, 1, indent_z[rem])
end

function tree_format(frames::Vector{<:StackFrameTree}, level::Int, cols::Int, maxes, filenamemap::Dict{Symbol,String}, showpointer::Bool)
    nindent = min(cols>>1, level)
    ndigoverhead = ndigits(maxes.overhead)
    ndigcounts = ndigits(maxes.count)
    ndigline = ndigits(maximum(frame.frame.line for frame in frames)) + 6
    ntext = max(30, cols - ndigoverhead - nindent - ndigcounts - ndigline - 6)
    widthfile = 2*ntext÷5 # min 12
    widthfunc = 3*ntext÷5 # min 18
    strs = Vector{String}(undef, length(frames))
    showextra = false
    if level > nindent
        nextra = level - nindent
        nindent -= ndigits(nextra) + 2
        showextra = true
    end
    for i = 1:length(frames)
        frame = frames[i]
        li = frame.frame
        stroverhead = lpad(frame.overhead > 0 ? string(frame.overhead) : "", ndigoverhead, " ")
        base = nindent == 0 ? "" : indent(nindent - 1) * " "
        if showextra
            base = string(base, "+", nextra, " ")
        end
        strcount = rpad(string(frame.count), ndigcounts, " ")
        if li != UNKNOWN
            if li.line == li.pointer
                strs[i] = string(stroverhead, "╎", base, strcount, " ",
                    "[unknown function] (pointer: 0x",
                    string(li.pointer, base = 16, pad = 2*sizeof(Ptr{Cvoid})),
                    ")")
            else
                if !li.from_c && li.linfo !== nothing
                    fname = sprint(show_spec_linfo, li)
                else
                    fname = string(li.func)
                end
                filename = short_path(li.file, filenamemap)
                if showpointer
                    fname = string(
                        "0x",
                        string(li.pointer, base = 16, pad = 2*sizeof(Ptr{Cvoid})),
                        " ",
                        fname)
                end
                strs[i] = string(stroverhead, "╎", base, strcount, " ",
                    rtruncto(filename, widthfile),
                    ":",
                    li.line == -1 ? "?" : string(li.line),
                    "; ",
                    ltruncto(fname, widthfunc))
            end
        else
            strs[i] = string(stroverhead, "╎", base, strcount, " [unknown stackframe]")
        end
    end
    return strs
end

# turn a list of backtraces into a tree (implicitly separated by NULL markers)
function tree!(root::StackFrameTree{T}, all::Vector{UInt64}, lidict::Union{LineInfoFlatDict, LineInfoDict}, C::Bool, recur::Symbol) where {T}
    parent = root
    tops = Vector{StackFrameTree{T}}()
    build = Vector{StackFrameTree{T}}()
    startframe = length(all)
    for i in startframe:-1:1
        ip = all[i]
        if ip == 0
            # sentinel value indicates the start of a new backtrace
            empty!(build)
            root.recur = 0
            if recur !== :off
                # We mark all visited nodes to so we'll only count those branches
                # once for each backtrace. Reset that now for the next backtrace.
                push!(tops, parent)
                for top in tops
                    while top.recur != 0
                        top.max_recur < top.recur && (top.max_recur = top.recur)
                        top.recur = 0
                        top = top.up
                    end
                end
                empty!(tops)
            end
            let this = parent
                while this !== root
                    this.flat_count += 1
                    this = this.up
                end
            end
            parent.overhead += 1
            parent = root
            root.count += 1
            startframe = i
        else
            pushfirst!(build, parent)
            if recur === :flat || recur == :flatc
                # Rewind the `parent` tree back, if this exact ip was already present *higher* in the current tree
                found = false
                for j in 1:(startframe - i)
                    if ip == all[i + j]
                        if recur === :flat # if not flattening C frames, check that now
                            frames = lidict[ip]
                            frame = (frames isa Vector ? frames[1] : frames)
                            frame.from_c && break # not flattening this frame
                        end
                        push!(tops, parent)
                        parent = build[j]
                        parent.recur += 1
                        parent.count_recur += 1
                        found = true
                        break
                    end
                end
                found && continue
            end
            builder_key = parent.builder_key
            builder_value = parent.builder_value
            fastkey = searchsortedfirst(builder_key, ip)
            if fastkey < length(builder_key) && builder_key[fastkey] === ip
                # jump forward to the end of the inlining chain
                # avoiding an extra (slow) lookup of `ip` in `lidict`
                # and an extra chain of them in `down`
                # note that we may even have this === parent (if we're ignoring this frame ip)
                this = builder_value[fastkey]
                let this = this
                    while this !== parent && (recur === :off || this.recur == 0)
                        this.count += 1
                        this.recur = 1
                        this = this.up
                    end
                end
                parent = this
                continue
            end
            frames = lidict[ip]
            nframes = (frames isa Vector ? length(frames) : 1)
            this = parent
            # add all the inlining frames
            for i = nframes:-1:1
                frame = (frames isa Vector ? frames[i] : frames)
                !C && frame.from_c && continue
                key = (T === UInt64 ? ip : frame)
                this = get!(StackFrameTree{T}, parent.down, key)
                if recur === :off || this.recur == 0
                    this.frame = frame
                    this.up = parent
                    this.count += 1
                    this.recur = 1
                end
                parent = this
            end
            # record where the end of this chain is for this ip
            insert!(builder_key, fastkey, ip)
            insert!(builder_value, fastkey, this)
        end
    end
    function cleanup!(node::StackFrameTree)
        stack = [node]
        while !isempty(stack)
            node = pop!(stack)
            node.recur = 0
            empty!(node.builder_key)
            empty!(node.builder_value)
            append!(stack, values(node.down))
        end
        nothing
    end
    cleanup!(root)
    return root
end

function maxstats(root::StackFrameTree)
    maxcount = Ref(0)
    maxflatcount = Ref(0)
    maxoverhead = Ref(0)
    maxmaxrecur = Ref(0)
    stack = [root]
    while !isempty(stack)
        node = pop!(stack)
        maxcount[] = max(maxcount[], node.count)
        maxoverhead[] = max(maxoverhead[], node.overhead)
        maxflatcount[] = max(maxflatcount[], node.flat_count)
        maxmaxrecur[] = max(maxmaxrecur[], node.max_recur)
        append!(stack, values(node.down))
    end
    return (count=maxcount[], count_flat=maxflatcount[], overhead=maxoverhead[], max_recur=maxmaxrecur[])
end

# Print the stack frame tree starting at a particular root. Uses a worklist to
# avoid stack overflows.
function print_tree(io::IO, bt::StackFrameTree{T}, cols::Int, fmt::ProfileFormat) where T
    maxes = maxstats(bt)
    filenamemap = Dict{Symbol,String}()
    worklist = [(bt, 0, 0, "")]
    println(io, "Overhead ╎ [+additional indent] Count File:Line; Function")
    println(io, "=========================================================")
    while !isempty(worklist)
        (bt, level, noisefloor, str) = popfirst!(worklist)
        isempty(str) || println(io, str)
        level > fmt.maxdepth && continue
        isempty(bt.down) && continue
        # Order the line information
        nexts = collect(values(bt.down))
        # Generate the string for each line
        strs = tree_format(nexts, level, cols, maxes, filenamemap, T === UInt64)
        # Recurse to the next level
        if fmt.sortedby == :count
            counts = collect(frame.count for frame in nexts)
            p = sortperm(counts)
        elseif fmt.sortedby == :overhead
            m = collect(frame.overhead for frame in nexts)
            p = sortperm(m)
        elseif fmt.sortedby == :flat_count
            m = collect(frame.flat_count for frame in nexts)
            p = sortperm(m)
        else
            lilist = collect(frame.frame for frame in nexts)
            p = liperm(lilist)
        end
        for i in reverse(p)
            down = nexts[i]
            count = down.count
            count < fmt.mincount && continue
            count < noisefloor && continue
            str = strs[i]
            noisefloor_down = fmt.noisefloor > 0 ? floor(Int, fmt.noisefloor * sqrt(count)) : 0
            pushfirst!(worklist, (down, level + 1, noisefloor_down, str))
        end
    end
end

function tree(io::IO, data::Vector{UInt64}, lidict::Union{LineInfoFlatDict, LineInfoDict}, cols::Int, fmt::ProfileFormat)
    if fmt.combine
        root = tree!(StackFrameTree{StackFrame}(), data, lidict, fmt.C, fmt.recur)
    else
        root = tree!(StackFrameTree{UInt64}(), data, lidict, fmt.C, fmt.recur)
    end
    if isempty(root.down)
        warning_empty()
        return
    end
    print_tree(io, root, cols, fmt)
    Base.println(io, "Total snapshots: ", root.count)
    nothing
end

function callersf(matchfunc::Function, bt::Vector, lidict::LineInfoFlatDict)
    counts = Dict{StackFrame, Int}()
    lastmatched = false
    for id in bt
        if id == 0
            lastmatched = false
            continue
        end
        li = lidict[id]
        if lastmatched
            if haskey(counts, li)
                counts[li] += 1
            else
                counts[li] = 1
            end
        end
        lastmatched = matchfunc(li)
    end
    k = collect(keys(counts))
    v = collect(values(counts))
    p = sortperm(v, rev=true)
    return [(v[i], k[i]) for i in p]
end

# Utilities
function rtruncto(str::String, w::Int)
    if length(str) <= w
        return str
    else
        return string("...", str[prevind(str, end, w-4):end])
    end
end
function ltruncto(str::String, w::Int)
    if length(str) <= w
        return str
    else
        return string(str[1:nextind(str, 1, w-4)], "...")
    end
end


truncto(str::Symbol, w::Int) = truncto(string(str), w)

# Order alphabetically (file, function) and then by line number
function liperm(lilist::Vector{StackFrame})
    function lt(a::StackFrame, b::StackFrame)
        a == UNKNOWN && return false
        b == UNKNOWN && return true
        fcmp = cmp(a.file, b.file)
        fcmp < 0 && return true
        fcmp > 0 && return false
        fcmp = cmp(a.func, b.func)
        fcmp < 0 && return true
        fcmp > 0 && return false
        fcmp = cmp(a.line, b.line)
        fcmp < 0 && return true
        return false
    end
    return sortperm(lilist, lt = lt)
end

warning_empty() = @warn """
            There were no samples collected. Run your program longer (perhaps by
            running it multiple times), or adjust the delay between samples with
            `Profile.init()`."""
