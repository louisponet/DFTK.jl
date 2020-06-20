# Routines for interaction with spglib
const SPGLIB = spglib_jll.libsymspg

function spglib_get_error_message()
    error_code = ccall((:spg_get_error_code, SPGLIB), Cint,(Cvoid,),Cvoid())
    return ccall((:spg_get_error_message, SPGLIB), String,(Cint,), error_code)
end

function spglib_get_symmetry_(unit_cell; maxsize = 384, symprec = 1e-5)
    rotations    = Array{Cint}(undef, 3, 3, maxsize)
    translations = Array{Cdouble}(undef, 3, maxsize)
    cell, positions, indices = unit_cell
    
    num_ops = ccall((:spg_get_symmetry, SPGLIB), Cint,
      (Ptr{Cint}, Ptr{Cdouble}, Cint, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cdouble),
       rotations, translations, Cint(maxsize), cell, positions, indices, Cint(length(indices)), symprec)
    #Note: spglib_jll returns transposed rotation matrix vs the python spglib interface
    return num_ops, [Vec3(translations[:, i]) for i in 1:num_ops], [Mat3(rotations[:, :, i])' for i in 1:num_ops]
end
"""
Construct a tuple containing the lattice and the positions of the species
in the convention required to take the place of a `cell` datastructure used in spglib.
"""
function spglib_cell_atommapping_(lattice, atoms)
    lattice = Matrix{Cdouble}(lattice)  # spglib operates in double precision
    n_attypes = isempty(atoms) ? 0 : sum(length(positions) for (type, positions) in atoms)
    spg_numbers = Vector{Cint}(undef, n_attypes)
    spg_positions = Matrix{Cdouble}(undef, 3, n_attypes)

    offset = 0
    nextnumber = 1
    atommapping = Dict{Int, Any}()
    for (iatom, (type, positions)) in enumerate(atoms)
        atommapping[nextnumber] = type
        for (ipos, pos) in enumerate(positions)
            # assign the same number to all types with this position
            spg_numbers[offset + ipos] = nextnumber
            spg_positions[:, offset + ipos] .= pos
        end
        offset += length(positions)
        nextnumber += 1
    end

    # Note: DFTK and C spglib both use lattice vectors as columns.
    (lattice, spg_positions, spg_numbers), atommapping
end
spglib_cell(lattice, atoms) = first(spglib_cell_atommapping_(lattice, atoms))


@timing function spglib_get_symmetry(lattice, atoms; tol_symmetry=1e-5)
    # lattice = Matrix{Float64}(lattice)  # spglib operates in double precision

    if isempty(atoms)
        # spglib doesn't like no atoms, so we default to
        # no symmetries (even though there are lots)
        return [Mat3{Int}(I)], [Vec3(zeros(3))]
    end

    # Ask spglib for symmetry operations and for irreducible mesh
    spg_numops, spg_translations, spg_rotations = spglib_get_symmetry_(spglib_cell(lattice, atoms),
                                                                       symprec=tol_symmetry)

    # If spglib does not find symmetries give an error
    if spg_numops == 0
        err_message = spglib_get_error_message()
        error("spglib failed to get the symmetries. Check your lattice, use a " *
              "uniform BZ mesh or disable symmetries. Spglib reported : " * err_message)
    end

    Stildes = spg_rotations
    τtildes = [rationalize.(τt, tol=tol_symmetry) for τt in spg_translations]
    
    # Checks: (A Stilde A^{-1}) is unitary
    for Stilde in Stildes
        Scart = lattice * Stilde * inv(lattice)  # Form S in cartesian coords
        if maximum(abs, Scart'Scart - I) > tol_symmetry
            error("spglib returned non-unitary rotation matrix")
        end
    end

    # Check (Stilde, τtilde) maps atoms to equivalent atoms in the lattice
    for (Stilde, τtilde) in zip(Stildes, τtildes)
        for (elem, positions) in atoms
            for coord in positions
                diffs = [rationalize.(Stilde * coord + τtilde - pos, tol=tol_symmetry)
                         for pos in positions]

                # If all elements of a difference in diffs is integer, then
                # Stilde * coord + τtilde and pos are equivalent lattice positions
                if !any(all(isinteger, d) for d in diffs)
                    error("Cannot map the atom at position $coord to another atom of the " *
                          "same element under the symmetry operation (Stilde, τtilde):\n" *
                          "($Stilde, $τtilde)")
                end
            end
        end
    end

    Stildes, τtildes
end

function spglib_standardize_cell_(unit_cell, to_primitive, no_idealize, symprec)
    cell, positions, indices = copy.(unit_cell)
    num_atoms = ccall((:spg_standardize_cell, SPGLIB), Cint,
      (Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint}, Cint, Cint, Cint, Cdouble),
       cell, positions, indices, length(indices), Cint(to_primitive), Cint(no_idealize), symprec)

    return num_atoms, cell, positions, indices
end

function spglib_standardize_cell(lattice::MatT, atoms; correct_symmetry=true,
                                 primitive=false, tol_symmetry=1e-5) where {MatT}
    T = eltype(lattice)

    # Convert lattice and atoms to spglib and keep the mapping between our atoms
    # and spglibs atoms
    cell, atommapping = spglib_cell_atommapping_(lattice, atoms)

    # Ask spglib to standardize the cell (i.e. find a cell, which fits the spglib conventions)
    num_atoms, spg_lattice, spg_scaled_positions, spg_numbers =
        spglib_standardize_cell_(spglib_cell(lattice, atoms), primitive, !correct_symmetry, tol_symmetry)

    # Note: In the python interface of spglib the lattice vectors
    #       are given in rows, but DFTK uses columns
    #       For future reference: The C interface spglib also uses columns.
    newatoms = [(atommapping[iatom]
                 => T.(spg_scaled_positions[findall(isequal(iatom), spg_numbers), :]))
                for iatom in unique(spg_numbers)]
    spg_lattice, newatoms
end

function spglib_get_stabilized_reciprocal_mesh(kgrid_size, rotations::AbstractArray{Int32};
                                               is_shift = Vec3(0, 0, 0),
                                               is_time_reversal = false,
                                               qpoints = [Vec3(0.0, 0.0, 0.0)],
                                               isdense = false)
    nkpt = prod(kgrid_size)
    mapping = Vector{Cint}(undef, nkpt)
    grid_address = Matrix{Cint}(undef, 3, nkpt)
    qpoints = eltype(qpoints) == Real ? [qpoints] : qpoints #Note: Done similarly to the python spglib
    # numrot = rotations isa Vector ? length(rotations) : size(rotations, 3)
    numrot = size(rotations, 3)
    num_kpts = ccall((:spg_get_stabilized_reciprocal_mesh, SPGLIB), Cint,
      (Ptr{Cint}, Ptr{Cint}, Ptr{Cint}, Ptr{Cint}, Cint, Cint, Ptr{Cint}, Cint, Ptr{Cdouble}),
       grid_address, mapping, [Cint.(kgrid_size)...], [Cint.(is_shift)...], Cint(is_time_reversal), Cint(numrot), rotations, Cint(length(qpoints)), qpoints)
    return num_kpts, mapping, grid_address
end
