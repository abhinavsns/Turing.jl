struct TuringState{S,F}
    state::S
    logdensity::F
end

state_to_turing(f::DynamicPPL.LogDensityFunction, state) = TuringState(state, f)
function transition_to_turing(f::DynamicPPL.LogDensityFunction, transition)
    # TODO: We should probably rename this `getparams` since it returns something
    # very different from `Turing.Inference.getparams`.
    θ = getparams(f.model, transition)
    varinfo = DynamicPPL.unflatten(f.varinfo, θ)
    return Transition(f.model, varinfo, transition)
end

state_to_turing(f::LogDensityProblemsAD.ADGradientWrapper, state) = TuringState(state, f)
function transition_to_turing(f::LogDensityProblemsAD.ADGradientWrapper, transition)
    return transition_to_turing(parent(f), transition)
end

"""
    getmodel(f)

Return the `DynamicPPL.Model` wrapped in the given log-density function `f`.
"""
getmodel(f::LogDensityProblemsAD.ADGradientWrapper) = getmodel(parent(f))
getmodel(f::DynamicPPL.LogDensityFunction) = f.model

"""
    setmodel(f, model[, adtype])

Set the `DynamicPPL.Model` in the given log-density function `f` to `model`.

!!! warning
    Note that if `f` is a `LogDensityProblemsAD.ADGradientWrapper` wrapping a
    `DynamicPPL.LogDensityFunction`, performing an update of the `model` in `f`
    might require recompilation of the gradient tape, depending on the AD backend.
"""
function setmodel(
    f::LogDensityProblemsAD.ADGradientWrapper,
    model::DynamicPPL.Model,
    adtype::ADTypes.AbstractADType
)
    # TODO: Should we handle `SciMLBase.NoAD`?
    # For an `ADGradientWrapper` we do the following:
    # 1. Update the `Model` in the underlying `LogDensityFunction`.
    # 2. Re-construct the `ADGradientWrapper` using `ADgradient` using the provided `adtype`
    #    to ensure that the recompilation of gradient tapes, etc. also occur. For example,
    #    ReverseDiff.jl in compiled mode will cache the compiled tape, which means that just
    #    replacing the corresponding field with the new model won't be sufficient to obtain
    #    the correct gradients.
    return LogDensityProblemsAD.ADgradient(adtype, setmodel(parent(f), model))
end
function setmodel(f::DynamicPPL.LogDensityFunction, model::DynamicPPL.Model)
    return Accessors.@set f.model = model
end

function varinfo_from_logdensityfn(f::LogDensityProblemsAD.ADGradientWrapper)
    return varinfo_from_logdensityfn(parent(f))
end
varinfo_from_logdensityfn(f::DynamicPPL.LogDensityFunction) = f.varinfo

function varinfo(state::TuringState)
    θ = getparams(getmodel(state.logdensity), state.state)
    # TODO: Do we need to link here first?
    return DynamicPPL.unflatten(varinfo_from_logdensityfn(state.logdensity), θ)
end

# NOTE: Only thing that depends on the underlying sampler.
# Something similar should be part of AbstractMCMC at some point:
# https://github.com/TuringLang/AbstractMCMC.jl/pull/86
getparams(::DynamicPPL.Model, transition::AdvancedHMC.Transition) = transition.z.θ
function getparams(model::DynamicPPL.Model, state::AdvancedHMC.HMCState)
    return getparams(model, state.transition)
end
getstats(transition::AdvancedHMC.Transition) = transition.stat

getparams(::DynamicPPL.Model, transition::AdvancedMH.Transition) = transition.params

getvarinfo(f::DynamicPPL.LogDensityFunction) = f.varinfo
getvarinfo(f::LogDensityProblemsAD.ADGradientWrapper) = getvarinfo(parent(f))

setvarinfo(f::DynamicPPL.LogDensityFunction, varinfo) = Accessors.@set f.varinfo = varinfo
function setvarinfo(f::LogDensityProblemsAD.ADGradientWrapper, varinfo)
    return Accessors.@set f.ℓ = setvarinfo(f.ℓ, varinfo)
end

"""
    recompute_logprob!!(rng, model, sampler, state)

Recompute the log-probability of the `model` based on the given `state` and return the resulting state.
"""
function recompute_logprob!!(
    rng::Random.AbstractRNG,  # TODO: Do we need the `rng` here?
    model::DynamicPPL.Model,
    sampler::DynamicPPL.Sampler{<:ExternalSampler},
    state,
)
    # Re-using the log-density function from the `state` and updating only the `model` field,
    # since the `model` might now contain different conditioning values.
    f = setmodel(state.logdensity, model, sampler.alg.adtype)
    # Recompute the log-probability with the new `model`.
    state_inner = recompute_logprob!!(
        rng, AbstractMCMC.LogDensityModel(f), sampler.alg.sampler, state.state
    )
    return state_to_turing(f, state_inner)
end

function recompute_logprob!!(
    rng::Random.AbstractRNG,
    model::AbstractMCMC.LogDensityModel,
    sampler::AdvancedHMC.AbstractHMCSampler,
    state::AdvancedHMC.HMCState,
)
    # Construct hamiltionian.
    hamiltonian = AdvancedHMC.Hamiltonian(state.metric, model)
    # Re-compute the log-probability and gradient.
    return Accessors.@set state.transition.z = AdvancedHMC.phasepoint(
        hamiltonian, state.transition.z.θ, state.transition.z.r
    )
end

function recompute_logprob!!(
    rng::Random.AbstractRNG,
    model::AbstractMCMC.LogDensityModel,
    sampler::AdvancedMH.MetropolisHastings,
    state::AdvancedMH.Transition,
)
    logdensity = model.logdensity
    return Accessors.@set state.lp = LogDensityProblems.logdensity(logdensity, state.params)
end

# TODO: Do we also support `resume`, etc?
function AbstractMCMC.step(
    rng::Random.AbstractRNG,
    model::DynamicPPL.Model,
    sampler_wrapper::Sampler{<:ExternalSampler};
    initial_state=nothing,
    initial_params=nothing,
    kwargs...,
)
    alg = sampler_wrapper.alg
    sampler = alg.sampler

    # Create a log-density function with an implementation of the
    # gradient so we ensure that we're using the same AD backend as in Turing.
    f = LogDensityProblemsAD.ADgradient(alg.adtype, DynamicPPL.LogDensityFunction(model))

    # Link the varinfo if needed.
    varinfo = getvarinfo(f)
    if requires_unconstrained_space(alg)
        if initial_params !== nothing
            # If we have initial parameters, we need to set the varinfo before linking.
            varinfo = DynamicPPL.link(DynamicPPL.unflatten(varinfo, initial_params), model)
            # Extract initial parameters in unconstrained space.
            initial_params = varinfo[:]
        else
            varinfo = DynamicPPL.link(varinfo, model)
        end
    end
    f = setvarinfo(f, varinfo)

    # Then just call `AdvancedHMC.step` with the right arguments.
    if initial_state === nothing
        transition_inner, state_inner = AbstractMCMC.step(
            rng, AbstractMCMC.LogDensityModel(f), sampler; initial_params, kwargs...
        )
    else
        transition_inner, state_inner = AbstractMCMC.step(
            rng,
            AbstractMCMC.LogDensityModel(f),
            sampler,
            initial_state;
            initial_params,
            kwargs...,
        )
    end
    # Update the `state`
    return transition_to_turing(f, transition_inner), state_to_turing(f, state_inner)
end

function AbstractMCMC.step(
    rng::Random.AbstractRNG,
    model::DynamicPPL.Model,
    sampler_wrapper::Sampler{<:ExternalSampler},
    state::TuringState;
    kwargs...,
)
    sampler = sampler_wrapper.alg.sampler
    f = state.logdensity

    # Then just call `AdvancedHMC.step` with the right arguments.
    transition_inner, state_inner = AbstractMCMC.step(
        rng, AbstractMCMC.LogDensityModel(f), sampler, state.state; kwargs...
    )

    # Update the `state`
    return transition_to_turing(f, transition_inner), state_to_turing(f, state_inner)
end
