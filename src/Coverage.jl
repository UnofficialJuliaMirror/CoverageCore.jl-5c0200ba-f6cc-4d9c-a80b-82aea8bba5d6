#######################################################################
# Coverage.jl
# Input: Code coverage and memory allocations
# Output: Useful things
# https://github.com/JuliaCI/Coverage.jl
#######################################################################
module Coverage
    using LibGit2

    export process_folder, process_file
    export clean_folder, clean_file
    export process_cov, amend_coverage_from_src!
    export get_summary
    export analyze_malloc, merge_coverage_counts

    # The unit for line counts. Counts can be >= 0 or nothing, where
    # the nothing means it doesn't make sense to have a count for this
    # line (e.g. a comment), but 0 means it could have run but didn't.
    const CovCount = Union{Nothing,Int}

    export FileCoverage
    """
    FileCoverage

    Represents coverage info about a file, including the filename, the source
    code itself, and a `Vector` of run counts for each line. If the
    line was expected to be run the count will be an `Int` >= 0. Other lines
    such as comments will have a count of `nothing`.
    """
    mutable struct FileCoverage
        filename::AbstractString
        source::AbstractString
        coverage::Vector{CovCount}
    end

    """
        get_summary(fcs)

    Summarize results from a single `FileCoverage` instance or a `Vector` of
    them, returning a 2-tuple with the covered lines and total lines.
    """
    function get_summary end

    function get_summary(fc::FileCoverage)
        if !isempty(fc.coverage)
            cov_lines = sum(x -> x !== nothing && x > 0, fc.coverage)
            tot_lines = sum(x -> x !== nothing, fc.coverage)
        else
            cov_lines = 0
            tot_lines = 0
        end
        return cov_lines, tot_lines
    end
    function get_summary(fcs::Vector{FileCoverage})
        cov_lines, tot_lines = 0, 0
        for fc in fcs
            c, t = get_summary(fc)
            cov_lines += c
            tot_lines += t
        end
        return cov_lines, tot_lines
    end

    """
        merge_coverage_counts(a1::Vector{CovCount}, a2::Vector{CovCount})

    Given two vectors of line coverage counts, take the pairwise
    maximum of both vectors, preseving null counts if both are null.
    """
    function merge_coverage_counts(a1::Vector{CovCount},
                                   a2::Vector{CovCount})
        n = max(length(a1),length(a2))
        a = Vector{CovCount}(undef, n)
        for i in 1:n
            a1v = isassigned(a1, i) ? a1[i] : nothing
            a2v = isassigned(a2, i) ? a2[i] : nothing
            a[i] = a1v == nothing ? a2v :
                   a2v == nothing ? a1v : max(a1v, a2v)
        end
        return a
    end

    """
        process_cov(filename, folder)

    Given a filename for a Julia source file, produce an array of
    line coverage counts by reading in all matching .{pid}.cov files.
    On Julia 0.3 there was just a .cov file, but this code works fine.
    """
    function process_cov(filename, folder)
        # Find all coverage files in the folder that match the file we
        # are currently working on
        files = readdir(folder)
        files = map!(file -> joinpath(folder, file), files, files)
        filter!(file -> occursin(filename, file) && occursin(".cov", file), files)
        # If there are no coverage files...
        if isempty(files)
            # ... we will assume that, as there is a .jl file, it was
            # just never run. We'll report the coverage as all null.
            println( """Coverage.process_cov: Coverage file(s) for $filename do not exist.
                                              Assuming file has no coverage.""")
            nlines = 0
            for line in eachline(filename)
                nlines += 1
            end
            return fill!(Vector{CovCount}(undef, nlines), nothing)
        end
        # Keep track of the combined coverage
        full_coverage = CovCount[]
        for file in files
            coverage = CovCount[]
            for line in eachline(file)
                # Columns 1:9 contain the coverage count
                cov_segment = line[1:9]
                # If coverage is NA, there will be a dash
                push!(coverage, cov_segment[9] == '-' ? nothing : parse(Int, cov_segment))
            end
            full_coverage = merge_coverage_counts(full_coverage, coverage)
        end
        return full_coverage
    end

    """
        amend_coverage_from_src!(coverage::Vector{CovCount}, srcname)

    The code coverage functionality in Julia can miss code lines, which
    will be incorrectly recorded as `nothing` but should instead be 0
    This function takes a coverage count vector and a the filename for
    a Julia code file, and updates the coverage vector in place.
    """
    function amend_coverage_from_src!(coverage::Vector{CovCount}, srcname)
        # To make sure things stay in sync, parse the file position
        # corresonding to each new line
        linepos = Int[]
        open(srcname) do io
            while !eof(io)
                push!(linepos, position(io))
                readline(io)
            end
            push!(linepos, position(io))
        end
        content = read(srcname, String)
        pos = 1
        while pos <= length(content)
            linestart = minimum(searchsorted(linepos, pos - 1))
            ast, pos = Meta.parse(content, pos)
            isa(ast, Expr) || continue
            flines = function_body_lines(ast)
            if !isempty(flines)
                flines .+= linestart-1
                for l in flines
                    if l > length(coverage)
                        error("source file is longer than .cov file; source might have changed")
                    end
                    if coverage[l] == nothing
                        coverage[l] = 0
                    end
                end
            end
        end
        nothing
    end
    # function_body_lines is located in parser.jl
    include("parser.jl")

    """
        process_file(filename[, folder]) -> FileCoverage

    Given a .jl file and its containing folder, produce a corresponding
    `FileCoverage` instance from the source and matching coverage files. If the
    folder is not given it is extracted from the filename.
    """
    function process_file end

    function process_file(filename, folder)
        println("Coverage.process_file: Detecting coverage for $filename")
        coverage = process_cov(filename,folder)
        amend_coverage_from_src!(coverage, filename)
        return FileCoverage(filename, read(filename, String), coverage)
    end
    process_file(filename) = process_file(filename,splitdir(filename)[1])

    """
        process_folder(folder="src") -> Vector{FileCoverage}

    Process the contents of a folder of Julia source code to collect coverage
    statistics for all the files contained within. Will recursively traverse
    child folders. Default folder is "src", which is useful for the primary case
    where Coverage is called from the root directory of a package.
    """
    function process_folder(folder="src")
        println("""Coverage.process_folder: Searching $folder for .jl files...""")
        source_files = FileCoverage[]
        files = readdir(folder)
        for file in files
            fullfile = joinpath(folder,file)
            if isfile(fullfile)
                # Is it a Julia file?
                if splitext(fullfile)[2] == ".jl"
                    push!(source_files, process_file(fullfile,folder))
                else
                    println("Coverage.process_folder: Skipping $file, not a .jl file")
                end
            elseif isdir(fullfile)
                # If it is a folder, recursively traverse
                append!(source_files, process_folder(fullfile))
            end
        end
        return source_files
    end

    # matches julia coverage files with and without the PID
    iscovfile(filename) = occursin(r"\.jl\.?[0-9]*\.cov$", filename)
    # matches a coverage file for the given sourcefile. They can be full paths
    # with directories, but the directories must match
    function iscovfile(filename, sourcefile)
        startswith(filename, sourcefile) || return false
        occursin(r"\.jl\.?[0-9]*\.cov$", filename)
    end

    """
        clean_folder(folder::AbstractString)

    Cleans up all the `.cov` files in the given directory and subdirectories.
    Unlike `process_folder` this does not include a default value
    for the root folder, requiring the calling code to be more explicit about
    which files will be deleted.
    """
    function clean_folder(folder::AbstractString)
        files = readdir(folder)
        for file in files
            fullfile = joinpath(folder, file)
            if isfile(fullfile) && iscovfile(file)
                # we have ourselves a coverage file. eliminate it
                println("Removing $fullfile")
                rm(fullfile)
            elseif isdir(fullfile)
                clean_folder(fullfile)
            end
        end
        nothing
    end

    """
        clean_file(filename::AbstractString)

    Cleans up all `.cov` files associated with a given source file. This only
    looks in the directory of the given file, i.e. the `.cov` files should be
    siblings of the source file.
    """
    function clean_file(filename::AbstractString)
        folder = splitdir(filename)[1]
        files = readdir(folder)
        for file in files
            fullfile = joinpath(folder, file)
            if isfile(fullfile) && iscovfile(fullfile, filename)
                println("Removing $fullfile")
                rm(fullfile)
            end
        end
    end

    include("coveralls.jl")
    include("codecovio.jl")
    include("lcov.jl")
    include("memalloc.jl")
end
