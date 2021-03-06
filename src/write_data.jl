"""
    AbstractFieldData

Abstract type representing any kind of dataset.
"""
abstract type AbstractFieldData end

# Numerical data may be associated to grid points, cells, or none.
struct VTKPointData <: AbstractFieldData end
struct VTKCellData <: AbstractFieldData end
struct VTKFieldData <: AbstractFieldData end

# These are the VTK names associated to each data "location".
node_type(::VTKPointData) = "PointData"
node_type(::VTKCellData) = "CellData"
node_type(::VTKFieldData) = "FieldData"

const ArrayOrValue = Union{AbstractArray, Number, String}
const NumericArray = AbstractArray{T} where {T <: Number}
const ListOfStrings = Union{Tuple{Vararg{String}}, AbstractArray{String}}

# Determine number of components of input data.
function num_components(data::ArrayOrValue, num_points_or_cells)
    Nc = div(length(data), num_points_or_cells)
    if Nc * num_points_or_cells != length(data)
        throw(DimensionMismatch("incorrect dimensions of input array."))
    end
    Nc
end

num_components(data::NumericArray, vtk, ::VTKPointData) =
    num_components(data, vtk.Npts)
num_components(data::NumericArray, vtk, ::VTKCellData) =
    num_components(data, vtk.Ncls)
num_components(data::NumericArray, vtk, ::VTKFieldData) = 1
num_components(::Union{Number,String}, args...) = 1
num_components(data::ListOfStrings, args...) = 1
num_components(data::NTuple, args...) = length(data)

# This is for the NumberOfTuples attribute of FieldData.
num_field_tuples(data::ArrayOrValue) = length(data)
num_field_tuples(data::ListOfStrings) = length(data)
num_field_tuples(data::String) = 1
num_field_tuples(data::NTuple) = num_field_tuples(first(data))

# Guess from data dimensions whether data should be associated to points,
# cells or none.
function guess_data_location(data, vtk)
    N = length(data)
    if rem(N, vtk.Npts) == 0
        VTKPointData()
    elseif rem(N, vtk.Ncls) == 0
        VTKCellData()
    else
        VTKFieldData()
    end
end

guess_data_location(data::NTuple, args...) =
    guess_data_location(first(data), args...)

guess_data_location(data::Tuple{}, args...) = VTKPointData()

"""
    VTKDataType

Union of data types allowed by VTK.
"""
const VTKDataType = Union{Int8, UInt8, Int16, UInt16, Int32, UInt32,
                          Int64, UInt64, Float32, Float64, String}

# Return the VTK string representation of a numerical data type.
function datatype_str(::Type{T}) where T <: VTKDataType
    # Note: the VTK type names are exactly the same as the Julia type names
    # (e.g.  Float64 -> "Float64"), so that we can simply use the `string`
    # function.
    string(T)
end

datatype_str(::Type{T}) where T =
    throw(ArgumentError("data type not supported by VTK: $T"))
datatype_str(v) = datatype_str(typeof(v))
datatype_str(::AbstractArray{T}) where T = datatype_str(T)
datatype_str(::NTuple{N, T} where N) where T <: AbstractArray =
    datatype_str(eltype(T))
datatype_str(::ListOfStrings) = datatype_str(String)

# Total size of data in bytes.
sizeof_data(x) = sizeof(x)
sizeof_data(x::String) = sizeof(x) + sizeof("\0")
sizeof_data(x::AbstractArray) = length(x) * sizeof(eltype(x))
sizeof_data(x::ListOfStrings) = sum(sizeof_data, x)
sizeof_data(x::NTuple) = sum(sizeof_data, x)

write_array(io, data) = write(io, data)
write_array(io, x::String) = write(io, x, '\0')
write_array(io, x::ListOfStrings) = sum(s -> write_array(io, s), x)

function write_array(io, data::NTuple)
    n = 0
    for i in eachindex(data...), x in data
        n += write(io, x[i])
    end
    n
end

function set_num_components(xDA, vtk, data, loc)
    Nc = num_components(data, vtk, loc)
    set_attribute(xDA, "NumberOfComponents", Nc)
    nothing
end

# In the specific case of FieldData, we also need to set the number of "tuples"
# (number of elements per field component).
function set_num_components(xDA, vtk, data, loc::VTKFieldData)
    Nc = num_components(data, vtk, loc)
    Nt = num_field_tuples(data)
    set_attribute(xDA, "NumberOfComponents", Nc)
    set_attribute(xDA, "NumberOfTuples", Nt)
    nothing
end

xml_data_array_name(::Any) = "DataArray"
xml_data_array_name(::Union{String,ListOfStrings}) = "Array"

"""
    data_to_xml(
        vtk::DatasetFile, xParent::XMLElement, data,
        name::AbstractString, Nc::Union{Int,AbstractFieldData} = 1,
    )

Add numerical data to VTK XML file.

Data is written under the `xParent` XML node.

`Nc` may be either the number of components, or the type of field data.
In the latter case, the number of components will be deduced from the data
dimensions and the type of field data.
"""
function data_to_xml(vtk, xParent, data, name,
                     Nc::Union{Int,AbstractFieldData}=1)
    xDA = new_child(xParent, xml_data_array_name(data))
    set_attribute(xDA, "type", datatype_str(data))
    set_attribute(xDA, "Name", name)
    if Nc isa Int
        set_attribute(xDA, "NumberOfComponents", Nc)
    else
        set_num_components(xDA, vtk, data, Nc)
    end
    if vtk.appended
        data_to_xml_appended(vtk, xDA, data)
    else
        data_to_xml_inline(vtk, xDA, data)
    end
end

"""
    data_to_xml_appended(vtk::DatasetFile, xDA::XMLElement, data)

Add appended raw binary data to VTK XML file.

Data is written to the `vtk.buf` buffer.

When compression is enabled:

  * the data array is written in compressed form (obviously);

  * the header, written before the actual numerical data, is an array of UInt32
    values:
        `[num_blocks, blocksize, last_blocksize, compressed_blocksizes]`
    All the sizes are in bytes. The header itself is not compressed, only the
    data is.
    For more details, see:
        http://public.kitware.com/pipermail/paraview/2005-April/001391.html
        http://mathema.tician.de/what-they-dont-tell-you-about-vtk-xml-binary-formats
    (This is not really documented in the VTK specification...)

Otherwise, if compression is disabled, the header is just a single UInt32 value
containing the size of the data array in bytes.

"""
function data_to_xml_appended(vtk::DatasetFile, xDA::XMLElement, data)
    @assert vtk.appended

    buf = vtk.buf    # append buffer
    compress = vtk.compression_level > 0

    # DataArray node
    set_attribute(xDA, "format", "appended")
    set_attribute(xDA, "offset", position(buf))

    # Size of data array (in bytes).
    nb = sizeof_data(data)

    if compress
        initpos = position(buf)

        # Write temporary array that will be replaced later by the real header.
        header = zeros(UInt32, 4)
        write(buf, header)

        # Write compressed data.
        zWriter = ZlibCompressorStream(buf, level=vtk.compression_level)
        write_array(zWriter, data)
        write(zWriter, TranscodingStreams.TOKEN_END)
        flush(zWriter)

        # Go back to `initpos` and write real header.
        endpos = position(buf)
        compbytes = endpos - initpos - sizeof(header)
        header[:] = [1, nb, nb, compbytes]
        seek(buf, initpos)
        write(buf, header)
        seek(buf, endpos)
    else
        write(buf, UInt32(nb))  # header (uncompressed version)
        nb_write = write_array(buf, data)
        @assert nb_write == nb
    end

    xDA::XMLElement
end

"""
    data_to_xml_inline(vtk::DatasetFile, xDA::XMLElement, data)

Add inline, base64-encoded data to VTK XML file.
"""
function data_to_xml_inline(vtk::DatasetFile, xDA::XMLElement, data)
    @assert !vtk.appended
    compress = vtk.compression_level > 0

    # DataArray node
    set_attribute(xDA, "format", "binary")   # here, binary means base64-encoded

    # Number of bytes of data.
    nb = sizeof_data(data)

    # Write data to a buffer, which is then base64-encoded and added to the
    # XML document.
    buf = IOBuffer()

    # NOTE: in the compressed case, the header and the data need to be
    # base64-encoded separately!!
    # That's why we don't use a single buffer that contains both, like in the
    # other data_to_xml function.
    local zWriter
    if compress
        # Write compressed data.
        zWriter = ZlibCompressorStream(buf, level=vtk.compression_level)
        write_array(zWriter, data)
        write(zWriter, TranscodingStreams.TOKEN_END)
        flush(zWriter)
    else
        write_array(buf, data)
    end

    # Write buffer with data to XML document.
    add_text(xDA, "\n")
    if compress
        header = UInt32[1, nb, nb, position(buf)]
        add_text(xDA, base64encode(header))
    else
        add_text(xDA, base64encode(UInt32(nb)))     # header (uncompressed version)
    end
    add_text(xDA, base64encode(take!(buf)))
    add_text(xDA, "\n")

    if compress
        close(zWriter)
    end
    close(buf)

    xDA::XMLElement
end

"""
    add_field_data(vtk::DatasetFile, data,
                   name::AbstractString, loc::AbstractFieldData)

Add either point or cell data to VTK file.
"""
function add_field_data(vtk::DatasetFile, data, name::AbstractString,
                        loc::AbstractFieldData)
    # Find Piece node.
    xroot = root(vtk.xdoc)
    xGrid = find_element(xroot, vtk.grid_type)

    xbase = if loc === VTKFieldData()
        xGrid
    else
        find_element(xGrid, "Piece")
    end

    # Find or create "nodetype" (PointData, CellData or FieldData) node.
    nodetype = node_type(loc)
    xtmp = find_element(xbase, nodetype)
    xPD = (xtmp === nothing) ? new_child(xbase, nodetype) : xtmp

    # DataArray node
    xDA = data_to_xml(vtk, xPD, data, name, loc)

    vtk
end

vtk_point_data(args...) = add_field_data(args..., VTKPointData())
vtk_cell_data(args...) = add_field_data(args..., VTKCellData())
vtk_field_data(args...) = add_field_data(args..., VTKFieldData())

"""
    setindex!(vtk::DatasetFile, data, name::AbstractString, [field_type])

Add a new dataset to VTK file.

The number of components of the dataset (e.g. for scalar or vector fields) is
determined automatically from the input data dimensions.

The optional argument `field_type` should be an instance of `VTKPointData`,
`VTKCellData` or `VTKFieldData`.
It determines whether the data should be associated to grid points, cells or
none.
If not given, this is guessed from the input data size and the grid dimensions.

# Example

Add "velocity" dataset and time scalar to VTK file.

```julia
vel = rand(3, 12, 14, 42)  # vector field
time = 42.0

vtk = vtk_grid(...)
vtk["velocity", VTKPointData()] = vel
vtk["time", VTKFieldData()] = time

# This also works, and will generally give the same result:
vtk["velocity"] = vel
vtk["time"] = time
```
"""
Base.setindex!(vtk::DatasetFile, data, name::AbstractString,
               loc::AbstractFieldData) = add_field_data(vtk, data, name, loc)

function Base.setindex!(vtk::DatasetFile, data, name::AbstractString)
    loc = guess_data_location(data, vtk) :: AbstractFieldData
    setindex!(vtk, data, name, loc)
end
