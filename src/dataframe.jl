##############################################################################
##
## AbstractDataFrame includes DataFrame and SubDataFrame
##
##############################################################################

abstract AbstractDataFrame <: Associative{Any, Any}

##############################################################################
##
## Basic DataFrame definition
##
## A DataFrame is a vector of heterogeneous DataVec's that be accessed using
## numeric indexing for both rows and columns and name-based indexing for
## columns. The columns are stored in a vector, which means that operations
## that insert/delete columns are O(n).
##
##############################################################################

type DataFrame <: AbstractDataFrame
    columns::Vector{Any}
    colindex::Index
    function DataFrame(cols::Vector, colindex::Index)
        # all columns have to be the same length
        if length(cols) > 1 && !all(map(length, cols) .== length(cols[1]))
            error("all columns in a DataFrame have to be the same length")
        end
        # colindex has to be the same length as columns vector
        if length(colindex) != length(cols)
            error("column names/index must be the same length as the number of columns")
        end
        new(cols, colindex)
    end
end

##############################################################################
##
## DataFrame constructors
##
##############################################################################

# TODO: Move this into utils.jl
function generate_column_names(n::Int)
    convert(Vector{ByteString}, map(i -> "x" * string(i), 1:n))
end

# The empty DataFrame
DataFrame() = DataFrame({}, Index())

# Convert an arbitrary vector w/ pre-specified names
DataFrame{T <: String}(cs::Vector, cn::Vector{T}) = DataFrame(cs, Index(cn))

# Convert an arbitrary vector w/o pre-specified names
DataFrame(cs::Vector) = DataFrame(cs, Index(generate_column_names(length(cs))))

# Build a DataFrame from an expression
# TODO expand the following to allow unequal lengths that are rep'd to the longest length.
DataFrame(ex::Expr) = based_on(DataFrame(), ex)

# Convert a standard Matrix to a DataFrame w/ pre-specified names
function DataFrame{T}(x::Matrix{T}, cn::Vector)
    DataFrame({DataVec(x[:, i]) for i in 1:length(cn)}, cn)
end

# Convert a standard Matrix to a DataFrame w/o pre-specified names
function DataFrame{T}(x::Matrix{T})
    DataFrame(x, generate_column_names(size(x, 2)))
end

# If we have something a tuple, convert each value in the tuple to a
# DataVec and then pass the converted columns in, hoping for the best
DataFrame(vals...) = DataFrame([DataVec(x) for x = vals])

function DataFrame{K,V}(d::Associative{K,V})
    # Find the first position with maximum length in the Dict.
    # I couldn't get findmax to work here.
    ## (Nrow,maxpos) = findmax(map(length, values(d)))
    lengths = map(length, values(d))
    maxpos = find(lengths .== max(lengths))[1]
    keymaxlen = keys(d)[maxpos]
    Nrow = length(d[keymaxlen])
    # Start with a blank DataFrame
    df = DataFrame() 
    for (k,v) in d
        if length(v) == Nrow
            df[k] = v  
        elseif rem(Nrow, length(v)) == 0    # Nrow is a multiple of length(v)
            df[k] = vcat(fill(v, div(Nrow, length(v)))...)
        else
            vec = fill(v[1], Nrow)
            j = 1
            for i = 1:Nrow
                vec[i] = v[j]
                j += 1
                if j > length(v)
                    j = 1
                end
            end
            df[k] = vec
        end
    end
    df
end

# Construct a DataFrame with groupings over the columns
function DataFrame(cs::Vector, cn::Vector, gr::Dict{ByteString,Vector{ByteString}})
  d = DataFrame(cs, cn)
  set_groups(index(d), gr)
  return d
end

# Pandas' Dict of Vectors -> DataFrame constructor w/ explicit column names
function DataFrame(d::Dict)
    column_names = sort(convert(Array{ByteString, 1}, keys(d)))
    p = length(column_names)
    if p == 0
        DataFrame(0, 0)
    end
    n = length(d[column_names[1]])
    columns = Array(Any, p)
    for j in 1:p
        if length(d[column_names[j]]) != n
            error("All inputs must have the same length")
        end
        columns[j] = DataVec(d[column_names[j]])
    end
    return DataFrame(columns, Index(column_names))
end

# Pandas' Dict of Vectors -> DataFrame constructor w/o explicit column names
function DataFrame(d::Dict, column_names::Vector)
    p = length(column_names)
    if p == 0
        DataFrame(0, 0)
    end
    n = length(d[column_names[1]])
    columns = Array(Any, p)
    for j in 1:p
        if length(d[column_names[j]]) != n
            error("All inputs must have the same length")
        end
        columns[j] = DataVec(d[column_names[j]])
    end
    return DataFrame(columns, Index(column_names))
end

# Initialize empty DataFrame objects of arbitrary size
# t is a Type
function DataFrame(t::Any, nrows::Int64, ncols::Int64)
    column_types = Array(Any, ncols)
    for i in 1:ncols
        column_types[i] = t
    end
    column_names = Array(ByteString, 0)
    DataFrame(column_types, column_names, nrows)
end

# Initialize empty DataFrame objects of arbitrary size
# Default to Float64 as the type
function DataFrame(nrows::Int64, ncols::Int64)
    DataFrame(Float64, nrows::Int64, ncols::Int64)
end

# Initialize an empty DataFrame with specific types and names
function DataFrame(column_types::Vector, column_names::Vector, n::Int64)
  p = length(column_types)
  columns = Array(Any, p)

  if column_names == []
    names = Array(ByteString, p)
    for j in 1:p
      names[j] = "x$j"
    end
  else
    names = column_names
  end

  for j in 1:p
    columns[j] = DataVec(Array(column_types[j], n), Array(Bool, n))
    for i in 1:n
      columns[j][i] = baseval(column_types[j])
      columns[j][i] = NA
    end
  end

  DataFrame(columns, Index(names))
end

# Initialize an empty DataFrame with specific types
function DataFrame(column_types::Vector, nrows::Int64)
    p = length(column_types)
    column_names = Array(ByteString, 0)
    DataFrame(column_types, column_names, nrows)
end

# Initialize from a Vector of Associatives (aka list of dicts)
function DataFrame{D<:Associative}(ds::Vector{D})
    ks = unique([k for k in [keys(d) for d in ds]])
    DataFrame(ds, ks)
end

# Initialize from a Vector of Associatives (aka list of dicts)
DataFrame{D<:Associative,T<:String}(ds::Vector{D}, ks::Vector{T}) = 
    invoke(DataFrame, (Vector{D}, Vector), ds, ks)
function DataFrame{D<:Associative}(ds::Vector{D}, ks::Vector)
    #get column types
    col_types = Any[None for i = 1:length(ks)]
    for d in ds
        for (i,k) in enumerate(ks)
            # TODO: check for user-defined "NA" values, ala pandas
            if has(d, k) && !isna(d[k])
                try
                    col_types[i] = promote_type(col_types[i], typeof(d[k]))
                catch
                    col_types[i] = Any
                end
            end
        end
    end
    col_types[col_types .== None] = Any

    # create empty DataFrame, and fill
    df = DataFrame(col_types, ks, length(ds))
    for (i,d) in enumerate(ds)
        for (j,k) in enumerate(ks)
            df[i,j] = get(d, k, NA)
        end
    end

    df
end



##
## Basic properties of a DataFrame
##

colnames(df::DataFrame) = names(df.colindex)
colnames!(df::DataFrame, vals) = names!(df.colindex, vals)

function coltypes(df::DataFrame)
    {typeof(df[i]).parameters[1] for i in 1:ncol(df)}
end

names(df::AbstractDataFrame) = colnames(df)
names!(df::DataFrame, vals) = names!(df.colindex, vals)

replace_names(df::DataFrame, from, to) = replace_names(df.colindex, from, to)
replace_names!(df::DataFrame, from, to) = replace_names!(df.colindex, from, to)

nrow(df::DataFrame) = ncol(df) > 0 ? length(df.columns[1]) : 0
ncol(df::DataFrame) = length(df.colindex)

size(df::AbstractDataFrame) = (nrow(df), ncol(df))
function size(df::AbstractDataFrame, i::Integer)
    if i == 1
        nrow(df)
    elseif i == 2
        ncol(df)
    else
        error("DataFrames have two dimensions only")
    end
end

length(df::AbstractDataFrame) = ncol(df)

ndims(::AbstractDataFrame) = 2

# these are the underlying ref functions that create a new DF object with references to the
# existing columns. The column index needs to be rebuilt with care, so that groups are preserved
# to the extent possible
function ref(df::DataFrame, c::Vector{Int})
	newdf = DataFrame(df.columns[c], convert(Vector{ByteString}, colnames(df)[c]))
	reconcile_groups(df, newdf)
end
function ref(df::DataFrame, r, c::Vector{Int})
	newdf = DataFrame({x[r] for x in df.columns[c]}, convert(Vector{ByteString}, colnames(df)[c]))
	reconcile_groups(df, newdf)
end

function reconcile_groups(olddf, newdf)
	# foreach group, restrict range to intersection with newdf colnames
	# add back any groups with non-null range
	old_groups = get_groups(olddf)
	for key in keys(old_groups)
		# this is clunky -- there are better/faster ways of doing this intersection operation
		match_vals = ByteString[]
		for val in old_groups[key]
			if contains(colnames(newdf), val)
				push(match_vals, val)
			end
		end
		if !isempty(match_vals)
			set_group(newdf, key, match_vals)
		end
	end
	newdf
end

# all other ref() implementations call the above
ref(df::DataFrame, c) = df[df.colindex[c]]
ref(df::DataFrame, c::Integer) = df.columns[c]
ref(df::DataFrame, r, c) = df[r, df.colindex[c]]
ref(df::DataFrame, r, c::Int) = df[c][r]

# special cases
ref(df::DataFrame, r::Int, c::Int) = df[c][r]
ref(df::DataFrame, r::Int, c::Vector{Int}) = df[[r], c]
ref(df::DataFrame, r::Int, c) = df[r, df.colindex[c]]
ref(df::DataFrame, dv::AbstractDataVec) = df[removeNA(dv), :]
ref(df::DataFrame, ex::Expr) = df[with(df, ex), :]  
ref(df::DataFrame, ex::Expr, c::Int) = df[with(df, ex), c]
ref(df::DataFrame, ex::Expr, c::Vector{Int}) = df[with(df, ex), c]
ref(df::DataFrame, ex::Expr, c) = df[with(df, ex), c]

index(df::DataFrame) = df.colindex

# Associative methods:
has(df::AbstractDataFrame, key) = has(index(df), key)
get(df::AbstractDataFrame, key, default) = has(df, key) ? df[key] : default
keys(df::AbstractDataFrame) = keys(index(df))
values(df::DataFrame) = df.columns
del_all(df::DataFrame) = DataFrame()

# Collection methods:
start(df::AbstractDataFrame) = 1
done(df::AbstractDataFrame, i) = i > ncol(df)
next(df::AbstractDataFrame, i) = (df[i], i + 1)

## numel(df::AbstractDataFrame) = ncol(df)
isempty(df::AbstractDataFrame) = ncol(df) == 0

# Column groups
set_group(d::AbstractDataFrame, newgroup, names) = set_group(index(d), newgroup, names)
set_groups(d::AbstractDataFrame, gr::Dict{ByteString,Vector{ByteString}}) = set_groups(index(d), gr)
get_groups(d::AbstractDataFrame) = get_groups(index(d))
rename_group!(d::AbstractDataFrame,a,b) =  replace_names!(index(d), a, b)

function insert(df::AbstractDataFrame, index::Integer, item, name)
    @assert 0 < index <= ncol(df) + 1
    df = copy(df)
    df[name] = item
    # rearrange:
    df[[1:index-1, end, index:end-1]]
end

function insert(df::AbstractDataFrame, df2::AbstractDataFrame)
    @assert nrow(df) == nrow(df2) || nrow(df) == 0
    df = copy(df)
    for n in colnames(df2)
        df[n] = df2[n]
    end
    df
end

# copy of a data frame does a shallow copy
function copy(df::DataFrame)
	newdf = DataFrame(df.columns, colnames(df))
	reconcile_groups(df, newdf)
end
function deepcopy(df::DataFrame)
    newdf = DataFrame([copy(x) for x in df.columns], colnames(df))
    reconcile_groups(df, newdf)
end
#deepcopy_with_groups(df::DataFrame) = DataFrame([copy(x) for x in df.columns], colnames(df), get_groups(df))

# dimilar of a data frame creates new vectors, but with the same columns. Dangerous, as 
# changing the in one df can break the other.

head(df::AbstractDataFrame, r::Int) = df[1:min(r,nrow(df)), :]
head(df::AbstractDataFrame) = head(df, 6)
tail(df::AbstractDataFrame, r::Int) = df[max(1,nrow(df)-r+1):nrow(df), :]
tail(df::AbstractDataFrame) = tail(df, 6)

# to print a DataFrame, find the max string length of each column
# then print the column names with an appropriate buffer
# then row-by-row print with an appropriate buffer
_string(x) = sprint(showcompact, x)
maxShowLength(v::Vector) = length(v) > 0 ? max([length(_string(x)) for x = v]) : 0
maxShowLength(dv::AbstractDataVec) = max([length(_string(x)) for x = dv])
function show(io, df::AbstractDataFrame)
    ## TODO use alignment() like print_matrix in show.jl.
    nrowz, ncolz = size(df)
    println(io, "$(nrowz)x$(ncolz) $(typeof(df)):")
    gr = get_groups(df)
    if length(gr) > 0
        #print(io, "Column groups: ")
        pretty_show(io, gr)
        println(io)
    end
    N = nrow(df)
    Nmx = 20   # maximum head and tail lengths
    if N <= 2Nmx
        rowrng = 1:min(2Nmx,N)
    else
        rowrng = [1:Nmx, N-Nmx+1:N]
    end
    # we don't have row names -- use indexes
    rowNames = [@sprintf("[%d,]", r) for r = rowrng]
    
    rownameWidth = maxShowLength(rowNames)
    
    # if we don't have columns names, use indexes
    # note that column names in R are obligatory
    if eltype(colnames(df)) == Nothing
        colNames = [@sprintf("[,%d]", c) for c = 1:ncol(df)]
    else
        colNames = colnames(df)
    end
    
    colWidths = [max(length(string(colNames[c])), maxShowLength(df[rowrng,c])) for c = 1:ncol(df)]

    header = strcat(" " ^ (rownameWidth+1),
                    join([lpad(string(colNames[i]), colWidths[i]+1, " ") for i = 1:ncol(df)], ""))
    println(io, header)

    for i = 1:length(rowrng)
        rowname = rpad(string(rowNames[i]), rownameWidth+1, " ")
        line = strcat(rowname,
                      join([lpad(_string(df[rowrng[i],c]), colWidths[c]+1, " ") for c = 1:ncol(df)], ""))
        println(io, line)
        if i == Nmx && N > 2Nmx
            println(io, "  :")
        end
    end
end

# get the structure of a DF
function dump(io::IOStream, x::AbstractDataFrame, n::Int, indent)
    println(io, typeof(x), "  $(nrow(x)) observations of $(ncol(x)) variables")
    gr = get_groups(x)
    if length(gr) > 0
        pretty_show(io, gr)
        println(io)
    end
    if n > 0
        for col in names(x)[1:min(10,end)]
            print(io, indent, "  ", col, ": ")
            dump(io, x[col], n - 1, strcat(indent, "  "))
        end
    end
end
dump(io::IOStream, x::AbstractDataVec, n::Int, indent) =
    println(io, typeof(x), "(", length(x), ") ", x[1:min(4, end)])

# summarize the columns of a DF
# if the column's base type derives from Number, 
# compute min, 1st quantile, median, mean, 3rd quantile, and max
# filtering NAs, which are reported separately
# if boolean, report trues, falses, and NAs
# if anything else, punt.
# Note that R creates a summary object, which has a print method. That's
# a reasonable alternative to this. The summary() functions in show.jl
# return a string.
summary(dv::AbstractDataVec) = summary(OUTPUT_STREAM::IOStream, dv)
summary(df::DataFrame) = summary(OUTPUT_STREAM::IOStream, df)
function summary{T<:Number}(io, dv::AbstractDataVec{T})
    filtered = float(removeNA(dv))
    qs = quantile(filtered, [0, .25, .5, .75, 1])
    statNames = ["Min", "1st Qu.", "Median", "Mean", "3rd Qu.", "Max"]
    statVals = [qs[1:3], mean(filtered), qs[4:5]]
    for i = 1:6
        println(io, strcat(rpad(statNames[i], 8, " "), " ", string(statVals[i])))
    end
    nas = sum(isna(dv))
    if nas > 0
        println(io, "NAs      $nas")
    end
end
function summary{T}(io, dv::AbstractDataVec{T})
    ispooled = isa(dv, PooledDataVec) ? "Pooled " : ""
    # if nothing else, just give the length and element type and NA count
    println(io, "Length: $(length(dv))")
    println(io, "Type  : $(ispooled)$(string(eltype(dv)))")
    println(io, "NAs   : $(sum(isna(dv)))")
end

# TODO: clever layout in rows
# TODO: AbstractDataFrame
function summary(io, df::AbstractDataFrame)
    for c in 1:ncol(df)
        col = df[c]
        println(io, colnames(df)[c])
        summary(io, col)
        println(io, )
    end
end

##############################################################################
##
## We use SubDataFrame's to maintain a reference to a subset of a DataFrame
## without making copies.
##
##############################################################################

# a SubDataFrame is a lightweight wrapper around a DataFrame used most frequently in
# split/apply sorts of operations.
type SubDataFrame <: AbstractDataFrame
    parent::DataFrame
    rows::Vector{Int} # maps from subdf row indexes to parent row indexes
    
    function SubDataFrame(parent::DataFrame, rows::Vector{Int})
        if any(rows .< 1)
            error("all SubDataFrame indices must be > 0")
        end
        if max(rows) > nrow(parent)
            error("all SubDataFrame indices must be <= the number of rows of the DataFrame")
        end
        new(parent, rows)
    end
end

sub(D::DataFrame, r, c) = sub(D[[c]], r)    # If columns are given, pass in a subsetted parent D.
                                            # Columns are not copies, so it's not expensive.
sub(D::DataFrame, r::Int) = sub(D, [r])
sub(D::DataFrame, rs::Vector{Int}) = SubDataFrame(D, rs)
sub(D::DataFrame, r) = sub(D, ref(SimpleIndex(nrow(D)), r)) # this is a wacky fall-through that uses light-weight fake indexes!
sub(D::DataFrame, ex::Expr) = sub(D, with(D, ex))

sub(D::SubDataFrame, r, c) = sub(D[[c]], r)
sub(D::SubDataFrame, r::Int) = sub(D, [r])
sub(D::SubDataFrame, rs::Vector{Int}) = SubDataFrame(D.parent, D.rows[rs])
sub(D::SubDataFrame, r) = sub(D, ref(SimpleIndex(nrow(D)), r)) # another wacky fall-through
sub(D::SubDataFrame, ex::Expr) = sub(D, with(D, ex))
const subset = sub

ref(df::SubDataFrame, c) = df.parent[df.rows, c]
ref(df::SubDataFrame, r, c) = df.parent[df.rows[r], c]

nrow(df::SubDataFrame) = length(df.rows)
ncol(df::SubDataFrame) = ncol(df.parent)
colnames(df::SubDataFrame) = colnames(df.parent) 

# Associative methods:
index(df::SubDataFrame) = index(df.parent)

# DF column operations
######################

# assignments return the complete object...

# df[1] = replace column
function assign(df::DataFrame, newcol::AbstractDataVec, icol::Integer)
    if length(newcol) != nrow(df) && nrow(df) != 0
        throw(ArgumentError("Can't insert new DataFrame column of improper length"))
    end
    if icol > 0 && icol <= ncol(df)
        df.columns[icol] = newcol
    else
        if icol == ncol(df) + 1
            i = ncol(df) + 1
            push(df.colindex, "x$i")
            push(df.columns, newcol)
        else
            throw(ArgumentError("Can't insert new DataFrame column into a non-existent slot"))
        end
    end
    return df
end
assign{T}(df::DataFrame, newcol::Vector{T}, icol::Integer) = assign(df, DataVec(newcol), icol)
assign{T}(df::DataFrame, newcol::Range1{T}, icol::Integer) = assign(df, DataVec(newcol), icol)

# df["old"] = replace old columns
# df["new"] = append new column
function assign(df::DataFrame, newcol::AbstractDataVec, colname::String)
    icol = get(df.colindex.lookup, colname, 0)
    if length(newcol) != nrow(df) && nrow(df) != 0
        throw(ArgumentError("Can't insert new DataFrame column of improper length"))
    end
    if icol > 0
        # existing
        assign(df, newcol, icol)
    else
        # new
        push(df.colindex, colname)
        push(df.columns, newcol)
    end
    df
end
assign{T}(df::DataFrame, newcol::Vector{T}, colname::String) = assign(df, DataVec(newcol), colname)
assign{T}(df::DataFrame, newcol::Range1{T}, colname::String) = assign(df, DataVec(newcol), colname)

# df[:, "old"] = replace old columns
# df[:, "new"] = append new column
function assign(df::DataFrame, newcol::AbstractDataVec, rows::Range1, colname::String)
    if length(rows) != nrow(df) && start(rows) != 1
        error("Whole-column assignment must specify all existing rows")
    end
    icol = get(df.colindex.lookup, colname, 0)
    if length(newcol) != nrow(df) && nrow(df) != 0
        throw(ArgumentError("Can't insert new DataFrame column of improper length"))
    end
    if icol > 0
        # existing
        assign(df, newcol, icol)
    else
        # new
        push(df.colindex, colname)
        push(df.columns, newcol)
    end
    df
end
assign{T}(df::DataFrame, newcol::Vector{T}, rows::Range1, colname::String) = assign(df, DataVec(newcol), rows, colname)
assign{T}(df::DataFrame, newcol::Range1{T}, rows::Range1, colname::String) = assign(df, DataVec(newcol), rows, colname)

# assign(df::DataFrame, newcol, colname) =
#     nrow(df) > 0 ? assign(df, DataVec(fill(newcol, nrow(df))), colname) : assign(df, DataVec([newcol]), colname)

# do I care about vectorized assignment? maybe not...
# df[1:3] = (replace columns) eh...
# df[["new", "newer"]] = (new columns)

# df[1] = nothing
assign(df::DataFrame, x::Nothing, icol::Integer) = del!(df, icol)

## Multicolumn assignment like df2[1:2,:] = df2[4:5,:]
function assign(df1::DataFrame, df2::DataFrame, row::Int, cols::Range1)
    if ncol(df2) != length(cols)
        error("Dimensions do not match in assignment.")
    end
    for col in cols
        df1[row, col] = df2[row, col]
    end
    return df1
end

function assign(df1::DataFrame, df2::DataFrame, rows::Range1, col::Int)
    if nrow(df2) != length(rows)
        error("Dimensions do not match in assignment.")
    end
    for row in rows
        df1[row, col] = df2[row, col]
    end
    return df1
end

function assign(df1::DataFrame, df2::DataFrame, rows::Range1, cols::Range1)
    if nrow(df2) != length(rows) || ncol(df2) != length(cols)
        error("Dimensions do not match in assignment.")
    end
    for row in rows
        for col in cols
            df1[row, col] = df2[row, col]
        end
    end
    return df1
end

function assign{T <: Union(String, Number, NAtype)}(df::DataFrame, x::T, i::Int, j::Int)
    df.columns[j][i] = x
    return df
end

function assign{T <: Union(String, Number, NAtype)}(df::DataFrame, x::T, row::Int, cols::Range1)
    for col in cols
        df.columns[col][row] = x
    end
    return df
end

function assign{T <: Union(String, Number, NAtype)}(df::DataFrame, x::T, rows::Range1, col::Int)
    df.columns[col][rows] = x
    return df
end

function assign{T <: Union(String, Number, NAtype)}(df::DataFrame, x::T, rows::Range1, cols::Range1)
    for col in cols
        df.columns[col][rows] = x
    end
    return df
end

function assign{T <: Union(String, Number, NAtype)}(df::DataFrame, x::T, j::Int)
    for i in 1:nrow(df)
        df.columns[j][i] = x
    end
    return df
end

function assign{T <: Union(String, Number, NAtype)}(df::DataFrame, x::T, colname::String)
    j = get(df.colindex.lookup, colname, 0)
    n = nrow(df)
    if j == 0
        if n == 0
            n = 1
        end
        newcol = DataVec(Array(T, n), falses(n))
        for i in 1:n
            newcol[i] = x
        end
        push(df.colindex, colname)
        push(df.columns, newcol)
    else
        for i in 1:n
            df.columns[j][i] = x
        end
    end
    return df
end

# del!(df, 1)
# del!(df, "old")
function del!(df::DataFrame, icols::Vector{Int})
    for icol in icols 
        if icol > 0 && icol <= ncol(df)
            del(df.columns, icol)
            del(df.colindex, icol)
        else
            throw(ArgumentError("Can't delete a non-existent DataFrame column"))
        end
    end
    df
end
del!(df::DataFrame, c::Int) = del!(df, [c])
del!(df::DataFrame, c) = del!(df, df.colindex[c])

# df2 = del(df, 1) new DF, minus vectors
function del(df::DataFrame, icols::Vector{Int})
    newcols = _setdiff([1:ncol(df)], icols) 
    if length(newcols) == 0
        throw(ArgumentError("Can't delete a non-existent DataFrame column"))
    end
    # Note: this does not copy columns.
    df[newcols]
end
del(df::DataFrame, i::Int) = del(df, [i])
del(df::DataFrame, c) = del(df, df.colindex[c])
del(df::SubDataFrame, c) = SubDataFrame(del(df.parent, c), df.rows)

#### cbind, rbind, hcat, vcat
# hcat() is just cbind()
# rbind(df, ...) only accepts data frames. Finds union of columns, maintaining order
# of first df. Missing data becomes NAs.
# vcat() is just rbind()
 
# two-argument form, two dfs, references only
function cbind(df1::DataFrame, df2::DataFrame)
    # If df1 had metadata, we should copy that.
    colindex = Index(make_unique(concat(colnames(df1), colnames(df2))))
    columns = [df1.columns, df2.columns]
    d = DataFrame(columns, colindex)  
    set_groups(d, get_groups(df1))
    set_groups(d, get_groups(df2))
    return d
end
   
# three-plus-argument form recurses
cbind(a, b, c...) = cbind(cbind(a, b), c...)
hcat(dfs::DataFrame...) = cbind(dfs...)

is_group(df::AbstractDataFrame, name::ByteString) = is_group(index(df), name)

similar{T}(dv::DataVec{T}, dims) =
    DataVec(zeros(T, dims), fill(true, dims))

similar{T}(dv::PooledDataVec{T}, dims) =
    PooledDataVec(fill(uint16(1), dims), dv.pool)

similar(df::DataFrame, dims) = 
    DataFrame([similar(x, dims) for x in df.columns], colnames(df)) 

similar(df::SubDataFrame, dims) = 
    DataFrame([similar(df[x], dims) for x in colnames(df)], colnames(df)) 

nas{T}(dv::DataVec{T}, dims) =   # TODO move to datavec.jl?
    DataVec(zeros(T, dims), fill(true, dims))

zeros{T<:ByteString}(::Type{T},args...) = fill("",args...) # needed for string arrays in the `nas` method above
    
nas{T}(dv::PooledDataVec{T}, dims) =
    PooledDataVec(fill(uint16(1), dims), dv.pool)

nas(df::DataFrame, dims) = 
    DataFrame([nas(x, dims) for x in df.columns], colnames(df)) 

nas(df::SubDataFrame, dims) = 
    DataFrame([nas(df[x], dims) for x in colnames(df)], colnames(df)) 

rbind(df::DataFrame) = df

function rbind(df1::DataFrame, df2::DataFrame)
    if size(df1) == (0, 0) && size(df2) == (0, 0)
        return DataFrame(0, 0)
    end
    if size(df1) == (0, 0) && size(df2) != (0, 0)
        return df2
    end
    if size(df1) != (0, 0) && size(df2) == (0, 0)
        return df1
    end
    # Tolerate permutations of the same columns?
    # if any(coltypes(df1) .!= coltypes(df2)) || any(colnames(df1) .!= colnames(df2))
    #     error("Cannot rbind dissimilar DataFrames")
    # end
    res = DataFrame(coltypes(df1), nrow(df1) + nrow(df2))
    colnames!(res, colnames(df1))
    ind = 0
    for i in 1:nrow(df1)
        ind += 1
        for j in 1:ncol(df1)
            res[ind, j] = df1[i, j]
        end
    end
    for i in 1:nrow(df2)
        ind += 1
        for j in 1:ncol(df1)
            res[ind, j] = df2[i, j]
        end
    end
    return res
end

# Use induction to define results for arbitrary lengths?
function rbind(dfs::DataFrame...)
    res = dfs[1]
    for j in 2:length(dfs)
        res = rbind(res, dfs[j])
    end
    return res
end

function rbind(dfs::Vector)   # for a Vector of DataFrame's
    Nrow = sum(nrow, dfs)
    Ncol = ncol(dfs[1])
    res = similar(dfs[1], Nrow)
    # TODO fix PooledDataVec columns with different pools.
    # for idx in 2:length(dfs)
    #     if colnames(dfs[1]) != colnames(dfs[idx])
    #         error("DataFrame column names must match.")
    #     end
    # end
    idx = 1
    for df in dfs
        for kdx in 1:nrow(df)
            for jdx in 1:Ncol
                res[jdx][idx] = df[kdx, jdx]
            end
            idx += 1
        end
        set_groups(res, get_groups(df))
    end
    res
end

# function rbind(dfs::DataFrame...)
#     L = length(dfs)
#     T = 0
#     total_rows = 0
#     real_cols = 0
#     non_empty_dfs = Array(Any, L)
#     for i in 1:L
#         df = dfs[i]
#         if nrow(df) > 0
#             T += 1
#             non_empty_dfs[T] = df
#         end
#     end
#     if T == 0
#         return DataFrame(0, 0)
#     end
#     dfs = non_empty_dfs[1:T]
#     Nrow = sum(nrow, dfs)
#     Ncol = max(ncol, dfs)
#     res = similar(dfs[1], Nrow)
#     # TODO fix PooledDataVec columns with different pools.
#     # for idx in 2:length(dfs)
#     #     if colnames(dfs[1]) != colnames(dfs[idx])
#     #         error("DataFrame column names must match.")
#     #     end
#     # end
#     idx = 1
#     for df in dfs
#         for kdx in 1:nrow(df)
#             for jdx in 1:Ncol
#                 res[jdx][idx] = df[kdx, jdx]
#             end
#             idx += 1
#         end
#         set_groups(res, get_groups(df))
#     end
#     res
# end
vcat(dfs::DataFrame...) = rbind(dfs...)

# DF row operations -- delete and append
# df[1] = nothing
# df[1:3] = nothing
# df3 = rbind(df1, df2...)
# rbind!(df1, df2...)


# split-apply-combine
# co(ap(myfun,
#    sp(df, ["region", "product"])))
# (|)(x, f::Function) = f(x)
# split(df, ["region", "product"]) | (apply(nrow)) | mean
# apply(f::function) = (x -> map(f, x))
# split(df, ["region", "product"]) | @@@)) | mean
# how do we add col names to the name space?
# transform(df, :(cat=dog*2, clean=proc(dirty)))
# summarise(df, :(cat=sum(dog), all=strcat(strs)))

function with(d::Associative, ex::Expr)
    # Note: keys must by symbols
    replace_symbols(x, d::Dict) = x
    replace_symbols(e::Expr, d::Dict) = Expr(e.head, isempty(e.args) ? e.args : map(x -> replace_symbols(x, d), e.args), e.typ)
    function replace_symbols{K,V}(s::Symbol, d::Dict{K,V})
        if (K == Any || K == Symbol) && has(d, s)
            :(_D[$(expr(:quote,s))])
        elseif (K == Any || K <: String) && has(d, string(s))
            :(_D[$(string(s))])
        else
            s
        end
    end
    ex = replace_symbols(ex, d)
    global _ex = ex
    f = @eval (_D) -> $ex
    f(d)
end

function within!(d::Associative, ex::Expr)
    # Note: keys must by symbols
    replace_symbols(x, d::Associative) = x
    function replace_symbols{K,V}(e::Expr, d::Associative{K,V})
        if e.head == :(=) # replace left-hand side of assignments:
            if (K == Symbol || (K == Any && isa(keys(d)[1], Symbol)))
                exref = expr(:quote, e.args[1])
                if !has(d, e.args[1]) # Dummy assignment to reserve a slot.
                                      # I'm not sure how expensive this is.
                    d[e.args[1]] = values(d)[1]
                end
            else
                exref = string(e.args[1])
                if !has(d, exref) # dummy assignment to reserve a slot
                    d[exref] = values(d)[1]
                end
            end
            Expr(e.head,
                 vcat({:(_D[$exref])}, map(x -> replace_symbols(x, d), e.args[2:end])),
                 e.typ)
        else
            Expr(e.head, isempty(e.args) ? e.args : map(x -> replace_symbols(x, d), e.args), e.typ)
        end
    end
    function replace_symbols{K,V}(s::Symbol, d::Associative{K,V})
        if (K == Any || K == Symbol) && has(d, s)
            :(_D[$(expr(:quote,s))])
        elseif (K == Any || K <: String) && has(d, string(s))
            :(_D[$(string(s))])
        else
            s
        end
    end
    ex = replace_symbols(ex, d)
    f = @eval (_D) -> begin
        $ex
        _D
    end
    f(d)
end

function based_on(d::Associative, ex::Expr)
    # Note: keys must by symbols
    replace_symbols(x, d::Associative) = x
    function replace_symbols{K,V}(e::Expr, d::Associative{K,V})
        if e.head == :(=) # replace left-hand side of assignments:
            if (K == Symbol || (K == Any && isa(keys(d)[1], Symbol)))
                exref = expr(:quote, e.args[1])
                if !has(d, e.args[1]) # Dummy assignment to reserve a slot.
                                      # I'm not sure how expensive this is.
                    d[e.args[1]] = values(d)[1]
                end
            else
                exref = string(e.args[1])
                if !has(d, exref) # dummy assignment to reserve a slot
                    d[exref] = values(d)[1]
                end
            end
            Expr(e.head,
                 vcat({:(_ND[$exref])}, map(x -> replace_symbols(x, d), e.args[2:end])),
                 e.typ)
        else
            Expr(e.head, isempty(e.args) ? e.args : map(x -> replace_symbols(x, d), e.args), e.typ)
        end
    end
    function replace_symbols{K,V}(s::Symbol, d::Associative{K,V})
        if (K == Any || K == Symbol) && has(d, s)
            :(_D[$(expr(:quote,s))])
        elseif (K == Any || K <: String) && has(d, string(s))
            :(_D[$(string(s))])
        else
            s
        end
    end
    ex = replace_symbols(ex, d)
    f = @eval (_D) -> begin
        _ND = similar(_D)
        $ex
        _ND
    end
    f(d)
end

function within!(df::AbstractDataFrame, ex::Expr)
    # By-column operation within a DataFrame that allows replacing or adding columns.
    # Returns the transformed DataFrame.
    #   
    # helper function to replace symbols in ex with a reference to the
    # appropriate column in df
    replace_symbols(x, syms::Dict) = x
    function replace_symbols(e::Expr, syms::Dict)
        if e.head == :(=) # replace left-hand side of assignments:
            if !has(syms, string(e.args[1]))
                syms[string(e.args[1])] = length(syms) + 1
            end
            Expr(e.head,
                 vcat({:(_DF[$(string(e.args[1]))])}, map(x -> replace_symbols(x, syms), e.args[2:end])),
                 e.typ)
        else
            Expr(e.head, isempty(e.args) ? e.args : map(x -> replace_symbols(x, syms), e.args), e.typ)
        end
    end
    function replace_symbols(s::Symbol, syms::Dict)
        if contains(keys(syms), string(s))
            :(_DF[$(syms[string(s)])])
        else
            s
        end
    end
    # Make a dict of colnames and column positions
    cn_dict = Dict(colnames(df), 1:ncol(df))
    ex = replace_symbols(ex, cn_dict)
    f = @eval (_DF) -> begin
        $ex
        _DF
    end
    f(df)
end

within(x, args...) = within!(copy(x), args...)

function based_on_f(df::AbstractDataFrame, ex::Expr)
    # Returns a function for use on an AbstractDataFrame
    
    # helper function to replace symbols in ex with a reference to the
    # appropriate column in a new df
    replace_symbols(x, syms::Dict) = x
    function replace_symbols(e::Expr, syms::Dict)
        if e.head == :(=) # replace left-hand side of assignments:
            if !has(syms, string(e.args[1]))
                syms[string(e.args[1])] = length(syms) + 1
            end
            Expr(e.head,
                 vcat({:(_col_dict[$(string(e.args[1]))])}, map(x -> replace_symbols(x, syms), e.args[2:end])),
                 e.typ)
        else
            Expr(e.head, isempty(e.args) ? e.args : map(x -> replace_symbols(x, syms), e.args), e.typ)
        end
    end
    function replace_symbols(s::Symbol, syms::Dict)
        if contains(keys(syms), string(s))
            :(_DF[$(syms[string(s)])])
        else
            s
        end
    end
    # Make a dict of colnames and column positions
    cn_dict = Dict(colnames(df), [1:ncol(df)])
    ex = replace_symbols(ex, cn_dict)
    @eval (_DF) -> begin
        _col_dict = NamedArray()
        $ex
        DataFrame(_col_dict)
    end
end
function based_on(df::AbstractDataFrame, ex::Expr)
    # By-column operation within a DataFrame.
    # Returns a new DataFrame.
    f = based_on_f(df, ex)
    f(df)
end

function with(df::AbstractDataFrame, ex::Expr)
    # By-column operation with the columns of a DataFrame.
    # Returns the result of evaluating ex.
    
    # helper function to replace symbols in ex with a reference to the
    # appropriate column in df
    replace_symbols(x, syms::Dict) = x
    replace_symbols(e::Expr, syms::Dict) = Expr(e.head, isempty(e.args) ? e.args : map(x -> replace_symbols(x, syms), e.args), e.typ)
    function replace_symbols(s::Symbol, syms::Dict)
        if contains(keys(syms), string(s))
            :(_DF[$(syms[string(s)])])
        else
            s
        end
    end
    # Make a dict of colnames and column positions
    cn_dict = Dict(colnames(df), [1:ncol(df)])
    ex = replace_symbols(ex, cn_dict)
    f = @eval (_DF) -> $ex
    f(df)
end

with(df::AbstractDataFrame, s::Symbol) = df[string(s)]

# add function curries to ease pipelining:
with(e::Expr) = x -> with(x, e)
within(e::Expr) = x -> within(x, e)
within!(e::Expr) = x -> within!(x, e)
based_on(e::Expr) = x -> based_on(x, e)

# allow pipelining straight to an expression using within!:
(|)(x::AbstractDataFrame, e::Expr) = within!(x, e)

#
#  Split - Apply - Combine operations
#

function groupsort_indexer(x::Vector, ngroups::Integer)
    ## translated from Wes McKinney's groupsort_indexer in pandas (file: src/groupby.pyx).

    ## count group sizes, location 0 for NA
    n = length(x)
    ## counts = x.pool
    counts = fill(0, ngroups + 1)
    for i = 1:n
        counts[x[i] + 1] += 1
    end

    ## mark the start of each contiguous group of like-indexed data
    where = fill(1, ngroups + 1)
    for i = 2:ngroups+1
        where[i] = where[i - 1] + counts[i - 1]
    end
    
    ## this is our indexer
    result = fill(0, n)
    for i = 1:n
        label = x[i] + 1
        result[where[label]] = i
        where[label] += 1
    end
    result, where, counts
end
groupsort_indexer(pv::PooledDataVec) = groupsort_indexer(pv.refs, length(pv.pool))

##############################################################################
##
## GroupedDataFrame...
##
##############################################################################

type GroupedDataFrame
    parent::AbstractDataFrame
    cols::Vector         # columns used for sorting
    idx::Vector{Int}     # indexing vector when sorted by the given columns
    starts::Vector{Int}  # starts of groups
    ends::Vector{Int}    # ends of groups 
end

#
# Split
#
function groupby{T}(df::AbstractDataFrame, cols::Vector{T})
    ## a subset of Wes McKinney's algorithm here:
    ##     http://wesmckinney.com/blog/?p=489
    
    # use the pool trick to get a set of integer references for each unique item
    dv = PooledDataVec(df[cols[1]])
    # if there are NAs, add 1 to the refs to avoid underflows in x later
    dv_has_nas = (findfirst(dv.refs, 0) > 0 ? 1 : 0)
    x = copy(dv.refs) + dv_has_nas
    # also compute the number of groups, which is the product of the set lengths
    ngroups = length(dv.pool) + dv_has_nas
    # if there's more than 1 column, do roughly the same thing repeatedly
    for j = 2:length(cols)
        dv = PooledDataVec(df[cols[j]])
        dv_has_nas = (findfirst(dv.refs, 0) > 0 ? 1 : 0)
        for i = 1:nrow(df)
            x[i] += (dv.refs[i] + dv_has_nas- 1) * ngroups
        end
        ngroups = ngroups * (length(dv.pool) + dv_has_nas)
        # TODO if ngroups is really big, shrink it
    end
    (idx, starts) = groupsort_indexer(x, ngroups)
    # Remove zero-length groupings
    starts = _uniqueofsorted(starts) 
    ends = [starts[2:end] - 1]
    GroupedDataFrame(df, cols, idx, starts[1:end-1], ends)
end
groupby(d::AbstractDataFrame, cols) = groupby(d, [cols])

# add a function curry
groupby{T}(cols::Vector{T}) = x -> groupby(x, cols)
groupby(cols) = x -> groupby(x, cols)

start(gd::GroupedDataFrame) = 1
next(gd::GroupedDataFrame, state::Int) = 
    (sub(gd.parent, gd.idx[gd.starts[state]:gd.ends[state]]),
     state + 1)
done(gd::GroupedDataFrame, state::Int) = state > length(gd.starts)
length(gd::GroupedDataFrame) = length(gd.starts)
ref(gd::GroupedDataFrame, idx::Int) = sub(gd.parent, gd.idx[gd.starts[idx]:gd.ends[idx]]) 

function show(io, gd::GroupedDataFrame)
    N = length(gd)
    println(io, "$(typeof(gd))  $N groups with keys: $(gd.cols)")
    println(io, "First Group:")
    show(io, gd[1])
    if N > 1
        println(io, "       :")
        println(io, "       :")
        println(io, "Last Group:")
        show(io, gd[N])
    end
end

#
# Apply / map
#

# map() sweeps along groups
## function map(f::Function, gd::GroupedDataFrame)
##     [f(d) for d in gd]
## end
function map(f::Function, gd::GroupedDataFrame)
    #[g[1,gd.cols] => f(g) for g in gd]
    # List comprehensions have changed
    [f(g) for g in gd]
end
## function map(f::Function, gd::GroupedDataFrame)
##     # preallocate based on the results on the first one
##     x = f(gd[1])
##     res = Array(typeof(x), length(gd))
##     res[1] = x
##     for idx in 2:length(gd)
##         res[idx] = f(gd[idx])
##     end
##     res
## end

# with() sweeps along groups and applies with to each group
function with(gd::GroupedDataFrame, e::Expr)
    [with(d, e) for d in gd]
end

# within() sweeps along groups and applies within to each group
function within!(gd::GroupedDataFrame, e::Expr)   
    x = [within!(d[:,:], e) for d in gd]
    rbind(x...)
end

within!(x::SubDataFrame, e::Expr) = within!(x[:,:], e)

function within(gd::GroupedDataFrame, e::Expr)  
    x = [within(d, e) for d in gd]
    rbind(x...)
end

within(x::SubDataFrame, e::Expr) = within(x[:,:], e)

# based_on() sweeps along groups and applies based_on to each group
function based_on(gd::GroupedDataFrame, ex::Expr)  
    f = based_on_f(gd.parent, ex)
    x = [f(d) for d in gd]
    idx = fill([1:length(x)], convert(Vector{Int}, map(nrow, x)))
    keydf = gd.parent[gd.idx[gd.starts[idx]], gd.cols]
    resdf = rbind(x)
    cbind(keydf, resdf)
end

# default pipelines:
map(f::Function, x::SubDataFrame) = f(x)
(|)(x::GroupedDataFrame, e::Expr) = based_on(x, e)   
## (|)(x::GroupedDataFrame, f::Function) = map(f, x)

# apply a function to each column in a DataFrame
colwise(f::Function, d::AbstractDataFrame) = [f(d[idx]) for idx in 1:ncol(d)]
colwise(f::Function, d::GroupedDataFrame) = map(colwise(f), d)
colwise(f::Function) = x -> colwise(f, x)
colwise(f) = x -> colwise(f, x)
# apply several functions to each column in a DataFrame
colwise(fns::Vector{Function}, d::AbstractDataFrame) = [f(d[idx]) for f in fns, idx in 1:ncol(d)][:]
colwise(fns::Vector{Function}, d::GroupedDataFrame) = map(colwise(fns), d)
colwise(fns::Vector{Function}, d::GroupedDataFrame, cn::Vector{String}) = map(colwise(fns), d)
colwise(fns::Vector{Function}) = x -> colwise(fns, x)

function colwise(d::AbstractDataFrame, s::Vector{Symbol}, cn::Vector)
    header = [s2 * "_" * string(s1) for s1 in s, s2 in cn][:]
    payload = colwise(map(eval, s), d)
    df = DataFrame()
    # TODO fix this to assign the longest column first or preallocate
    # based on the maximum length.
    for i in 1:length(header)
        df[header[i]] = payload[i]
    end
    df
end
## function colwise(d::AbstractDataFrame, s::Vector{Symbol}, cn::Vector)
##     header = [s2 * "_" * string(s1) for s1 in s, s2 in cn][:]
##     payload = colwise(map(eval, s), d)
##     DataFrame(payload, header)
## end
colwise(d::AbstractDataFrame, s::Symbol, x) = colwise(d, [s], x)
colwise(d::AbstractDataFrame, s::Vector{Symbol}, x::String) = colwise(d, s, [x])
colwise(d::AbstractDataFrame, s::Symbol) = colwise(d, [s], colnames(d))
colwise(d::AbstractDataFrame, s::Vector{Symbol}) = colwise(d, s, colnames(d))

# TODO make this faster by applying the header just once.
# BUG zero-rowed groupings cause problems here, because a sum of a zero-length
# DataVec is 0 (not 0.0).
colwise(d::GroupedDataFrame, s::Vector{Symbol}) = rbind(map(x -> colwise(del(x, d.cols),s), d)...)
function colwise(gd::GroupedDataFrame, s::Vector{Symbol})
    payload = rbind(map(x -> colwise(del(x, gd.cols),s), gd)...)
    keydf = rbind(with(gd, :( _DF[1,$(gd.cols)] )))
    cbind(keydf, payload)
end
colwise(d::GroupedDataFrame, s::Symbol, x) = colwise(d, [s], x)
colwise(d::GroupedDataFrame, s::Vector{Symbol}, x::String) = colwise(d, s, [x])
colwise(d::GroupedDataFrame, s::Symbol) = colwise(d, [s])
(|)(d::GroupedDataFrame, s::Vector{Symbol}) = colwise(d, s)
(|)(d::GroupedDataFrame, s::Symbol) = colwise(d, [s])
colnames(d::GroupedDataFrame) = colnames(d.parent)

# by() convenience function
by(d::AbstractDataFrame, cols, f::Function) = map(f, groupby(d, cols))
by(d::AbstractDataFrame, cols, e::Expr) = based_on(groupby(d, cols), e)
by(d::AbstractDataFrame, cols, s::Vector{Symbol}) = colwise(groupby(d, cols), s)
by(d::AbstractDataFrame, cols, s::Symbol) = colwise(groupby(d, cols), s)

##
## Reshaping
##

function stack(df::DataFrame, icols::Vector{Int})
    remainingcols = _setdiff([1:ncol(df)], icols)
    res = rbind([insert(df[[i, remainingcols]], 1, colnames(df)[i], "key") for i in icols]...)
    replace_names!(res, colnames(res)[2], "value")
    res 
end
stack(df::DataFrame, icols) = stack(df, [df.colindex[icols]])

function unstack(df::DataFrame, ikey::Int, ivalue::Int, irefkey::Int)
    keycol = PooledDataVec(df[ikey])
    valuecol = df[ivalue]
    # TODO make a version with a default refkeycol
    refkeycol = PooledDataVec(df[irefkey])
    remainingcols = _setdiff([1:ncol(df)], [ikey, ivalue])
    Nrow = length(refkeycol.pool)
    Ncol = length(keycol.pool)
    # TODO make fillNA(type, length) 
    payload = DataFrame({DataVec([fill(valuecol[1],Nrow)], fill(true, Nrow))  for i in 1:Ncol}, map(string, keycol.pool))
    nowarning = true 
    for k in 1:nrow(df)
        j = int(keycol.refs[k])
        i = int(refkeycol.refs[k])
        if i > 0 && j > 0
            if nowarning && !isna(payload[j][i]) 
                println("Warning: duplicate entries in unstack.")
                nowarning = false
            end
            payload[j][i]  = valuecol[k]
        end
    end
    insert(payload, 1, refkeycol.pool, colnames(df)[irefkey])
end
unstack(df::DataFrame, ikey, ivalue, irefkey) =
    unstack(df, df.colindex[ikey], df.colindex[ivalue], df.colindex[irefkey])

##
## Join / merge
##

function join_idx(left, right, max_groups)
    ## adapted from Wes McKinney's full_outer_join in pandas (file: src/join.pyx).

    # NA group in location 0

    left_sorter, where, left_count = groupsort_indexer(left, max_groups)
    right_sorter, where, right_count = groupsort_indexer(right, max_groups)

    # First pass, determine size of result set, do not use the NA group
    count = 0
    rcount = 0
    lcount = 0
    for i in 2 : max_groups + 1
        lc = left_count[i]
        rc = right_count[i]

        if rc > 0 && lc > 0
            count += lc * rc
        elseif rc > 0
            rcount += rc
        else
            lcount += lc
        end
    end
    
    # group 0 is the NA group
    position = 0
    lposition = 0
    rposition = 0

    # exclude the NA group
    left_pos = left_count[1]
    right_pos = right_count[1]

    left_indexer = Array(Int, count)
    right_indexer = Array(Int, count)
    leftonly_indexer = Array(Int, lcount)
    rightonly_indexer = Array(Int, rcount)
    for i in 1 : max_groups + 1
        lc = left_count[i]
        rc = right_count[i]

        if rc == 0
            for j in 1:lc
                leftonly_indexer[lposition + j] = left_pos + j
            end
            lposition += lc
        elseif lc == 0
            for j in 1:rc
                rightonly_indexer[rposition + j] = right_pos + j
            end
            rposition += rc
        else
            for j in 1:lc
                offset = position + (j-1) * rc
                for k in 1:rc
                    left_indexer[offset + k] = left_pos + j
                    right_indexer[offset + k] = right_pos + k
                end
            end
            position += lc * rc
        end
        left_pos += lc
        right_pos += rc
    end

    ## (left_sorter, left_indexer, leftonly_indexer,
    ##  right_sorter, right_indexer, rightonly_indexer)
    (left_sorter[left_indexer], left_sorter[leftonly_indexer],
     right_sorter[right_indexer], right_sorter[rightonly_indexer])
end

function merge(df1::AbstractDataFrame, df2::AbstractDataFrame, bycol, jointype)

    dv1, dv2 = PooledDataVecs(df1[bycol], df2[bycol])
    left_indexer, leftonly_indexer,
    right_indexer, rightonly_indexer =
        join_idx(dv1.refs, dv2.refs, length(dv1.pool))

    if jointype == "inner"
        return cbind(df1[left_indexer,:], del(df2, bycol)[right_indexer,:])
    elseif jointype == "left"
        left = df1[[left_indexer,leftonly_indexer],:]
        right = rbind(del(df2, bycol)[right_indexer,:],
                      nas(del(df2, bycol), length(leftonly_indexer)))
        return cbind(left, right)
    elseif jointype == "right"
        left = rbind(df1[left_indexer,:],
                     nas(df1, length(rightonly_indexer)))
        right = del(df2, bycol)[[right_indexer,rightonly_indexer],:]
        return cbind(left, right)
    elseif jointype == "outer"
        left = rbind(df1[[left_indexer,leftonly_indexer],:],
                     nas(df1, length(rightonly_indexer)))
        right = rbind(del(df2, bycol)[right_indexer,:],
                      nas(del(df2, bycol), length(leftonly_indexer)),
                      del(df2, bycol)[rightonly_indexer,:])
        return cbind(left, right)
    end
    # TODO add support for multiple columns
end

merge(df1::AbstractDataFrame, df2::AbstractDataFrame, bycol) = merge(df1, df2, bycol, "inner")

# TODO: Make this method work with multiple columns
#       Will need to fix PooledDataVecs for that
function merge(df1::AbstractDataFrame, df2::AbstractDataFrame)
    s1 = Set{ByteString}()
    for coln in colnames(df1)
        add(s1, coln)
    end
    s2 = Set{ByteString}()
    for coln in colnames(df2)
        add(s2, coln)
    end
    bycol = first(elements(intersect(s1, s2)))
    merge(df1, df2, bycol, "inner")
end

##
## Miscellaneous
##

function complete_cases(df::AbstractDataFrame)
    ## Returns a Vector{Bool} of indexes of complete cases (rows with no NA's).
    res = !isna(df[1])
    for i in 2:ncol(df)
        res &= !isna(df[i])
    end
    res
end

function array(d::AbstractDataFrame)
    # DataFrame -> Array{Any}
    if nrow(d) == 1  # collapse to one element
       [el[1] for el in d[1,:]]
    else
       [col for col in d]
    end
end

# DataFrame -> Array{promoted_type, 2}
# Note: this doesn't work yet for DataVecs. It might once promotion
# with Arrays is added (work needed).
# matrix(d::AbstractDataFrame) = reshape([d...],size(d))
function matrix(df::DataFrame)
    n, p = size(df)
    m = zeros(n, p)
    for i in 1:n
        for j in 1:p
            if isna(df[i, j])
                error("DataFrame's with missing entries cannot be converted")
            else
                m[i, j] = df[i, j]
            end
        end
    end
    return m
end

function duplicated(df::AbstractDataFrame)
    # Return a Vector{Bool} indicated whether the row is a duplicate
    # of a prior row.
    res = fill(false, nrow(df))
    di = Dict()
    for i in 1:nrow(df)
        if has(di, array(df[i,:]))
            res[i] = true
        else
            di[array(df[i,:])] = 1 
        end
    end
    res
end

function drop_duplicates!(df::AbstractDataFrame)
    df = df[!duplicated(df), :]
    return
end

# Unique rows of an AbstractDataFrame.        
unique(df::AbstractDataFrame) = df[!duplicated(df), :] 

function duplicatedkey(df::AbstractDataFrame)
    # Here's another (probably a lot faster) way to do `duplicated`
    # by grouping on all columns. It will fail if columns cannot be
    # made into PooledDataVec's.
    gd = groupby(df, colnames(df))
    idx = [1:length(gd.idx)][gd.idx][gd.starts]
    res = fill(true, nrow(df))
    res[idx] = false
    res
end

function isna(df::DataFrame)
    results = BitArray(size(df))
    for i in 1:nrow(df)
        for j in 1:ncol(df)
            results[i, j] = isna(df[i, j])
        end
    end
    return results
end

function isnan(df::DataFrame)
    p = ncol(df)
    res_columns = Array(Any, p)
    for j in 1:p
        res_columns[j] = isnan(df[j])
    end
    return DataFrame(res_columns, colnames(df))
end

function isfinite(df::DataFrame)
    p = ncol(df)
    res_columns = Array(Any, p)
    for j in 1:p
        res_columns[j] = isfinite(df[j])
    end
    return DataFrame(res_columns, colnames(df))
end
