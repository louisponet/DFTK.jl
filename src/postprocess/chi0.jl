using LinearMaps
using IterativeSolvers
using ForwardDiff
using ProgressMeter

"""
Compute the independent-particle susceptibility. Will blow up for large systems.
Drop all non-diagonal terms with (f(εn)-f(εm))/(εn-εm) factor less than `droptol`.
"""
function compute_χ0(ham; droptol=0, temperature=ham.basis.model.temperature)
    # We're after χ0(r,r') such that δρ = ∫ χ0(r,r') δV(r') dr'
    # where (up to normalizations)
    # ρ = ∑_nk f(εnk - εF) |ψnk|^2
    # ∑_nk f(εnk - εF) = N_el
    # Everything is summed on k so we omit it for notational simplicity

    # We differentiate wrt a variation δV of the external potential
    # δρ = ∑_n (f'n δεn |ψn|^2 + 2Re fn ψn* δψn - f'n δεF |ψn|^2
    # with fn = f(εnk - εF), f'n = f'(εnk - εF)
    # δN_el = 0 = ∑_n f'n (δεn - δεF)

    # Now we use from first order perturbation theory
    # δεn = <ψn|δV|ψn>
    # δψn = ∑_{m != n} <ψm|δV|ψn> |ψm> / (εn-εm)

    # for δεF we get, with DOS = -∑_n f'n and LDOS = -∑_n f'n |ψn|^2
    # δεF = 1/DOS ∫ δV(r) LDOS(r)dr

    # for δρ we note ρnm = ψn* ψm, and we get
    # δρ = LDOS δεF + ∑_n f'n <ρn|δV> ρn + ∑_{n,m != n} 2Re fn ρnm <ρmn|δV> / (εn-εm)
    # δρ = LDOS δεF + ∑_n f'n <ρn|δV> ρn + ∑_{n,m != n} (fn-fm)/(εn-εm) ρnm <ρnm|δV>
    # The last two terms merge with the convention that (f(x)-f(x))/(x-x) = f'(x) into
    # δρ = LDOS δεF + ∑_{n,m} (fn-fm) ρnm <ρmn|δV> / (εn-εm)
    # Therefore the kernel is LDOS(r) LDOS(r') / DOS + ∑_{n,m} (fn-fm)/(εn-εm) ρnm(r) ρmn(r')
    basis = ham.basis
    model = basis.model
    fft_size = basis.fft_size
    @assert model.spin_polarization in (:none, :spinless)
    filled_occ = filled_occupation(model)
    dVol = basis.model.unit_cell_volume / prod(basis.fft_size)

    length(model.symops) == 1 || error("Disable symmetries completely for computing χ0")

    EVs = [eigen(Hermitian(Array(Hk))) for Hk in ham.blocks]
    Es = [EV.values for EV in EVs]
    Vs = [EV.vectors for EV in EVs]
    occ, εF = find_occupation(basis, Es, temperature=temperature)

    χ0 = zeros(eltype(basis), prod(fft_size), prod(fft_size))
    for ik = 1:length(basis.kpoints)
        N = length(G_vectors(basis.kpoints[ik]))
        @assert N < 10_000
        E = Es[ik]
        V = Vs[ik]
        Vr = cat(G_to_r.(Ref(basis), Ref(basis.kpoints[ik]), eachcol(V))..., dims=4)
        Vr = reshape(Vr, prod(fft_size), N)
        @showprogress "Computing χ0 for kpoint $ik/$(length(basis.kpoints)) ..." for m = 1:N, n = 1:N
            enred = (E[n] - εF) / temperature
            @assert occ[ik][n] ≈ filled_occ * Smearing.occupation(model.smearing, enred)
            ddiff = Smearing.occupation_divided_difference
            ratio = filled_occ * ddiff(model.smearing, E[m], E[n], εF, temperature)
            (n != m) && (abs(ratio) < droptol) && continue
            # dVol because inner products have a dVol so that |f> becomes <dVol f|
            # can take the real part here because the nm term is complex conjugate of mn
            # TODO optimize this a bit... use symmetry nm, reduce allocs, etc.
            factor = basis.kweights[ik] * ratio * dVol
            @views χ0 .+= factor .* real(conj((Vr[:, m] .* Vr[:, m]'))
                                            .*   (Vr[:, n] .* Vr[:, n]'))
        end
    end

    # Add variation wrt εF
    if temperature > 0
        ldos = vec(LDOS(εF, basis, Es, Vs))
        dos = DOS(εF, basis, Es)
        χ0 .+= (ldos .* ldos') .* dVol ./ dos
    end

    χ0
end


# make ldiv! act as a given function
struct FunctionPreconditioner
    fun!  # f!(y, x) applies f to x and puts it into y
end
LinearAlgebra.ldiv!(y, P::FunctionPreconditioner, x) = P.fun!(y, x)
LinearAlgebra.ldiv!(P::FunctionPreconditioner, x) = (x .= P.fun!(similar(x), x))

# Solves Q (H-εn) Q δψn = -Q rhs
# where Q is the projector on the orthogonal of ψk
function sternheimer_solver(basis, kpoint, Hk, ψk, ψnk, εnk, rhs, cgtol)
    # we err on the side of caution here by applying Q *a lot*
    # there are optimizations to be made here
    Q(ϕ) = ϕ - ψk * (ψk' * ϕ)
    function QHQ(ϕ)
        Qϕ = Q(ϕ)
        Q(Hk * Qϕ - εnk * Qϕ)
    end
    precon = PreconditionerTPA(basis, kpoint)
    precondprep!(precon, ψnk)
    function f_ldiv!(x, y)
        x .= Q(precon \ Q(y))
    end
    J = LinearMap{eltype(ψk)}(QHQ, size(Hk, 1))
    # cgtol should not be too tight, and in particular not be
    # too far below the error in the ψ. Otherwise Q and H
    # don't commute enough, and an oversolving of the linear
    # system can lead to spurious solutions
    rhs = Q(rhs)
    δψnk = cg(J, rhs, Pl=FunctionPreconditioner(f_ldiv!), tol=cgtol / norm(rhs), verbose=false)
    δψnk
end

"""
Returns the change in density δρ for a given δV. Drop all non-diagonal terms with
(f(εn)-f(εm))/(εn-εm) factor less than `droptol`. If `sternheimer_contribution`
is false, only compute excitations inside the provided orbitals.
"""
function apply_χ0(ham, δV, ψ, εF, eigenvalues;
                  droptol=0,
                  sternheimer_contribution=true,
                  temperature=ham.basis.model.temperature,
                  cgtol=1e-6)
    basis = ham.basis
    T = eltype(basis)
    model = basis.model
    fft_size = basis.fft_size
    @assert model.spin_polarization in (:none, :spinless)
    filled_occ = filled_occupation(model)
    dVol = basis.model.unit_cell_volume / prod(basis.fft_size)

    # Normalize δV to avoid numerical trouble; theoretically should
    # not be necessary, but it simplifies the interaction with the
    # Sternheimer linear solver (it makes the rhs be order 1 even if
    # δV is small)
    normδV = norm(δV)
    normδV < eps(T) && return zero(δV)
    δV /= normδV

    # Make δV respect the full model symmetry group, since it's
    # invalid to consider perturbations that don't (technically it
    # could be made to only respect basis.symops, but symmetrizing wrt
    # the model symmetry group means that χ0 is unaffected by the
    # use_symmetry kwarg of basis, which is nice)
    δV = symmetrize(from_real(basis, δV)).real

    if droptol > 0 && sternheimer_contribution == true
        error("Droptol cannot be positive if sternheimer contribution is to be computed.")
    end

    # δρ = ∑_nk (f'n δεn |ψn|^2 + 2Re fn ψn* δψn - f'n δεF |ψn|^2
    δρ_fourier = zeros(complex(T), size(δV))
    for ik = 1:length(basis.kpoints)
        δρk = zero(δV)
        for n = 1:size(ψ[ik], 2)
            ψnk = @view ψ[ik][:, n]
            ψnk_real = G_to_r(basis, basis.kpoints[ik], ψnk)
            εnk = eigenvalues[ik][n]

            # 2Re fn ψn* δψn
            # we split δψn into its component on the computed and uncomputed states:
            # δψn = P ψn + Q ψn
            # we compute Pψn explicitly by sum over states, and
            # Q δψn by solving the Sternheimer equation
            # (H-εn) Q δψn = -Q δV ψn
            # where Q = sum_n |ψn><ψn|

            # explicit contributions
            for m = 1:size(ψ[ik], 2)
                εmk = eigenvalues[ik][m]
                ddiff = Smearing.occupation_divided_difference
                ratio = filled_occ * ddiff(model.smearing, εmk, εnk, εF, temperature)
                (n != m) && (abs(ratio) < droptol) && continue
                ψmk = @view ψ[ik][:, m]
                ψmk_real = G_to_r(basis, basis.kpoints[ik], ψmk)
                # ∑_{n,m != n} (fn-fm)/(εn-εm) ρnm <ρmn|δV>
                ρnm = conj(ψnk_real) .* ψmk_real
                weight = dVol*dot(ρnm, δV)
                δρk .+= real(ratio .* weight .* ρnm)
            end

            if sternheimer_contribution
                # Compute the contributions from uncalculated bands
                fnk = filled_occ * Smearing.occupation(model.smearing, (εnk-εF) / temperature)
                abs(fnk) < eps(T) && continue
                rhs = r_to_G(basis, basis.kpoints[ik], .- δV .* ψnk_real)
                norm(rhs) < 100eps(T) && continue
                δψnk = sternheimer_solver(basis, basis.kpoints[ik], ham.blocks[ik], ψ[ik], ψnk, εnk, rhs, cgtol)
                δψnk_real = G_to_r(basis, basis.kpoints[ik], δψnk)
                δρk .+= 2 .* fnk .* real(conj(ψnk_real) .* δψnk_real)
            end
        end
        accumulate_over_symops!(δρ_fourier, r_to_G(basis, complex(δρk)), basis, basis.ksymops[ik], G_vectors(basis))
    end
    δρ = real(G_to_r(basis, δρ_fourier))
    count = sum(length(basis.ksymops[ik]) for ik in 1:length(basis.kpoints))
    δρ ./= count

    # Add variation wrt εF
    if temperature > 0
        ldos = LDOS(εF, basis, eigenvalues, ψ, temperature=temperature)
        dos = DOS(εF, basis, eigenvalues, temperature=temperature)
        δρ .+= ldos .* dot(ldos, δV) .* dVol ./ dos
    end

    δρ .* normδV
end
