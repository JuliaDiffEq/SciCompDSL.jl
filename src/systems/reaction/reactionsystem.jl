
"""
$(TYPEDEF)

One chemical reaction.

# Fields
$(FIELDS)

# Examples

```julia
using ModelingToolkit
@parameters t k[1:20]
@variables A(t) B(t) C(t) D(t)
rxs = [Reaction(k[1], nothing, [A]),            # 0 -> A
       Reaction(k[2], [B], nothing),            # B -> 0
       Reaction(k[3],[A],[C]),                  # A -> C
       Reaction(k[4], [C], [A,B]),              # C -> A + B
       Reaction(k[5], [C], [A], [1], [2]),      # C -> A + A
       Reaction(k[6], [A,B], [C]),              # A + B -> C
       Reaction(k[7], [B], [A], [2], [1]),      # 2B -> A
       Reaction(k[8], [A,B], [A,C]),            # A + B -> A + C
       Reaction(k[9], [A,B], [C,D]),            # A + B -> C + D
       Reaction(k[10], [A], [C,D], [2], [1,1]), # 2A -> C + D
       Reaction(k[11], [A], [A,B], [2], [1,1]), # 2A -> A + B
       Reaction(k[12], [A,B,C], [C,D], [1,3,4], [2, 3]),          # A+3B+4C -> 2C + 3D
       Reaction(k[13], [A,B], nothing, [3,1], nothing),           # 3A+B -> 0
       Reaction(k[14], nothing, [A], nothing, [2]),               # 0 -> 2A
       Reaction(k[15]*A/(2+A), [A], nothing; only_use_rate=true), # A -> 0 with custom rate
       Reaction(k[16], [A], [B]; only_use_rate=true),             # A -> B with custom rate.
       Reaction(k[17]*A*exp(B), [C], [D], [2], [1]),              # 2C -> D with non constant rate.
       Reaction(k[18]*B, nothing, [B], nothing, [2]),             # 0 -> 2B with non constant rate.
       Reaction(k[19]*t, [A], [B]),                                # A -> B with non constant rate.
       Reaction(k[20]*t*A, [B,C], [D],[2,1],[2])                  # 2A +B -> 2C with non constant rate.
  ]
```

Notes:
- `nothing` can be used to indicate a reaction that has no reactants or no products.
  In this case the corresponding stoichiometry vector should also be set to `nothing`.
- The three-argument form assumes all reactant and product stoichiometric coefficients
  are one.
"""

# Support for bursty reactions

using Distributions, Statistics
const ReactantDistribution = DiscreteUnivariateDistribution

struct VarStoich
    offs::Int
    dist::ReactantDistribution
end

VarStoich(dist::ReactantDistribution) = VarStoich(0, dist)

Base.:(+)(vs::VarStoich, x::Int) = VarStoich(vs.offs + x, vs.dist)
Base.:(+)(x::Int, vs::VarStoich) = vs + x
Base.:(-)(vs::VarStoich, x::Int) = vs + (-x)

function Base.:(*)(coeff::Int, vs::VarStoich) 
    coeff == 1 && VarStoich(vs.offs, vs.dist)
    throw("Cannot multiply distributions")
end 

Statistics.mean(vs::VarStoich) = vs.offs + mean(vs.dist)
Statistics.var(vs::VarStoich) = var(vs.dist)

sample_bernoulli(p) = rand(Bernoulli(p))
sample_betabinomial(n,α,β) = rand(BetaBinomial(n,α,β))
sample_binomial(n,p) = rand(Binomial(n,p))
sample_geom(p) = rand(Geometric(p))
sample_discunif(a,b) = rand(DiscreteUniform(a,b))
sample_negbinomial(r,p) = rand(NegativeBinomial(r,p))
sample_poisson(λ) = rand(Poisson(λ))

@register sample_bernoulli(p)
@register sample_betabinomial(n,α,β)
@register sample_binomial(n,p)
@register sample_geom(p)
@register sample_discunif(a,b)
@register sample_negbinomial(r,p)
@register sample_poisson(λ)

convert_distribution(bern::Bernoulli) = sample_bernoulli(bern.p)
convert_distribution(betabin::BetaBinomial) = sample_betabinomial(bin.n, bin.α, bin.β)
convert_distribution(bin::Binomial) = sample_binomial(bin.n, bin.p)
convert_distribution(geom::Geometric) = sample_geom(geom.p)
convert_distribution(unif::DiscreteUniform) = sample_discunif(unif.a, unif.b)
convert_distribution(negbin::NegativeBinomial) = sample_negbinomial(negbin.p, negbin.r)
convert_distribution(pois::Poisson) = sample_poisson(pois.λ)

#

struct Reaction{S}
    """The rate function (excluding mass action terms)."""
    rate
    """Reaction substrates."""
    substrates::Vector
    """Reaction products."""
    products::Vector
    """The stoichiometric coefficients of the reactants."""
    substoich::Vector{Int}
    """The stoichiometric coefficients of the products."""
    prodstoich::Vector{Union{Int,VarStoich}}
    """The net stoichiometric coefficients of all species changed by the reaction."""
    netstoich::Vector{Pair{S, Union{Int, VarStoich}}}
    """
    `false` (default) if `rate` should be multiplied by mass action terms to give the rate law.
    `true` if `rate` represents the full reaction rate law.
    """
    only_use_rate::Bool
end

function convert_prodstoich(prodstoich)
    ret = Vector{Union{Int,VarStoich}}(undef, length(prodstoich))
    for (i, ps) in enumerate(prodstoich)
        if ps isa Distribution
            ret[i] = VarStoich(ps)
        else
            ret[i] = ps
        end
    end
    ret
end

function Reaction(rate, subs, prods, substoich, prodstoich;
                  netstoich=nothing, only_use_rate=false, kwargs...)

    (isnothing(prods)&&isnothing(subs)) && error("A reaction requires a non-nothing substrate or product vector.")
    (isnothing(prodstoich)&&isnothing(substoich)) && error("Both substrate and product stochiometry inputs cannot be nothing.")
    if isnothing(subs)
        subs = Vector{Term}()
        !isnothing(substoich) && error("If substrates are nothing, substrate stoichiometries have to be so too.")
        substoich = Vector{Int}()
    end
    if isnothing(prods)
        prods = Vector{Term}()
        !isnothing(prodstoich) && error("If products are nothing, product stoichiometries have to be so too.")
        prodstoich = Vector{Union{Int,VarStoich}}()
    else
        prodstoich = convert_prodstoich(prodstoich)
    end
    subs = value.(subs)
    prods = value.(prods)
    ns = isnothing(netstoich) ? get_netstoich(subs, prods, substoich, prodstoich) : netstoich
    Reaction(value(rate), subs, prods, substoich, prodstoich, ns, only_use_rate)
end


# three argument constructor assumes stoichiometric coefs are one and integers
function Reaction(rate, subs, prods; kwargs...)
    sstoich = isnothing(subs) ? nothing : ones(Int,length(subs))
    pstoich = isnothing(prods) ? nothing : ones(Int,length(prods))
    Reaction(rate, subs, prods, sstoich, pstoich; kwargs...)
end

function namespace_equation(rx::Reaction, name, iv)
    Reaction(namespace_expr(rx.rate, name, iv), 
             namespace_expr(rx.substrates, name, iv),
             namespace_expr(rx.products, name, iv),
             rx.substoich, rx.prodstoich,            
             [namespace_expr(n[1],name,iv) => n[2] for n in rx.netstoich], rx.only_use_rate)
end

# calculates the net stoichiometry of a reaction as a vector of pairs (sub,substoich)
function get_netstoich(subs, prods, sstoich, pstoich)
    # stoichiometry as a Dictionary
    nsdict = Dict{Any, Union{Int,VarStoich}}(sub => -sstoich[i] for (i,sub) in enumerate(subs))
    for (i,p) in enumerate(prods)
        coef = pstoich[i]
        @inbounds nsdict[p] = haskey(nsdict, p) ? nsdict[p] + coef : coef
    end

    # stoichiometry as a vector
    ns = [el for el in nsdict if el[2] != 0 ]

    ns
end

"""
$(TYPEDEF)

A system of chemical reactions.

# Fields
$(FIELDS)

# Example
Continuing from the example in the [`Reaction`](@ref) definition:
```julia
rs = ReactionSystem(rxs, t, [A,B,C,D], k)
```
"""
struct ReactionSystem <: AbstractSystem
    """The reactions defining the system."""
    eqs::Vector{Reaction}
    """Independent variable (usually time)."""
    iv::Any
    """Dependent (state) variables representing amount of each species."""
    states::Vector
    """Parameter variables."""
    ps::Vector
    observed::Vector{Equation}
    """The name of the system"""
    name::Symbol
    """systems: The internal systems"""
    systems::Vector

    function ReactionSystem(eqs, iv, states, ps, observed, name, systems)
        new(eqs, value(iv), value.(states), value.(ps), observed, name, systems)
    end
end

function ReactionSystem(eqs, iv, species, params;
                        observed = [],
                        systems = [],
                        name = gensym(:ReactionSystem))

    #isempty(species) && error("ReactionSystems require at least one species.")
    ReactionSystem(eqs, iv, species, params, observed, name, systems)
end

function ReactionSystem(iv; kwargs...)
    ReactionSystem(Reaction[], iv, [], []; kwargs...)
end


function equations(sys::ModelingToolkit.ReactionSystem)
    eqs = get_eqs(sys)
    systems = get_systems(sys)
    if isempty(systems)
        return eqs
    else
        eqs = [eqs;
               reduce(vcat,
                      namespace_equations.(get_systems(sys));
                      init=[])]
        return eqs
    end
end

isbursty(reac::Reaction) = any(stoich -> stoich isa VarStoich, reac.prodstoich)

get_bursty_eqs(sys::ReactionSystem) = filter(reac -> isbursty(reac), get_eqs(sys))
get_bursts(rx::Reaction) = ( (rx, spec, stoich) for (spec, stoich) in zip(rx.products, rx.prodstoich) if stoich isa VarStoich )
get_bursts(sys::ReactionSystem) = Base.Iterators.flatten((get_bursts(rx) for rx in get_bursty_eqs(sys)))

"""
    oderatelaw(rx; combinatoric_ratelaw=true)

Given a [`Reaction`](@ref), return the reaction rate law [`Operation`](@ref) used in
generated ODEs for the reaction. Note, for a reaction defined by

`k*X*Y, X+Z --> 2X + Y`

the expression that is returned will be `k*X(t)^2*Y(t)*Z(t)`. For a reaction
of the form

`k, 2X+3Y --> Z`

the `Operation` that is returned will be `k * (X(t)^2/2) * (Y(t)^3/6)`.

Notes:
- Allocates
- `combinatoric_ratelaw=true` uses factorial scaling factors in calculating the rate
    law, i.e. for `2S -> 0` at rate `k` the ratelaw would be `k*S^2/2!`. If
    `combinatoric_ratelaw=false` then the ratelaw is `k*S^2`, i.e. the scaling factor is
    ignored.
"""
function oderatelaw(rx; combinatoric_ratelaw=true)
    @unpack rate, substrates, substoich, only_use_rate = rx
    rl = rate
    if !only_use_rate
        coef = one(eltype(substoich))
        for (i,stoich) in enumerate(substoich)
            coef *= factorial(stoich)
            rl   *= isone(stoich) ? substrates[i] : substrates[i]^stoich
        end
        combinatoric_ratelaw && (!isone(coef)) && (rl /= coef)
    end
    rl
end

function assemble_oderhs(rs; combinatoric_ratelaws=true)
    sts = get_states(rs)
    species_to_idx = Dict((x => i for (i,x) in enumerate(sts)))
    rhsvec         = Any[0 for i in eachindex(sts)]

    for rx in get_eqs(rs)
        rl = oderatelaw(rx; combinatoric_ratelaw=combinatoric_ratelaws)
        for (spec,stoich) in rx.netstoich
            i = species_to_idx[spec]
            if stoich isa VarStoich            
                rhsvec[i] = mean(stoich) * rl + rhsvec[i]
            elseif _iszero(rhsvec[i])
                signedrl  = (stoich > zero(stoich)) ? rl : -rl
                rhsvec[i] = isone(abs(stoich)) ? signedrl : stoich * rl
            else
                Δspec     = isone(abs(stoich)) ? rl : abs(stoich) * rl
                rhsvec[i] = (stoich > zero(stoich)) ? (rhsvec[i] + Δspec) : (rhsvec[i] - Δspec)
            end
        end
    end

    rhsvec
end

function assemble_drift(rs; combinatoric_ratelaws=true, as_odes=true)
    rhsvec = assemble_oderhs(rs; combinatoric_ratelaws=combinatoric_ratelaws)
    if as_odes
        D   = Differential(get_iv(rs))
        eqs = [Equation(D(x),rhs) for (x,rhs) in zip(get_states(rs),rhsvec) if (!_iszero(rhs))]
    else
        eqs = [Equation(0,rhs) for rhs in rhsvec if (!_iszero(rhs))]
    end
    eqs
end

function assemble_diffusion(rs, noise_scaling; combinatoric_ratelaws=true)
    sts  = get_states(rs)
    n_bursts = count(f -> f !== nothing, get_bursts(rs))
    eqs  = Matrix{Any}(undef, length(sts), length(get_eqs(rs)) + n_bursts)
    eqs .= 0
    species_to_idx = Dict((x => i for (i,x) in enumerate(sts)))

    for (j,rx) in enumerate(equations(rs))
        rlsqrt = sqrt(abs(oderatelaw(rx; combinatoric_ratelaw=combinatoric_ratelaws)))
        (noise_scaling!==nothing) && (rlsqrt *= noise_scaling[j])
        for (spec,stoich) in rx.netstoich
            i = species_to_idx[spec]
            if stoich isa VarStoich            
                eqs[i,j] = mean(stoich) * rlsqrt
            else
                signedrlsqrt = (stoich > zero(stoich)) ? rlsqrt : -rlsqrt
                eqs[i,j]     = isone(abs(stoich)) ? signedrlsqrt : stoich * rlsqrt
            end
        end
    end

    # Add additional noise due to bursts
    for (j, (rx, spec, stoich)) in enumerate(get_bursts(rs))
        varstoich = var(stoich)

        j_reac = findfirst(x -> x == rx, equations(rs))
        rlsqrt = sqrt(abs(oderatelaw(rx; combinatoric_ratelaw=combinatoric_ratelaws)))
        (noise_scaling!==nothing) && (rlsqrt *= noise_scaling[j_reac])
        i = species_to_idx[spec]
        eqs[i,length(get_eqs(rs))+j] = sqrt(varstoich) * rlsqrt
    end

    eqs
end

"""
    jumpratelaw(rx; rxvars=get_variables(rx.rate), combinatoric_ratelaw=true)

Given a [`Reaction`](@ref), return the reaction rate law [`Operation`](@ref) used in
generated stochastic chemical kinetics model SSAs for the reaction. Note,
for a reaction defined by

`k*X*Y, X+Z --> 2X + Y`

the expression that is returned will be `k*X^2*Y*Z`. For a reaction of
the form

`k, 2X+3Y --> Z`

the `Operation` that is returned will be `k * binomial(X,2) *
binomial(Y,3)`.

Notes:
- `rxvars` should give the `Variable`s, i.e. species and parameters, the rate depends on.
- Allocates
- `combinatoric_ratelaw=true` uses binomials in calculating the rate law, i.e. for `2S ->
  0` at rate `k` the ratelaw would be `k*S*(S-1)/2`. If `combinatoric_ratelaw=false` then
  the ratelaw is `k*S*(S-1)`, i.e. the rate law is not normalized by the scaling
  factor.
"""
function jumpratelaw(rx; rxvars=get_variables(rx.rate), combinatoric_ratelaw=true)
    @unpack rate, substrates, substoich, only_use_rate = rx
    rl = rate
    if !only_use_rate
        coef = one(eltype(substoich))
        for (i,stoich) in enumerate(substoich)
            s   = substrates[i]
            rl *= s
            isone(stoich) && continue
            for i in one(stoich):(stoich-one(stoich))
                rl *= (s - i)
            end
            combinatoric_ratelaw && (coef *= factorial(stoich))
        end
        !isone(coef) && (rl /= coef)
    end
    rl
end

# if haveivdep=false then time dependent rates will still be classified as mass action
"""
```julia
ismassaction(rx, rs; rxvars = get_variables(rx.rate),
                              haveivdep = any(var -> isequal(get_iv(rs),var), rxvars),
                              stateset = Set(states(rs)))
```

True if a given reaction is of mass action form, i.e. `rx.rate` does not depend
on any chemical species that correspond to states of the system, and does not depend
explicitly on the independent variable (usually time).

# Arguments
- `rx`, the [`Reaction`](@ref).
- `rs`, a [`ReactionSystem`](@ref) containing the reaction.
- Optional: `rxvars`, `Variable`s which are not in `rxvars` are ignored as possible dependencies.
- Optional: `haveivdep`, `true` if the [`Reaction`](@ref) `rate` field explicitly depends on the independent variable.
- Optional: `stateset`, set of states which if the rxvars are within mean rx is non-mass action.
"""
function ismassaction(rx, rs; rxvars = get_variables(rx.rate),
                              haveivdep = any(var -> isequal(get_iv(rs),var), rxvars),
                              stateset = Set(get_states(rs)))
    # if no dependencies must be zero order
    (length(rxvars)==0) && return true
    haveivdep && return false
    rx.only_use_rate && return false
    isbursty(rx) && return false      # bursty reactions aren't MA for technical reasons
    @inbounds for i = 1:length(rxvars)
        (rxvars[i] in stateset) && return false
    end
    return true
end

function get_affect(rx::Reaction)
    affect = Vector{Equation}()
    for (spec,stoich) in rx.netstoich
        if stoich isa VarStoich
            push!(affect, spec ~ spec + stoich.offs + convert_distribution(stoich.dist))
        else
            push!(affect, spec ~ spec + stoich)
        end
    end
    affect
end

@inline function makemajump(rx; combinatoric_ratelaw=true)
    @unpack rate, substrates, substoich, netstoich = rx
    zeroorder = (length(substoich) == 0)
    reactant_stoch = Vector{Pair{Any,eltype(substoich)}}(undef, length(substoich))
    @inbounds for i = 1:length(reactant_stoch)
        reactant_stoch[i] = substrates[i] => substoich[i]
    end
    #push!(rstoich, reactant_stoch)
    coef = (zeroorder || (!combinatoric_ratelaw)) ? one(eltype(substoich)) : prod(stoich -> factorial(stoich), substoich)
    (!isone(coef)) && (rate /= coef)
    #push!(rates, rate)
    net_stoch      = [Pair(p[1],p[2]) for p in netstoich]
    @assert all(p[2] isa Int for p in net_stoch)      # bursty reactions aren't MA for technical reasons
    #push!(nstoich, net_stoch)
    MassActionJump(Num(rate), reactant_stoch, net_stoch, scale_rates=false, useiszero=false)
end

function assemble_jumps(rs; combinatoric_ratelaws=true)
    meqs = MassActionJump[]; ceqs = ConstantRateJump[]; veqs = VariableRateJump[]
    stateset = Set(get_states(rs))
    #rates = [];  rstoich = []; nstoich = []
    rxvars = []
    ivname = nameof(get_iv(rs))

    isempty(equations(rs)) && error("Must give at least one reaction before constructing a JumpSystem.")
    for rx in equations(rs)
        empty!(rxvars)
        (rx.rate isa Symbolic) && get_variables!(rxvars, rx.rate)
        haveivdep = false
        @inbounds for i = 1:length(rxvars)
            if isequal(rxvars[i], get_iv(rs))
                haveivdep = true
                break
            end
        end
        if ismassaction(rx, rs; rxvars=rxvars, haveivdep=haveivdep, stateset=stateset)
            push!(meqs, makemajump(rx, combinatoric_ratelaw=combinatoric_ratelaws))
        else
            rl     = jumpratelaw(rx, rxvars=rxvars, combinatoric_ratelaw=combinatoric_ratelaws)
            affect = get_affect(rx)
            if haveivdep
                push!(veqs, VariableRateJump(rl,affect))
            else
                push!(ceqs, ConstantRateJump(rl,affect))
            end
        end
    end
    #eqs[1] = MassActionJump(rates, rstoich, nstoich, scale_rates=false, useiszero=false)
    ArrayPartition(meqs,ceqs,veqs)
end

"""
```julia
Base.convert(::Type{<:ODESystem},rs::ReactionSystem)
```
Convert a [`ReactionSystem`](@ref) to an [`ODESystem`](@ref).

Notes:
- `combinatoric_ratelaws=true` uses factorial scaling factors in calculating the rate
law, i.e. for `2S -> 0` at rate `k` the ratelaw would be `k*S^2/2!`. If
`combinatoric_ratelaws=false` then the ratelaw is `k*S^2`, i.e. the scaling factor is
ignored.
"""
function Base.convert(::Type{<:ODESystem}, rs::ReactionSystem; 
                      name=nameof(rs), combinatoric_ratelaws=true, kwargs...)
    eqs     = assemble_drift(rs; combinatoric_ratelaws=combinatoric_ratelaws)
    systems = map(sys -> (sys isa ODESystem) ? sys : convert(ODESystem, sys), get_systems(rs))
    ODESystem(eqs, get_iv(rs), get_states(rs), get_ps(rs), name=name, systems=systems)
end

"""
```julia
Base.convert(::Type{<:NonlinearSystem},rs::ReactionSystem)
```

Convert a [`ReactionSystem`](@ref) to an [`NonlinearSystem`](@ref).

Notes:
- `combinatoric_ratelaws=true` uses factorial scaling factors in calculating the rate
law, i.e. for `2S -> 0` at rate `k` the ratelaw would be `k*S^2/2!`. If
`combinatoric_ratelaws=false` then the ratelaw is `k*S^2`, i.e. the scaling factor is
ignored.
"""
function Base.convert(::Type{<:NonlinearSystem},rs::ReactionSystem;
                      name=nameof(rs), combinatoric_ratelaws=true, kwargs...)
    eqs     = assemble_drift(rs; combinatoric_ratelaws=combinatoric_ratelaws, as_odes=false)
    systems = convert.(NonlinearSystem, get_systems(rs))
    NonlinearSystem(eqs, get_states(rs), get_ps(rs), name=name, systems=systems)
end

"""
```julia
Base.convert(::Type{<:SDESystem},rs::ReactionSystem)
```

Convert a [`ReactionSystem`](@ref) to an [`SDESystem`](@ref).

Notes:
- `combinatoric_ratelaws=true` uses factorial scaling factors in calculating the rate
law, i.e. for `2S -> 0` at rate `k` the ratelaw would be `k*S^2/2!`. If
`combinatoric_ratelaws=false` then the ratelaw is `k*S^2`, i.e. the scaling factor is
ignored.
- `noise_scaling=nothing::Union{Vector{Operation},Operation,Nothing}` allows for linear
scaling of the noise in the chemical Langevin equations. If `nothing` is given, the default
value as in Gillespie 2000 is used. Alternatively, an `Operation` can be given, this is
added as a parameter to the system (at the end of the parameter array). All noise terms
are linearly scaled with this value. The parameter may be one already declared in the `ReactionSystem`.
Finally, a `Vector{Operation}` can be provided (the length must be equal to the number of reactions).
Here the noise for each reaction is scaled by the corresponding parameter in the input vector.
This input may contain repeat parameters.
"""
function Base.convert(::Type{<:SDESystem}, rs::ReactionSystem; 
                      noise_scaling=nothing, name=nameof(rs), combinatoric_ratelaws=true, kwargs...)

    if noise_scaling isa Vector
        (length(noise_scaling)!=length(equations(rs))) &&
        error("The number of elements in 'noise_scaling' must be equal " *
              "to the number of reactions in the reaction system.")
        noise_scaling = value.(noise_scaling)
    elseif !isnothing(noise_scaling)
        noise_scaling = fill(value(noise_scaling),length(equations(rs)))
    end

    eqs      = assemble_drift(rs; combinatoric_ratelaws=combinatoric_ratelaws)
    noiseeqs = assemble_diffusion(rs,noise_scaling;
                                  combinatoric_ratelaws=combinatoric_ratelaws)
    systems  = convert.(SDESystem, get_systems(rs))
    SDESystem(eqs, noiseeqs, get_iv(rs), get_states(rs),
              (noise_scaling===nothing) ? get_ps(rs) : union(get_ps(rs), toparam.(noise_scaling)),
              name=name, 
              systems=systems)
end

"""
```julia
Base.convert(::Type{<:JumpSystem},rs::ReactionSystem; combinatoric_ratelaws=true)
```

Convert a [`ReactionSystem`](@ref) to an [`JumpSystem`](@ref).

Notes:
- `combinatoric_ratelaws=true` uses binomials in calculating the rate law, i.e. for `2S ->
  0` at rate `k` the ratelaw would be `k*S*(S-1)/2`. If `combinatoric_ratelaws=false` then
  the ratelaw is `k*S*(S-1)`, i.e. the rate law is not normalized by the scaling
  factor.
"""
function Base.convert(::Type{<:JumpSystem},rs::ReactionSystem; 
                      name=nameof(rs), combinatoric_ratelaws=true, kwargs...)
    eqs     = assemble_jumps(rs; combinatoric_ratelaws=combinatoric_ratelaws)
    systems = convert.(JumpSystem, get_systems(rs))
    JumpSystem(eqs, get_iv(rs), get_states(rs), get_ps(rs), name=name, systems=systems)
end


### Converts a reaction system to ODE or SDE problems ###


# ODEProblem from AbstractReactionNetwork
function DiffEqBase.ODEProblem(rs::ReactionSystem, u0, tspan, p=DiffEqBase.NullParameters(), args...; kwargs...)
    return ODEProblem(convert(ODESystem,rs; kwargs...),u0,tspan,p, args...; kwargs...)
end

# NonlinearProblem from AbstractReactionNetwork
function DiffEqBase.NonlinearProblem(rs::ReactionSystem, u0, p=DiffEqBase.NullParameters(), args...; kwargs...)
    return NonlinearProblem(convert(NonlinearSystem,rs; kwargs...), u0, p, args...; kwargs...)
end


# SDEProblem from AbstractReactionNetwork
function DiffEqBase.SDEProblem(rs::ReactionSystem, u0, tspan, p=DiffEqBase.NullParameters(), args...; noise_scaling=nothing, kwargs...)
    sde_sys  = convert(SDESystem,rs;noise_scaling=noise_scaling, kwargs...)
    p_matrix = zeros(length(get_states(rs)), length(get_eqs(rs)))
    return SDEProblem(sde_sys,u0,tspan,p,args...; noise_rate_prototype=p_matrix,kwargs...)
end

# DiscreteProblem from AbstractReactionNetwork
function DiffEqBase.DiscreteProblem(rs::ReactionSystem, u0, tspan::Tuple, p=DiffEqBase.NullParameters(), args...; kwargs...)
    return DiscreteProblem(convert(JumpSystem,rs; kwargs...), u0,tspan,p, args...; kwargs...)
end

# JumpProblem from AbstractReactionNetwork
function DiffEqJump.JumpProblem(rs::ReactionSystem, prob, aggregator, args...; kwargs...)
    return JumpProblem(convert(JumpSystem,rs; kwargs...), prob, aggregator, args...; kwargs...)
end

# SteadyStateProblem from AbstractReactionNetwork
function DiffEqBase.SteadyStateProblem(rs::ReactionSystem, u0, p=DiffEqBase.NullParameters(), args...; kwargs...)
    return SteadyStateProblem(ODEFunction(convert(ODESystem,rs; kwargs...)),u0,p, args...; kwargs...)
end

# determine which species a reaction depends on
function get_variables!(deps::Set, rx::Reaction, variables)
    (rx.rate isa Symbolic) && get_variables!(deps, rx.rate, variables)
    for s in rx.substrates
        push!(deps, s)
    end
    deps
end

# determine which species a reaction modifies
function modified_states!(mstates, rx::Reaction, sts::Set)
    for (species,stoich) in rx.netstoich
        (species in sts) && push!(mstates, species)
    end
end
