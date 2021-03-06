# WriteVTK

[![Build Status](https://travis-ci.com/jipolanco/WriteVTK.jl.svg?branch=master)](https://travis-ci.com/jipolanco/WriteVTK.jl)
[![DOI](https://zenodo.org/badge/32700186.svg)](https://zenodo.org/badge/latestdoi/32700186)

This module allows to write VTK XML files, that can be visualised for example
with [ParaView](http://www.paraview.org/).

The data is written compressed by default, using the
[CodecZlib](https://github.com/bicycle1885/CodecZlib.jl) package.

Rectilinear (.vtr), structured (.vts), image data (.vti) and unstructured
(.vtu) grids are supported.
Multiblock files (.vtm), which can point to multiple VTK files, can also be
exported.

## Contents

  - [Installation](#installation)
  - [Rectilinear and structured meshes](#usage-rectilinear-and-structured-meshes)
  - [Image data](#usage-image-data)
  - [Julia array](#usage-julia-array)
  - [Unstructured meshes](#usage-unstructured-meshes)
  - [Multiblock files](#multiblock-files)
  - [Paraview PVD files](#paraview-data-pvd-file-format)
  - [Do-block syntax](#do-block-syntax)
  - [Additional options](#additional-options)
  - [Examples](#examples)

## Installation

From the Julia REPL:

``` julia
Pkg.add("WriteVTK")
```

Then load the module in Julia with:

``` julia
using WriteVTK
```

## Usage: rectilinear and structured meshes

### Define a grid

The function `vtk_grid` initialises the VTK file.
This function requires a filename with no extension, and the grid coordinates.
Depending on the shape of the arrays `x`, `y` and `z`, either a rectilinear or
structured grid is created.

``` julia
vtkfile = vtk_grid("my_vtk_file", x, y, z) # 3-D
vtkfile = vtk_grid("my_vtk_file", x, y)    # 2-D
```

Required array shapes for each grid type:

  - Rectilinear grid: `x`, `y`, `z` are 1-D arrays with different lengths in
    general (`Ni`, `Nj` and `Nk` respectively).
  - Structured grid: `x`, `y`, `z` are 3-D arrays with the same
    shape: `[Ni, Nj, Nk]`. For the two dimensional case, `x` and `y` are 2-D arrays
    with shape `[Ni, Nj]`

Alternatively, in the case of structured grids, the grid points can be defined from a
single 4-D array `xyz`, of dimensions `[3, Ni, Nj, Nk]`. For the two dimensional case
`xy` is a 3-D array, with dimensions `[2, Ni, Nj]`:

``` julia
vtkfile = vtk_grid("my_vtk_file", xyz) # 3-D
vtkfile = vtk_grid("my_vtk_file", xy)  # 2-D
```

This is actually more efficient than the previous formulation.

### Add some data to the file

In a VTK file, data can be associated to grid points or to data cells
(see [Defining cells](#defining-cells) for details on cells).
Data is written to a VTK file object using the syntax
```julia
vtkfile["Velocity"] = vel
vtkfile["Pressure"] = p
vtkfile["Concentration"] = C
```
where the "index" is the name of the dataset in the VTK file.

It is also possible to write datasets whose dimensions are independent of the
discrete geometry.
In VTK this is called "field data", and can be used to write metadata such as
time information or strings:
```julia
vtkfile["Time"] = 42.0
vtkfile["Date"] = "30/05/2020"
vtkfile["Distances"] = [2.0, 4.0, 8.0]
```

For convenience, the input data is automatically associated either to grid
points or data cells, or interpreted as field data, according to the input data
dimensions.
If more control is desired, one can explicitly pass a `VTKPointData`,
a `VTKCellData` or a `VTKFieldData` instance as a second index:
```julia
vtkfile["Velocity", VTKPointData()] = vel
vtkfile["Pressure", VTKCellData()] = p
vtkfile["Time", VTKFieldData()] = 42.0
```

Note that in rectilinear and structured meshes, the cell dimensions are
always `(Ni - 1, Nj - 1, Nk - 1)`, and the dimensions of the data arrays associated to cells should be consistent with these dimensions.

The input array can represent either scalar or vectorial data.
The shape of the array should be `(Ni, Nj, Nk)` for scalars, and
`(Nc, Ni, Nj, Nk)` for vectors, where `Nc` is the number of components of
the vector.

Vector datasets can also be given as a tuple of scalar datasets, where each
scalar represents a component of the vector field.
Example:
```julia
acc = (acc_x, acc_y, acc_z)  # acc_x, acc_y and acc_z have size (Ni, Nj, Nk)
vtkfile["Acceleration"] = acc
```
This can be useful to avoid copies of data in some cases.

### Save the file

Finally, close and save the file with `vtk_save`:

``` julia
outfiles = vtk_save(vtkfile)
```

`outfiles` is an array of strings with the paths to the generated files.
In this case, the array is of length 1, but that changes when working
with [multiblock files](#multiblock-files).


## Usage: image data

The points and cells of an image data file are defined by the number of points
in each direction, `(Nx, Ny, Nz)`.
The origin of the dataset and the spacing in each direction can be optionally
included.
Example:

``` julia
Nx, Ny, Nz = 10, 12, 42
origin = [3.0, 4.0, -3.2]
spacing = [0.1, 0.2, 0.3]
vtk = vtk_grid("my_vti_file", Nx, Ny, Nz, origin=origin, spacing=spacing)
vtk_save(vtk)
```

Coordinates may also be specified using ranges (more precisely, any subtype of `AbstractRange`).
Some examples:

```julia
# Using StepRangeLen objects
vtk_grid("vti_file_1", 0:0.1:10, 0:0.2:10, 1:0.3:4)

# Using LinRange objects
vtk_grid("vti_file_2", LinRange(0, 4.2, 10), LinRange(1, 3.1, 42), LinRange(0.2, 12.1, 32))
```

## Usage: Julia arrays

A convenience function is provided to quickly save Julia arrays as image data:

```julia
A = rand(100, 100, 100)
vtk_write_array("my_vti_file", A, "my_property_name")
```

## Usage: unstructured meshes

An unstructured mesh is defined by a set of points in space and a set of cells
that connect those points.

### Defining cells

In WriteVTK, a cell is defined using the MeshCell type:

``` julia
cell = MeshCell(cell_type, connectivity)
```

  - `cell_type` is of type `VTKCellType` which contains the name and an integer value that
    determines the type of the cell, as defined in the
    [VTK specification](http://www.vtk.org/VTK/img/file-formats.pdf) (see figures 2 and 3 in
    that document). For convenience, WriteVTK includes a `VTKCellTypes` module that contains
    these definitions. For instance, a triangle is associated to the value `cell_type = VTKCellTypes.VTK_TRIANGLE`.
    Cell types may also be constructed from their associated integer identifier.
    For instance, `VTKCellType(5)` also returns a `VTK_TRIANGLE` cell type.

  - `connectivity` is a vector of indices that determine the mesh points that are connected
    by the cell. In the case of a triangle, this would be an integer array of length 3.

    Note that the connectivity indices are one-based (as opposed to
    [zero-based](https://en.wikipedia.org/wiki/Zero-based_numbering)), following the
    convention in Julia.

### Generating an unstructured VTK file

First, initialise the file:

``` julia
vtkfile = vtk_grid("my_vtk_file", points, cells)
```

  - `points` is an array with the point locations, of dimensions `[dim, num_points]` where
    `dim` is the dimension (1, 2 or 3) and `num_points` the number of points.

  - `cells` is a MeshCell array that contains all the cells of the mesh. For example:

    ``` julia
    # Suppose that the mesh is made of 5 points:
    cells = [MeshCell(VTKCellTypes.VTK_TRIANGLE, [1, 4, 2]),
             MeshCell(VTKCellTypes.VTK_QUAD,     [2, 4, 3, 5])]
    ```

Alternatively, the grid points can be defined from 1-D arrays `x`, `y`,
`z` with equal lengths `num_points`:

``` julia
vtkfile = vtk_grid("my_vtk_file", x, y, z, cells) # 3D
vtkfile = vtk_grid("my_vtk_file", x, y, cells)    # 2D
vtkfile = vtk_grid("my_vtk_file", x, cells)       # 1D
```

or from a 4-D array `points`, with dimension `[dim, Ni, Nj, Nk]` where `dim` is the dimension
and `Ni`,`Nj`,`Nk` the number of points in each direction `x`,`y`,`z`:

``` julia
vtkfile = vtk_grid("my_vtk_file", points, cells)
```
These two last methods are less efficient though.

Now add some data to the file.
It is possible to add both point data and cell data:
``` julia
vtkfile["my_point_data", VTKPointData()] = pdata
vtkfile["my_cell_data", VTKCellData()] = cdata
```
The `pdata` and `cdata` arrays must have sizes consistent with the number of
points and cells in the mesh, respectively.
Note that, as discussed [above](#add-some-data-to-the-file), the second
argument (`VTKPointData()` or `VTKCellData()`) can be generally omitted.
In this case, its value will be automatically determined from the input data
dimensions.

Finally, close and save the file:
``` julia
outfiles = vtk_save(vtkfile)
```

## Multiblock files

Multiblock files (.vtm) are XML VTK files that can point to multiple other VTK
files.
They can be useful when working with complex geometries that are composed of
multiple sub-domains.
In order to generate multiblock files, the `vtk_multiblock` function must be used.
The functions introduced above are then used with some small modifications.

First, a multiblock file must be initialised:

``` julia
vtmfile = vtk_multiblock("my_vtm_file")
```

Then, each sub-grid can be generated with `vtk_grid` using the `vtmfile` object
as the first argument:

``` julia
# First block.
vtkfile = vtk_grid(vtmfile, x1, y1, z1)
vtkfile["Pressure"] = p1

# Second block.
vtkfile = vtk_grid(vtmfile, x2, y2, z2)
vtkfile["Pressure"] = p2
```

Finally, only the multiblock file needs to be saved explicitly:

``` julia
outfiles = vtk_save(vtmfile)
```

Assuming that the two blocks are structured grids, this generates the files
`my_vtm_file.vtm`, `my_vtm_file_1.vts` and `my_vtm_file_2.vts`, where the
`vtm` file points to the two `vts` files.


## Paraview Data (PVD) file format

A `pvd` file is a collection of VTK files, typically for holding results at
different time steps in a simulation. A `pvd` file is initialised with:
``` julia
pvd = paraview_collection("my_pvd_file")
```
By default this overwrites existent `pvd` files.
To append new datasets to an existent `pvd` file, set the `append` option to
`true`:
```julia
pvd = paraview_collection("my_pvd_file", append=true)
```

VTK files are then added to the `pvd` file with
```julia
pvd[time] = vtkfile
```
Here, `time` is a real number that represents the current time (or timestep) in
the simulation.

When all the files are added to the `pvd` file, it can be saved using:
``` julia
vtk_save(pvd)
```

## Do-block syntax

[Do-block syntax](https://docs.julialang.org/en/latest/manual/functions/#Do-Block-Syntax-for-Function-Arguments-1)
is supported by `vtk_grid`, `vtk_multiblock` and `paraview_collection`.
At the end of the do-block, `vtk_save` is called implicitly on the generated
VTK object.
Example:

``` julia
# Rectilinear or structured grid
outfiles = vtk_grid("my_vtk_file", x, y, z) do vtk
    vtk["Pressure"] = p
    vtk["Velocity"] = vel
end

# Multiblock file
outfiles = vtk_multiblock("my_vtm_file") do vtm
    vtk = vtk_grid(vtm, x1, y1, z1)
    vtk["Velocity"] = vel1

    vtk = vtk_grid(vtm, x2, y2, z2)
    vtk["Velocity"] = vel2
end
```


## Additional options

By default, numerical data is written to the XML files as compressed raw binary
data.
This can be changed using the optional `compress` and `append` parameters of
the `vtk_grid` functions.

For instance, to disable both compressing and appending raw data in the case of
unstructured meshes:

``` julia
vtk = vtk_grid("my_vtk_file", points, cells; compress=false, append=false)
```

  - If `append` is `true` (default), data is written appended at the end of the
    XML file as raw binary data.
    Note that this violates the XML specification, although it is allowed by VTK.

    Otherwise, if `append` is `false`, data is written "inline", and base-64
    encoded instead of raw.
    This is usually slower than writing raw binary data, and also results in
    larger files, but is valid according to the XML specification.

  - If `compress` is `true` (default), data is first compressed using zlib.
    Its value may also be a compression level between 1 (fast compression)
    and 9 (best compression).

## Examples

See some examples in the `test/` directory.
