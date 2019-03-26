struct DynamicNUTS{AD, T} <: Hamiltonian{AD}
    n_iters   ::  Integer   # number of samples
    space     ::  Set{T}    # sampling space, emtpy means all
end
using AdvancedHMC
"""
    DynamicNUTS(n_iters::Integer)

Dynamic No U-Turn Sampling algorithm provided by the DynamicHMC package.
To use it, make sure you have the DynamicHMC package installed.

```julia
# Import Turing and DynamicHMC.
using DynamicHMC, Turing

# Model definition.
@model gdemo(x, y) = begin
  s ~ InverseGamma(2,3)
  m ~ Normal(0,sqrt(s))
  x ~ Normal(m, sqrt(s))
  y ~ Normal(m, sqrt(s))
  return s, m
end

# Pull 2,000 samples using DynamicNUTS.
chn = sample(gdemo(1.5, 2.0), DynamicNUTS(2000))
```
"""
DynamicNUTS(args...) = DynamicNUTS{ADBackend()}(args...)
function DynamicNUTS{AD}(n_iters::Integer, space...) where AD
    _space = isa(space, Symbol) ? Set([space]) : Set(space)
    DynamicNUTS{AD, eltype(_space)}(n_iters, _space)
end

function Sampler(alg::DynamicNUTS{T}, s::Selector) where T <: Hamiltonian
  return Sampler(alg, Dict{Symbol,Any}(), s)
end

function sample(model::Model,
                alg::DynamicNUTS{AD},
                ) where AD

    spl = Sampler(alg)

    n = alg.n_iters
    samples = Array{Sample}(undef, n)
    weight = 1 / n
    for i = 1:n
        samples[i] = Sample(weight, Dict{Symbol, Any}())
    end

    vi = VarInfo()
    model(vi, SampleFromUniform())

    if spl.selector.tag == :default
        link!(vi, spl)
        runmodel!(model, vi, spl)
    end

    function logπ(x)::Float64
        vi[spl] = x
        return runmodel!(model, vi, spl).logp
    end


    function ∂logπ∂θ(x)::Vector{Float64}
        _, deriv = gradient_logp(x, vi, model, spl)
        return deriv
    end

    θ_init = Vector{Float64}(vi[spl])
    # Define metric space, Hamiltonian and sampling method
    metric = DiagEuclideanMetric(θ_init)
    h = AdvancedHMC.Hamiltonian(metric, logπ, ∂logπ∂θ)
    prop = AdvancedHMC.NUTS(Leapfrog(AdvancedHMC.find_good_eps(h, θ_init)))
    adaptor = StanNUTSAdaptor(2_000, AdvancedHMC.PreConditioner(metric), NesterovDualAveraging(0.8, prop.integrator.ϵ))

    # Sampling
    asamples = AdvancedHMC.sample(h, prop, θ_init, spl.alg.n_iters, adaptor, 2_000)

    for i = 1:alg.n_iters
        vi[spl] = asamples[i]
        samples[i].value = Sample(vi, spl).value
    end

    return Chain(0.0, samples)
end
