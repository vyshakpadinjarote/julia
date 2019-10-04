using Profile: Memory

forever_chunks = []
function foo()
    global forever_chunks

    # Create a chunk that will live forever
    push!(forever_chunks, Array{UInt8,2}(undef,1000,1000))

    # Create a chunk that......will not.
    Array{UInt8,2}(undef,1000,100)

    # Create lots of little objects
    tups = Any[(1,), (2,3)]
    for idx in 1:20
        addition = (tups[end-1]..., tups[end]...)
        addition = addition[2:end]
        push!(tups, addition)
    end
    # Keep a few of them around
    push!(forever_chunks, tups[1])
    push!(forever_chunks, tups[end])
    return nothing
end

function test(should_profile::Bool = false)
    # We use the trick of setting the tag filter to 0x0000 to disable
    # memory profiling so that we don't ever have to recompile.
    Memory.init(50_000_000, 1_000_000, 0xffff * should_profile)
    global forever_chunks = []
    Memory.@profile foo()
end

@info("Precompiling test()")
test(false)

@info("Running test()")
test(true)

@info("Reading memprofile data...")
open_chunks, closed_chunks, ghost_chunks = Memory.read_and_coalesce_memprofile_data()
println("open_chunks:")
display(open_chunks)

# This often crashes us, if we've held on to a bad object address.
# Explicitly run it to make sure everything is on the up-and-up.
Base.GC.gc(GC.Full)
