# Functions returning appropriate builders for the external potential

"""
    build_local_potential(pw::PlaneWaveModel, generators_or_composition...;
                          compensating_background=true)

Function generating a local potential on the real-space density grid ``B^∗_ρ``
defined by the plane-wave basis `pw`. The potential is generated by summing
(in Fourier space) analytic contributions from all species involved in the
lattice, followed by an iFFT. The lattice definition is taken implicitly from `pw`.

The contributions are defined by the `generators_or_composition` pairs. In the simplest case
these are pairs from `Species` objects to lists of fractional coordinates defining the
real-space positions of the species. More generally any function `G -> potential(G)`, which
evaluates a local potential at this reciprocal space position may be used. In this
case `G` is passed in integer coordinates.  
The parameter `compensating_background` (default true) determines whether the DC component
will be automatically set to zero, which physically corresponds to including
a compensating change background in the potential model.

# Examples
Given an appropriate lattice and basis definition in `basis` one may build
the local potential for an all-electron treatment of sodium chloride as such
```julia-repl
julia> na = Species(11); cl = Species(17)
       build_local_potential(basis, na => [[0,0,0], [1/2,1/2,0], [1/2,0,1/2], [0,1/2,1/2]],
                             cl => [[0,1/2,0], [1/2,0,0], [0,0,1/2], [1/2,1/2,1/2]])
```
Equivalently one could have explicitly specified the Coulomb potential function to
be used, e.g.
```julia-repl
julia> na_Coulomb(G) = -11 / sum(abs2, basis.recip_lattice * G)
       cl = Species(17)
       build_local_potential(basis,
                             na_Coulomb => [[0,0,0], [1/2,1/2,0], [1/2,0,1/2], [0,1/2,1/2]],
                             cl => [[0,1/2,0], [1/2,0,0], [0,0,1/2], [1/2,1/2,1/2]])
```
since sodium has nuclear charge 11.
```
"""
function term_external(generators_or_composition...; compensating_background=true)
    function inner(basis::PlaneWaveModel{T}, energy, potential; kwargs...) where T
        model = basis.model

        make_generator(elem::Function) = elem
        function make_generator(elem::Species)
            if elem.psp === nothing
                # All-electron => Use default Coulomb potential
                return G -> -charge_nuclear(elem) / sum(abs2, model.recip_lattice * G)
            else
                # Use local part of pseudopotential defined in Species object
                return G -> eval_psp_local_fourier(elem.psp, model.recip_lattice * G)
            end
        end
        genfunctions = [make_generator(elem) => positions
                        for (elem, positions) in generators_or_composition]

        @assert energy === nothing "Energy computation not yet implemented"
        @assert potential !== nothing "Potential currently needed"

        # Get the values in the plane-wave basis set (Fourier space)
        values_fourier = map(basis_Cρ(basis)) do G
            sum(
                4π / model.unit_cell_volume  # Prefactor spherical Hankel transform
                * genfunction(G)          # Potential data for wave vector G
                * cis(2π * dot(G, r))     # Structure factor
                for (genfunction, positions) in genfunctions
                for r in positions
            )
        end
        if compensating_background
            values_fourier[1] = 0
        end
        potential .= G_to_r(basis, values_fourier)  # iFFT to real space

        energy, potential
    end
    return inner
end
